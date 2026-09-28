// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ICurveEngine} from "../interfaces/ICurveEngine.sol";
import {PoolKey, CurveType} from "../types/PoolKey.sol";
import {PoolId} from "../types/PoolId.sol";
import {Currency} from "../types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../types/Slot0.sol";
import {PoolErrors} from "../errors/PoolErrors.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";
import {PluginDispatcher} from "./PluginDispatcher.sol";
import {TransientStorageLib} from "../libraries/TransientStorageLib.sol";
import {SafeCastLib} from "../libraries/SafeCastLib.sol";
import {ICircuitBreaker} from "../interfaces/ICircuitBreaker.sol";
import {CircuitBreakerErrors} from "../errors/CircuitBreakerErrors.sol";

/**
 * @title SupaPoolManager
 * @notice Core singleton AMM contract coordinating multi-curve pool state, flash accounting,
 * and plugin lifecycles.
 */
contract SupaPoolManager is IPoolManager {
    using Slot0Library for Slot0;

    /**
     * @notice Contract owner / governance address
     */
    address public owner;

    /**
     * @notice Multi-tier emergency circuit breaker contract
     */
    ICircuitBreaker public circuitBreaker;

    /**
     * @inheritdoc IPoolManager
     */
    IVault public immutable override vault;

    /**
     * @notice Curve Engine instances
     */
    ICurveEngine public immutable clammEngine;
    ICurveEngine public immutable binEngine;
    ICurveEngine public immutable stableEngine;

    /**
     * @notice Mapping of PoolId to active Slot0 state
     */
    mapping(PoolId => Slot0) internal poolSlot0;

    /**
     * @notice Mapping of PoolId to active Liquidity
     */
    mapping(PoolId => uint128) internal poolLiquidity;

    /**
     * @dev Modifier ensuring caller is owner
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert VaultErrors.Unauthorized();
        _;
    }

    /**
     * @dev Modifier requiring active unlock session
     */
    modifier onlyUnlocked() {
        if (!vault.isUnlocked()) revert VaultErrors.VaultNotUnlocked();
        _;
    }

    constructor(
        IVault _vault,
        ICurveEngine _clammEngine,
        ICurveEngine _binEngine,
        ICurveEngine _stableEngine
    ) {
        owner = msg.sender;
        vault = _vault;
        clammEngine = _clammEngine;
        binEngine = _binEngine;
        stableEngine = _stableEngine;
    }

    /**
     * @notice Configures the emergency circuit breaker instance
     */
    function setCircuitBreaker(ICircuitBreaker _circuitBreaker) external onlyOwner {
        circuitBreaker = _circuitBreaker;
    }

    /**
     * @notice Transfers pool manager governance ownership
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert VaultErrors.Unauthorized();
        owner = newOwner;
    }

    /**
     * @dev Internal helper verifying circuit breaker pause status for a pool and curve
     */
    function _checkCircuitBreaker(PoolId id, CurveType curveType) internal view {
        if (address(circuitBreaker) != address(0)) {
            if (circuitBreaker.isVaultPaused()) revert CircuitBreakerErrors.VaultPaused();
            if (circuitBreaker.isPoolPaused(id)) revert CircuitBreakerErrors.PoolPaused();
            if (circuitBreaker.isCurvePaused(uint8(curveType))) revert CircuitBreakerErrors.CurvePaused();
        }
    }

    /**
     * @notice Resolves the appropriate curve engine for a pool key.
     */
    function getCurveEngine(CurveType curveType) public view returns (ICurveEngine) {
        if (curveType == CurveType.CLAMM) return clammEngine;
        if (curveType == CurveType.BIN_AMM) return binEngine;
        if (curveType == CurveType.STABLE_AMM) return stableEngine;
        revert PoolErrors.CurrenciesOutOfOrderOrEqual();
    }

    /**
     * @inheritdoc IPoolManager
     */
    function initialize(PoolKey memory key, uint160 sqrtPriceX96, bytes calldata /* hookData */)
        external
        override
        returns (int24 tick)
    {
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) {
            revert PoolErrors.CurrenciesOutOfOrderOrEqual();
        }
        if (key.tickSpacing <= 0) revert PoolErrors.InvalidTickSpacing(key.tickSpacing);

        if (address(circuitBreaker) != address(0)) {
            if (circuitBreaker.isVaultPaused()) revert CircuitBreakerErrors.VaultPaused();
            if (circuitBreaker.isCurvePaused(uint8(key.curveType))) revert CircuitBreakerErrors.CurvePaused();
        }

        PoolId id = key.toId();
        if (poolSlot0[id].isInitialized()) revert PoolErrors.PoolAlreadyInitialized(id);

        PluginDispatcher.dispatchBeforeInitialize(key.plugin, msg.sender, key, sqrtPriceX96);

        ICurveEngine engine = getCurveEngine(key.curveType);
        tick = engine.initialize(key, sqrtPriceX96);

        Slot0 initialSlot0 = Slot0Library.pack(sqrtPriceX96, tick, 0, key.fee, true);
        poolSlot0[id] = initialSlot0;

        emit Initialize(
            id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.plugin, sqrtPriceX96, tick
        );

        PluginDispatcher.dispatchAfterInitialize(key.plugin, msg.sender, key, sqrtPriceX96, tick);
    }

    /**
     * @inheritdoc IPoolManager
     */
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) external override onlyUnlocked returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        PoolId id = key.toId();
        _checkCircuitBreaker(id, key.curveType);
        if (!poolSlot0[id].isInitialized()) revert PoolErrors.PoolNotInitialized(id);

        PluginDispatcher.dispatchBeforeModifyLiquidity(key.plugin, msg.sender, key, params, hookData);

        ICurveEngine engine = getCurveEngine(key.curveType);
        (callerDelta, feesAccrued) = engine.modifyLiquidity(key, params);

        BalanceDelta hookDelta = PluginDispatcher.dispatchAfterModifyLiquidity(
            key.plugin, msg.sender, key, params, callerDelta, hookData
        );

        if (BalanceDelta.unwrap(hookDelta) != 0) {
            callerDelta = callerDelta.add(hookDelta);
        }

        // Net caller delta accounts for accrued fee distributions (fees credit the caller)
        BalanceDelta netCallerDelta = callerDelta.sub(feesAccrued);

        if (netCallerDelta.amount0() != 0) {
            vault.accountDelta(msg.sender, key.currency0, -netCallerDelta.amount0());
        }
        if (netCallerDelta.amount1() != 0) {
            vault.accountDelta(msg.sender, key.currency1, -netCallerDelta.amount1());
        }

        poolSlot0[id] = engine.getSlot0(id);
        poolLiquidity[id] = engine.getLiquidity(id);

        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
    }

    /**
     * @inheritdoc IPoolManager
     */
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        override
        onlyUnlocked
        returns (BalanceDelta swapDelta)
    {
        PoolId id = key.toId();
        _checkCircuitBreaker(id, key.curveType);
        Slot0 slot0 = poolSlot0[id];
        if (!slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);

        uint24 overrideFee = PluginDispatcher.dispatchBeforeSwap(key.plugin, msg.sender, key, params, hookData);
        uint24 fee = overrideFee != 0 ? overrideFee : key.fee;

        ICurveEngine engine = getCurveEngine(key.curveType);
        swapDelta = engine.swap(key, params, fee);

        int128 hookDeltaSpecified = PluginDispatcher.dispatchAfterSwap(
            key.plugin, msg.sender, key, params, swapDelta, hookData
        );

        if (hookDeltaSpecified != 0) {
            if (params.zeroForOne) {
                swapDelta = toBalanceDelta(swapDelta.amount0() + hookDeltaSpecified, swapDelta.amount1());
            } else {
                swapDelta = toBalanceDelta(swapDelta.amount0(), swapDelta.amount1() + hookDeltaSpecified);
            }
        }

        // Apply swap deltas to vault transient ledger (input debt is negative, output credit is positive)
        if (swapDelta.amount0() != 0) {
            vault.accountDelta(msg.sender, key.currency0, -swapDelta.amount0());
        }
        if (swapDelta.amount1() != 0) {
            vault.accountDelta(msg.sender, key.currency1, -swapDelta.amount1());
        }

        poolSlot0[id] = engine.getSlot0(id);
        poolLiquidity[id] = engine.getLiquidity(id);

        emit Swap(
            id,
            msg.sender,
            swapDelta.amount0(),
            swapDelta.amount1(),
            poolSlot0[id].sqrtPriceX96(),
            poolLiquidity[id],
            poolSlot0[id].tick(),
            fee
        );
    }

    /**
     * @inheritdoc IPoolManager
     */
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        override
        onlyUnlocked
        returns (BalanceDelta delta)
    {
        PoolId id = key.toId();
        _checkCircuitBreaker(id, key.curveType);
        if (!poolSlot0[id].isInitialized()) revert PoolErrors.PoolNotInitialized(id);

        PluginDispatcher.dispatchBeforeDonate(key.plugin, msg.sender, key, amount0, amount1, hookData);

        if (amount0 != 0) {
            vault.accountDelta(msg.sender, key.currency0, -SafeCastLib.toInt256(amount0));
        }
        if (amount1 != 0) {
            vault.accountDelta(msg.sender, key.currency1, -SafeCastLib.toInt256(amount1));
        }

        delta = toBalanceDelta(SafeCastLib.toInt128(SafeCastLib.toInt256(amount0)), SafeCastLib.toInt128(SafeCastLib.toInt256(amount1)));
        emit Donate(id, msg.sender, amount0, amount1);

        PluginDispatcher.dispatchAfterDonate(key.plugin, msg.sender, key, amount0, amount1, hookData);
    }

    /**
     * @inheritdoc IPoolManager
     */
    function getSlot0(PoolId id) external view override returns (Slot0) {
        return poolSlot0[id];
    }

    /**
     * @inheritdoc IPoolManager
     */
    function getLiquidity(PoolId id) external view override returns (uint128) {
        return poolLiquidity[id];
    }
}
