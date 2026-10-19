// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "../external/BaseHook.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {IVolatilityTWAPOracle} from "../../interfaces/IVolatilityTWAPOracle.sol";
import {ISupaRoles} from "../../interfaces/ISupaRoles.sol";
import {IPluginEvents} from "../../events/IPluginEvents.sol";
import {PluginDispatcher} from "../../core/PluginDispatcher.sol";
import {DynamicFeeLib} from "../../libraries/DynamicFeeLib.sol";
import {PluginErrors} from "../../errors/PluginErrors.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../types/PoolId.sol";
import {BalanceDelta} from "../../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../types/Slot0.sol";
import {VolatilityTWAPOracle} from "./VolatilityTWAPOracle.sol";

/**
 * @title LVRShieldPlugin
 * @notice Native adaptive-fee plugin that surcharges swaps under rapid pool-tick volatility
 *         and decays elevated fees toward the pool base fee (half-life decay).
 * @dev Plugin min/max fee bounds are authoritative after DynamicFeeLib compute + clamp.
 *      Signal uses internal pool ticks (not an external fair-price feed).
 */
contract LVRShieldPlugin is BaseHook, IPluginEvents {
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;

    uint24 internal constant MAX_FEE_PIPS = 1_000_000;
    /// @dev Observation ring capacity grown at pool init for usable TWAP history.
    uint16 internal constant ORACLE_CARDINALITY = 64;

    IVolatilityTWAPOracle public immutable oracle;
    ISupaRoles public roles;

    struct PoolLVRState {
        uint24 baseFee;
        uint24 lastFee;
        uint32 lastSwapTimestamp;
        int24 lastTick;
        uint32 decayHalfLife;
        uint24 volatilityAlpha;
        uint24 minFeeBps;
        uint24 maxFeeBps;
        bool isInitialized;
    }

    mapping(PoolId => PoolLVRState) public poolLVRStates;

    modifier onlyOperatorOrRolesOwner() {
        // Unset roles ⇒ permissionless fee griefing; require deploy to call `setRoles` first.
        if (address(roles) == address(0)) {
            revert PluginErrors.PluginPermissionDenied(address(this), 0);
        }
        if (!roles.isOperator(msg.sender) && msg.sender != roles.owner()) {
            revert PluginErrors.PluginPermissionDenied(address(this), 0);
        }
        _;
    }

    /**
     * @dev Deploys a writer-bound oracle in-constructor (writer = address(this)) so there is
     * no permissionless `setWriter` race at deploy time.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        oracle = IVolatilityTWAPOracle(address(new VolatilityTWAPOracle(address(this))));
    }

    /**
     * @notice Wires the operator registry (callable once by current roles owner or unset).
     * @dev Zero address rejected so setters cannot be re-opened as permissionless.
     */
    function setRoles(ISupaRoles _roles) external {
        if (address(_roles) == address(0)) revert PluginErrors.PluginPermissionDenied(address(this), 0);
        if (address(roles) != address(0) && msg.sender != roles.owner()) {
            revert PluginErrors.PluginPermissionDenied(address(this), 0);
        }
        roles = _roles;
    }

    function getPluginPermissions() public pure override returns (uint32 permissions) {
        return PluginDispatcher.AFTER_INITIALIZE_FLAG | PluginDispatcher.BEFORE_SWAP_FLAG
            | PluginDispatcher.AFTER_SWAP_FLAG;
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        sender;
        sqrtPriceX96;
        PoolId poolId = key.toId();

        uint24 maxFee = key.fee > 10_000 ? key.fee : 100_000;
        uint24 minFee = key.fee > 1 ? 1 : key.fee;
        if (minFee > maxFee) maxFee = minFee;

        poolLVRStates[poolId] = PoolLVRState({
            baseFee: key.fee,
            lastFee: key.fee,
            lastSwapTimestamp: uint32(block.timestamp),
            lastTick: tick,
            decayHalfLife: 12,
            volatilityAlpha: 50,
            minFeeBps: minFee,
            maxFeeBps: maxFee,
            isInitialized: true
        });

        oracle.initialize(poolId, uint32(block.timestamp), tick);
        oracle.grow(poolId, ORACLE_CARDINALITY);

        return this.afterInitialize.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, uint24 overrideFee) {
        sender;
        params;
        hookData;
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];

        if (!state.isInitialized) {
            return (this.beforeSwap.selector, 0);
        }

        uint32 currentTime = uint32(block.timestamp);
        uint32 timeElapsed = currentTime >= state.lastSwapTimestamp ? currentTime - state.lastSwapTimestamp : 0;

        uint256 volatility = oracle.getInstantaneousVolatility(poolId, 12);
        // Scale volatility by alpha (100 units ~= 1 bp surcharge unit)
        uint256 scaledVol = (volatility * state.volatilityAlpha) / 100;
        if (scaledVol > type(uint24).max) scaledVol = type(uint24).max;

        uint24 dynamicFee = DynamicFeeLib.computeDynamicFee(
            state.baseFee, state.lastFee, uint24(scaledVol), timeElapsed, state.decayHalfLife
        );

        // Plugin bounds are authoritative after DynamicFeeLib compute.
        if (dynamicFee < state.minFeeBps) dynamicFee = state.minFeeBps;
        if (dynamicFee > state.maxFeeBps) dynamicFee = state.maxFeeBps;

        state.lastFee = dynamicFee;
        state.lastSwapTimestamp = currentTime;

        emit DynamicFeeUpdated(poolId, state.baseFee, dynamicFee, uint24(scaledVol), timeElapsed);

        return (this.beforeSwap.selector, dynamicFee);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128 hookDeltaSpecified) {
        sender;
        params;
        delta;
        hookData;
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];

        if (state.isInitialized) {
            Slot0 slot0 = poolManager.getSlot0(poolId);
            int24 tick = slot0.tick();
            state.lastTick = tick;
            uint128 liquidity = poolManager.getLiquidity(poolId);
            // Fail loud: silent catch previously hid oracle write failures.
            oracle.write(poolId, uint32(block.timestamp), tick, liquidity > 0 ? liquidity : 1);
        }

        return (this.afterSwap.selector, 0);
    }

    function setDecayHalfLife(PoolKey calldata key, uint32 newDecayHalfLife) external onlyOperatorOrRolesOwner {
        if (newDecayHalfLife == 0) revert PluginErrors.InvalidDecayHalfLife();
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        state.decayHalfLife = newDecayHalfLife;
        _emitParams(poolId, state);
    }

    function setVolatilityAlpha(PoolKey calldata key, uint24 newAlpha) external onlyOperatorOrRolesOwner {
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        state.volatilityAlpha = newAlpha;
        _emitParams(poolId, state);
    }

    function setMinFeeBps(PoolKey calldata key, uint24 newMin) external onlyOperatorOrRolesOwner {
        if (newMin >= MAX_FEE_PIPS) revert PluginErrors.InvalidFeeParameter(newMin);
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        if (newMin > state.maxFeeBps) revert PluginErrors.InvalidFeeBounds(newMin, state.maxFeeBps);
        state.minFeeBps = newMin;
        _emitParams(poolId, state);
    }

    function setMaxFeeBps(PoolKey calldata key, uint24 newMax) external onlyOperatorOrRolesOwner {
        if (newMax >= MAX_FEE_PIPS) revert PluginErrors.InvalidFeeParameter(newMax);
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        if (state.minFeeBps > newMax) revert PluginErrors.InvalidFeeBounds(state.minFeeBps, newMax);
        state.maxFeeBps = newMax;
        _emitParams(poolId, state);
    }

    function setDecayParameters(
        PoolKey calldata key,
        uint32 newDecayHalfLife,
        uint24 newAlpha,
        uint24 newMin,
        uint24 newMax
    ) external onlyOperatorOrRolesOwner {
        if (newDecayHalfLife == 0) revert PluginErrors.InvalidDecayHalfLife();
        if (newMin >= MAX_FEE_PIPS) revert PluginErrors.InvalidFeeParameter(newMin);
        if (newMax >= MAX_FEE_PIPS) revert PluginErrors.InvalidFeeParameter(newMax);
        if (newMin > newMax) revert PluginErrors.InvalidFeeBounds(newMin, newMax);
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        state.decayHalfLife = newDecayHalfLife;
        state.volatilityAlpha = newAlpha;
        state.minFeeBps = newMin;
        state.maxFeeBps = newMax;
        _emitParams(poolId, state);
    }

    function _emitParams(PoolId poolId, PoolLVRState storage state) internal {
        emit LVRParametersUpdated(
            poolId, state.decayHalfLife, state.volatilityAlpha, state.minFeeBps, state.maxFeeBps
        );
    }
}
