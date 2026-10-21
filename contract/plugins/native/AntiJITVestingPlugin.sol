// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "../external/BaseHook.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {IPluginEvents} from "../../events/IPluginEvents.sol";
import {PluginDispatcher} from "../../core/PluginDispatcher.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId} from "../../types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "../../types/BalanceDelta.sol";

/**
 * @title AntiJITVestingPlugin
 * @notice Native anti-MEV plugin that linearly vests accrued swap fees over a minimum residency
 *         window and redistributes unvested fees to remaining LPs via fee growth.
 * @dev Residency is tracked per position key. Adding liquidity resets the clock for the entire position
 *      (APUS-SUPADEX-014); honest LPs who top up therefore re-vest fees earned in the next
 *      `minResidencyBlocks` blocks. Fees realised on any modify (including adds) are haircut by the
 *      pre-update residency (APUS-SUPADEX-008). Separate salts/positions are tracked independently.
 */
contract AntiJITVestingPlugin is BaseHook, IPluginEvents {
    /**
     * @notice Minimum number of blocks liquidity must remain deposited for full fee vesting.
     */
    uint32 public immutable minResidencyBlocks;

    uint24 public constant BPS_DENOMINATOR = 10_000;

    /**
     * @dev Pending unvested fee bps for the in-flight modifyLiquidity call.
     *      Single slot is safe: PoolManager is non-reentrant across unlock, and before/after
     *      pair atomically. Cleared in afterModifyLiquidity.
     */
    uint24 private _pendingUnvestedBps;

    /**
     * @notice Position residency container.
     */
    struct PositionResidency {
        uint32 lastDepositBlock;
        uint32 lastDepositTimestamp;
        uint128 liquidity;
    }

    /**
     * @notice Mapping from PoolId => positionKey => PositionResidency.
     */
    mapping(PoolId => mapping(bytes32 => PositionResidency)) public residencies;

    constructor(IPoolManager _poolManager, uint32 _minResidencyBlocks) BaseHook(_poolManager) {
        minResidencyBlocks = _minResidencyBlocks > 0 ? _minResidencyBlocks : 3;
    }

    /**
     * @inheritdoc BaseHook
     */
    function getPluginPermissions() public pure override returns (uint32 permissions) {
        return PluginDispatcher.BEFORE_MODIFY_LIQUIDITY_FLAG | PluginDispatcher.AFTER_MODIFY_LIQUIDITY_FLAG;
    }

    /**
     * @inheritdoc BaseHook
     */
    function beforeModifyLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        hookData;
        PoolId poolId = key.toId();
        // Align with engine Position.getKey(owner=sender, ticks, salt)
        bytes32 positionKey = keccak256(abi.encodePacked(sender, params.tickLower, params.tickUpper, params.salt));

        PositionResidency storage residency = residencies[poolId][positionKey];

        // APUS-SUPADEX-008: every modifyLiquidity realises the position's accrued fees (engines pay them on adds
        // too), so the haircut is ALWAYS evaluated against the residency that earned those fees, before any update.
        _pendingUnvestedBps = _computeUnvestedBps(residency);

        if (params.liquidityDelta > 0) {
            uint128 addLiq = uint128(uint256(int256(params.liquidityDelta)));
            uint128 oldLiq = residency.liquidity;
            // APUS-SUPADEX-014: any top-up restarts the residency clock for the whole position (no liquidity-
            // weighted averaging), so a resident seed cannot shield a same-block JIT top-up. Fees earned before
            // the top-up were already settled above at the old age; only fees accrued after it vest again.
            residency.lastDepositBlock = uint32(block.number);
            residency.lastDepositTimestamp = uint32(block.timestamp);
            residency.liquidity = oldLiq + addLiq;

            emit LiquidityResidencyRecorded(
                poolId, sender, positionKey, residency.lastDepositBlock, uint32(block.timestamp), residency.liquidity
            );
        } else {
            // Remove or fee-collect poke (vesting already evaluated above).
            if (params.liquidityDelta < 0) {
                uint128 deltaAbs = uint128(uint256(int256(-params.liquidityDelta)));
                if (deltaAbs >= residency.liquidity) {
                    residency.liquidity = 0;
                } else {
                    residency.liquidity -= deltaAbs;
                }
            }
        }

        return this.beforeModifyLiquidity.selector;
    }

    /**
     * @inheritdoc BaseHook
     */
    function afterModifyLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta hookDelta, BalanceDelta feesHookDelta) {
        hookData;
        delta; // Principal is never haircut — fees only.
        params;

        uint24 unvestedBps = _pendingUnvestedBps;
        _pendingUnvestedBps = 0;
        if (unvestedBps == 0) {
            return (this.afterModifyLiquidity.selector, BalanceDelta.wrap(0), BalanceDelta.wrap(0));
        }

        int128 f0 = feesAccrued.amount0();
        int128 f1 = feesAccrued.amount1();
        int128 h0;
        int128 h1;
        uint256 penaltyAmount;

        if (f0 > 0) {
            uint256 haircut0 = (uint256(uint128(f0)) * unvestedBps) / BPS_DENOMINATOR;
            h0 = int128(uint128(haircut0));
            penaltyAmount += haircut0;
        }
        if (f1 > 0) {
            uint256 haircut1 = (uint256(uint128(f1)) * unvestedBps) / BPS_DENOMINATOR;
            h1 = int128(uint128(haircut1));
            penaltyAmount += haircut1;
        }

        if (penaltyAmount > 0) {
            PoolId poolId = key.toId();
            bytes32 positionKey = keccak256(abi.encodePacked(sender, params.tickLower, params.tickUpper, params.salt));
            PositionResidency storage residency = residencies[poolId][positionKey];
            uint32 elapsed = _elapsedBlocks(residency.lastDepositBlock);
            emit JITPenaltyLevied(poolId, sender, positionKey, penaltyAmount, elapsed, minResidencyBlocks);
        }

        feesHookDelta = toBalanceDelta(h0, h1);
        return (this.afterModifyLiquidity.selector, BalanceDelta.wrap(0), feesHookDelta);
    }

    /**
     * @dev Linear unvested share: unvestedBps = BPS * (1 - min(elapsed/K, 1)).
     */
    function _computeUnvestedBps(PositionResidency storage residency) internal view returns (uint24) {
        // Untouched / never deposited via this plugin → fully vested.
        if (residency.lastDepositBlock == 0 && residency.liquidity == 0) return 0;

        uint32 required = minResidencyBlocks;
        uint32 elapsed = _elapsedBlocks(residency.lastDepositBlock);
        if (elapsed >= required) return 0;

        uint256 vestedBps = (uint256(elapsed) * BPS_DENOMINATOR) / uint256(required);
        return uint24(BPS_DENOMINATOR - vestedBps);
    }

    function _elapsedBlocks(uint32 depositBlock) internal view returns (uint32) {
        uint32 currentBlock = uint32(block.number);
        return currentBlock >= depositBlock ? currentBlock - depositBlock : 0;
    }
}
