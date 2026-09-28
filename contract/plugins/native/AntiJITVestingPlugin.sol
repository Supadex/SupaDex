// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "../external/BaseHook.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {IPluginEvents} from "../../events/IPluginEvents.sol";
import {PluginDispatcher} from "../../core/PluginDispatcher.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../types/PoolId.sol";
import {BalanceDelta} from "../../types/BalanceDelta.sol";

/**
 * @title AntiJITVestingPlugin
 * @notice Native anti-MEV plugin preventing Just-In-Time (JIT) liquidity attacks via epoch-based residency verification.
 */
contract AntiJITVestingPlugin is BaseHook, IPluginEvents {
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Minimum number of blocks liquidity must remain deposited before withdrawal without JIT penalty.
     */
    uint32 public immutable minResidencyBlocks;

    /**
     * @notice Penalty rate in basis points (e.g. 5000 = 50%) applied to early JIT liquidity withdrawals.
     */
    uint24 public constant PENALTY_BPS = 5000;
    uint24 public constant BPS_DENOMINATOR = 10000;

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

    constructor(
        IPoolManager _poolManager,
        uint32 _minResidencyBlocks
    ) BaseHook(_poolManager) {
        minResidencyBlocks = _minResidencyBlocks > 0 ? _minResidencyBlocks : 3;
    }

    /**
     * @inheritdoc BaseHook
     */
    function getPluginPermissions()
        public
        pure
        override
        returns (uint32 permissions)
    {
        return
            PluginDispatcher.BEFORE_MODIFY_LIQUIDITY_FLAG |
            PluginDispatcher.AFTER_MODIFY_LIQUIDITY_FLAG;
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
        bytes32 positionKey = keccak256(
            abi.encodePacked(
                sender,
                params.tickLower,
                params.tickUpper,
                params.salt
            )
        );

        PositionResidency storage residency = residencies[poolId][positionKey];

        if (params.liquidityDelta > 0) {
            // Addition of liquidity: record/refresh residency entry
            residency.lastDepositBlock = uint32(block.number);
            residency.lastDepositTimestamp = uint32(block.timestamp);
            residency.liquidity += uint128(
                uint256(int256(params.liquidityDelta))
            );

            emit LiquidityResidencyRecorded(
                poolId,
                sender,
                positionKey,
                uint32(block.number),
                uint32(block.timestamp),
                residency.liquidity
            );
        } else if (params.liquidityDelta < 0) {
            // Removal of liquidity: evaluate block residency
            uint32 currentBlock = uint32(block.number);
            uint32 depositBlock = residency.lastDepositBlock;
            uint32 elapsed = currentBlock >= depositBlock
                ? currentBlock - depositBlock
                : 0;

            uint128 deltaAbs = uint128(uint256(int256(-params.liquidityDelta)));

            if (elapsed < minResidencyBlocks && residency.liquidity > 0) {
                // JIT residency violation detected: calculate haircut penalty
                uint256 penalty = (uint256(deltaAbs) * PENALTY_BPS) /
                    BPS_DENOMINATOR;

                emit JITPenaltyLevied(
                    poolId,
                    sender,
                    positionKey,
                    penalty,
                    elapsed,
                    minResidencyBlocks
                );
            }

            if (deltaAbs >= residency.liquidity) {
                residency.liquidity = 0;
            } else {
                residency.liquidity -= deltaAbs;
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
        bytes calldata hookData
    )
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BalanceDelta hookDelta)
    {
        sender;
        key;
        params;
        delta;
        hookData;
        return (this.afterModifyLiquidity.selector, BalanceDelta.wrap(0));
    }
}
