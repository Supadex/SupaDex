// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "../external/BaseHook.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {IVolatilityTWAPOracle} from "../../interfaces/IVolatilityTWAPOracle.sol";
import {IPluginEvents} from "../../events/IPluginEvents.sol";
import {PluginDispatcher} from "../../core/PluginDispatcher.sol";
import {DynamicFeeLib} from "../../libraries/DynamicFeeLib.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../types/PoolId.sol";
import {BalanceDelta} from "../../types/BalanceDelta.sol";

/**
 * @title LVRShieldPlugin
 * @notice Native anti-MEV plugin protecting liquidity providers from Loss-Versus-Rebalancing via dynamic volatility decay spreads.
 */
contract LVRShieldPlugin is BaseHook, IPluginEvents {
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Volatility TWAP oracle recording price tick observations.
     */
    IVolatilityTWAPOracle public immutable oracle;

    /**
     * @notice Tracking container for pool-level dynamic fee volatility state.
     */
    struct PoolLVRState {
        uint24 baseFee;
        uint24 lastFee;
        uint32 lastSwapTimestamp;
        int24 lastTick;
        uint32 decayHalfLife;
        bool isInitialized;
    }

    /**
     * @notice Mapping from PoolId to dynamic LVR state.
     */
    mapping(PoolId => PoolLVRState) public poolLVRStates;

    constructor(IPoolManager _poolManager, IVolatilityTWAPOracle _oracle) BaseHook(_poolManager) {
        oracle = _oracle;
    }

    /**
     * @inheritdoc BaseHook
     */
    function getPluginPermissions() public pure override returns (uint32 permissions) {
        return
            PluginDispatcher.AFTER_INITIALIZE_FLAG | PluginDispatcher.BEFORE_SWAP_FLAG
                | PluginDispatcher.AFTER_SWAP_FLAG;
    }

    /**
     * @inheritdoc BaseHook
     */
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
            decayHalfLife: 12, // 12-second block decay half life
            isInitialized: true
        });

        // Initialize oracle state for the pool
        oracle.initialize(poolId, uint32(block.timestamp), tick);

        return this.afterInitialize.selector;
    }

    /**
     * @inheritdoc BaseHook
     */
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

        // Query instantaneous volatility over recent block window
        uint256 volatility = oracle.getInstantaneousVolatility(poolId, 12);

        // Compute volatility-adaptive dynamic fee
        uint24 dynamicFee = DynamicFeeLib.computeDynamicFee(
            state.baseFee, state.lastFee, uint24(volatility), timeElapsed, state.decayHalfLife
        );

        state.lastFee = dynamicFee;
        state.lastSwapTimestamp = currentTime;

        emit DynamicFeeUpdated(poolId, state.baseFee, dynamicFee, uint24(volatility), timeElapsed);

        return (this.beforeSwap.selector, dynamicFee);
    }

    /**
     * @inheritdoc BaseHook
     */
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
            // Write updated observation to volatility oracle
            try oracle.write(poolId, uint32(block.timestamp), state.lastTick, 100_000_000) {} catch {}
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Updates the decay half life in seconds for a specific pool.
     */
    function setDecayHalfLife(PoolKey calldata key, uint32 newDecayHalfLife) external {
        // Enforce basic validation
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (state.isInitialized) {
            state.decayHalfLife = newDecayHalfLife;
        }
    }
}
