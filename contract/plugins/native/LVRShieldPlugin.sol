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

/**
 * @title LVRShieldPlugin
 * @notice Native anti-MEV plugin protecting liquidity providers from Loss-Versus-Rebalancing via dynamic volatility decay spreads.
 */
contract LVRShieldPlugin is BaseHook, IPluginEvents {
    using PoolIdLibrary for PoolKey;

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
        if (address(roles) != address(0)) {
            if (!roles.isOperator(msg.sender) && msg.sender != roles.owner()) {
                revert PluginErrors.PluginPermissionDenied(address(this), 0);
            }
        }
        _;
    }

    constructor(IPoolManager _poolManager, IVolatilityTWAPOracle _oracle) BaseHook(_poolManager) {
        oracle = _oracle;
    }

    /**
     * @notice Wires the operator registry (callable once by current roles owner or unset).
     */
    function setRoles(ISupaRoles _roles) external {
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

        poolLVRStates[poolId] = PoolLVRState({
            baseFee: key.fee,
            lastFee: key.fee,
            lastSwapTimestamp: uint32(block.timestamp),
            lastTick: tick,
            decayHalfLife: 12,
            volatilityAlpha: 50,
            minFeeBps: key.fee > 1 ? 1 : key.fee,
            maxFeeBps: key.fee > 10_000 ? key.fee : 100_000,
            isInitialized: true
        });

        oracle.initialize(poolId, uint32(block.timestamp), tick);

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

        uint24 dynamicFee = DynamicFeeLib.computeDynamicFee(
            state.baseFee, state.lastFee, uint24(scaledVol), timeElapsed, state.decayHalfLife
        );

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
            try oracle.write(poolId, uint32(block.timestamp), state.lastTick, 100_000_000) {} catch {}
        }

        return (this.afterSwap.selector, 0);
    }

    function setDecayHalfLife(PoolKey calldata key, uint32 newDecayHalfLife) external onlyOperatorOrRolesOwner {
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
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        state.minFeeBps = newMin;
        _emitParams(poolId, state);
    }

    function setMaxFeeBps(PoolKey calldata key, uint24 newMax) external onlyOperatorOrRolesOwner {
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
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
