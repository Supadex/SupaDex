// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ICurveEngine} from "../interfaces/ICurveEngine.sol";
import {IPluginWhitelist} from "../interfaces/IPluginWhitelist.sol";
import {PoolKey, CurveType} from "../types/PoolKey.sol";
import {PoolId} from "../types/PoolId.sol";
import {Currency} from "../types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../types/Slot0.sol";
import {PoolErrors} from "../errors/PoolErrors.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";
import {PluginDispatcher} from "./PluginDispatcher.sol";
import {SafeCastLib} from "../libraries/SafeCastLib.sol";
import {ProtocolFeeLib} from "../libraries/ProtocolFeeLib.sol";
import {ICircuitBreaker} from "../interfaces/ICircuitBreaker.sol";
import {CircuitBreakerErrors} from "../errors/CircuitBreakerErrors.sol";

/**
 * @title SupaPoolManager
 * @notice Core singleton AMM contract coordinating multi-curve pool state, flash accounting,
 * and plugin lifecycles.
 * @dev NOT upgradeable (plain contract; engines are immutables). Upgrading means redeploying and migrating.
 * Circuit breaker = withdraw-only mode (SDX-008): when the vault, pool or curve is paused, swaps, donations
 * and liquidity additions revert, while liquidity removals and fee collection (liquidityDelta <= 0) stay open.
 * BIN_AMM pool creation is disabled (ADR-0004, `binAmmEnabled() == false`) until a multi-bin traversal engine exists.
 */
contract SupaPoolManager is IPoolManager {
    using Slot0Library for Slot0;

    uint24 internal constant MAX_FEE_PIPS = 1_000_000;

    /**
     * @notice ADR-0004: BinAMM is a single frozen-price bin; new BIN_AMM pools are disabled until multi-bin lands.
     * @dev `virtual` only so the test suite can keep exercising BinAMM engine accounting through a test-only
     * subclass (test/helpers/SecurityTestSetup.sol). The production contract always returns false.
     */
    function binAmmEnabled() public pure virtual returns (bool) {
        return false;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event CircuitBreakerSet(address indexed circuitBreaker);
    event PluginWhitelistSet(address indexed whitelist);
    event ProtocolFeeControllerSet(address indexed controller);

    address public owner;
    ICircuitBreaker public circuitBreaker;
    IPluginWhitelist public pluginWhitelist;
    address public protocolFeeController;

    IVault public immutable override vault;
    ICurveEngine public immutable clammEngine;
    ICurveEngine public immutable binEngine;
    ICurveEngine public immutable stableEngine;

    mapping(PoolId => Slot0) internal poolSlot0;
    mapping(PoolId => uint128) internal poolLiquidity;
    mapping(Currency => uint256) public override protocolFeesAccrued;
    /// @notice Plugin permission bitmask cached at initialize; plugins cannot change it afterwards.
    mapping(PoolId => uint32) public pluginPermissions;

    modifier onlyOwner() {
        if (msg.sender != owner) revert VaultErrors.Unauthorized();
        _;
    }

    modifier onlyUnlocked() {
        if (!vault.isUnlocked()) revert VaultErrors.VaultNotUnlocked();
        _;
    }

    /**
     * @dev Engines are deployed in a prior tx (predicted CREATE address) and passed in so
     * PoolManager initcode stays under EIP-3860 (49KB). Each engine must be immutably bound
     * to `address(this)` — no permissionless setter.
     */
    constructor(IVault _vault, ICurveEngine _clamm, ICurveEngine _bin, ICurveEngine _stable) {
        owner = msg.sender;
        vault = _vault;
        if (address(_clamm) == address(0) || address(_bin) == address(0) || address(_stable) == address(0)) {
            revert PoolErrors.NotPoolManager();
        }
        if (
            _clamm.poolManager() != address(this) || _bin.poolManager() != address(this)
                || _stable.poolManager() != address(this)
        ) {
            revert PoolErrors.NotPoolManager();
        }
        clammEngine = _clamm;
        binEngine = _bin;
        stableEngine = _stable;
    }

    function setCircuitBreaker(ICircuitBreaker _circuitBreaker) external onlyOwner {
        circuitBreaker = _circuitBreaker;
        emit CircuitBreakerSet(address(_circuitBreaker));
    }

    function setPluginWhitelist(IPluginWhitelist _whitelist) external onlyOwner {
        // Never allow disabling the whitelist once configured.
        if (address(_whitelist) == address(0)) revert PoolErrors.PluginWhitelistRequired();
        pluginWhitelist = _whitelist;
        emit PluginWhitelistSet(address(_whitelist));
    }

    function setProtocolFeeController(address controller) external onlyOwner {
        if (controller == address(0)) revert VaultErrors.Unauthorized();
        protocolFeeController = controller;
        emit ProtocolFeeControllerSet(controller);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert VaultErrors.Unauthorized();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _checkCircuitBreaker(PoolId id, CurveType curveType) internal view {
        if (address(circuitBreaker) != address(0)) {
            if (circuitBreaker.isVaultPaused()) revert CircuitBreakerErrors.VaultPaused();
            if (circuitBreaker.isPoolPaused(id)) revert CircuitBreakerErrors.PoolPaused();
            if (circuitBreaker.isCurvePaused(uint8(curveType))) revert CircuitBreakerErrors.CurvePaused();
        }
    }

    function getCurveEngine(CurveType curveType) public view returns (ICurveEngine) {
        if (curveType == CurveType.CLAMM) return clammEngine;
        if (curveType == CurveType.BIN_AMM) return binEngine;
        if (curveType == CurveType.STABLE_AMM) return stableEngine;
        revert PoolErrors.CurrenciesOutOfOrderOrEqual();
    }

    function _abs128(int128 x) internal pure returns (uint256) {
        return uint256(uint128(x < 0 ? -x : x));
    }

    function _isPluginAllowed(address plugin) internal view returns (bool) {
        return address(pluginWhitelist) != address(0) && pluginWhitelist.isPluginWhitelisted(plugin);
    }

    function _requirePluginAllowed(address plugin) internal view {
        if (address(pluginWhitelist) == address(0)) revert PoolErrors.PluginWhitelistRequired();
        if (!pluginWhitelist.isPluginWhitelisted(plugin)) {
            revert PoolErrors.PluginNotWhitelisted(plugin);
        }
    }

    /**
     * @dev Hook deltas may only haircut user *credits* (negative reference):
     * - `referenceAmount > 0` (user debit): any non-zero hook underpays while engine state advances → reject.
     * - `referenceAmount < 0` (user credit): only non-negative haircuts with `hook <= |reference|`.
     * - `referenceAmount == 0`: non-zero hooks create value from nothing → reject.
     */
    function _validateHookDelta(address plugin, int128 hookAmount, int128 referenceAmount) internal view {
        if (hookAmount == 0) return;
        if (!pluginWhitelist.canPluginReturnDelta(plugin)) {
            revert PoolErrors.HookDeltaNotAllowed(plugin);
        }
        // Debits (and zero legs) cannot be reduced or invented by hooks.
        if (referenceAmount >= 0) revert PoolErrors.HookDeltaCapExceeded();
        // Credits: haircut must be non-negative and bounded by the credit magnitude.
        if (hookAmount < 0 || uint256(uint128(hookAmount)) > _abs128(referenceAmount)) {
            revert PoolErrors.HookDeltaCapExceeded();
        }
    }

    /**
     * @dev Fee hook deltas must be non-negative and bounded by accrued fees per leg.
     */
    function _validateFeesHookDelta(address plugin, int128 feesHookAmount, int128 feesAccruedAmount) internal view {
        if (feesHookAmount == 0) return;
        if (!pluginWhitelist.canPluginReturnDelta(plugin)) {
            revert PoolErrors.HookDeltaNotAllowed(plugin);
        }
        if (feesHookAmount < 0 || feesAccruedAmount < 0) revert PoolErrors.HookDeltaCapExceeded();
        if (uint256(uint128(feesHookAmount)) > uint256(uint128(feesAccruedAmount))) {
            revert PoolErrors.HookDeltaCapExceeded();
        }
    }

    /**
     * @dev Credits confiscated fees to remaining LPs via fee growth, or protocol if no active liquidity.
     * Tokens are already in the vault (from prior swaps); do not vault-debit again.
     */
    function _redistributeConfiscatedFees(PoolKey memory key, ICurveEngine engine, uint256 amount0, uint256 amount1)
        internal
    {
        if (amount0 == 0 && amount1 == 0) return;
        if (engine.getLiquidity(key.toId()) == 0) {
            if (amount0 > 0) protocolFeesAccrued[key.currency0] += amount0;
            if (amount1 > 0) protocolFeesAccrued[key.currency1] += amount1;
            return;
        }
        engine.donate(key, amount0, amount1);
    }

    /// @inheritdoc IPoolManager
    function initialize(
        PoolKey memory key,
        uint160 sqrtPriceX96,
        bytes calldata /* hookData */
    )
        external
        override
        returns (int24 tick)
    {
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) {
            revert PoolErrors.CurrenciesOutOfOrderOrEqual();
        }
        if (key.tickSpacing <= 0) revert PoolErrors.InvalidTickSpacing(key.tickSpacing);
        if (key.fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(key.fee);
        if (key.curveType == CurveType.BIN_AMM && !binAmmEnabled()) {
            revert PoolErrors.CurveDisabled(uint8(CurveType.BIN_AMM));
        }

        _requirePluginAllowed(key.plugin);

        if (address(circuitBreaker) != address(0)) {
            if (circuitBreaker.isVaultPaused()) revert CircuitBreakerErrors.VaultPaused();
            if (circuitBreaker.isCurvePaused(uint8(key.curveType))) revert CircuitBreakerErrors.CurvePaused();
        }

        PoolId id = key.toId();
        if (poolSlot0[id].isInitialized()) revert PoolErrors.PoolAlreadyInitialized(id);

        uint32 permissions = PluginDispatcher.readPermissions(key.plugin);
        pluginPermissions[id] = permissions;

        PluginDispatcher.dispatchBeforeInitialize(key.plugin, permissions, msg.sender, key, sqrtPriceX96);

        ICurveEngine engine = getCurveEngine(key.curveType);
        tick = engine.initialize(key, sqrtPriceX96);

        Slot0 initialSlot0 = Slot0Library.pack(sqrtPriceX96, tick, 0, key.fee, true);
        poolSlot0[id] = initialSlot0;

        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.plugin, sqrtPriceX96, tick);

        PluginDispatcher.dispatchAfterInitialize(key.plugin, permissions, msg.sender, key, sqrtPriceX96, tick);
    }

    /// @inheritdoc IPoolManager
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        override
        onlyUnlocked
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        // Withdraw-only pause: removals / fee pokes (liquidityDelta <= 0) are always allowed.
        if (params.liquidityDelta > 0) _checkCircuitBreaker(id, key.curveType);
        if (!poolSlot0[id].isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        uint32 permissions = pluginPermissions[id];
        // Delisting disables the plugin on already-initialized pools. APUS-SUPADEX-011: instead of trapping LP
        // principal, removals / fee pokes still go through with ALL hooks skipped; only adds revert.
        if (params.liquidityDelta > 0) {
            _requirePluginAllowed(key.plugin);
        } else if (!_isPluginAllowed(key.plugin)) {
            permissions = 0;
        }

        PluginDispatcher.dispatchBeforeModifyLiquidity(key.plugin, permissions, msg.sender, key, params, hookData);

        ICurveEngine engine = getCurveEngine(key.curveType);
        (callerDelta, feesAccrued) = engine.modifyLiquidity(key, params, msg.sender);

        // Sync before after-hooks so plugins reading getSlot0/getLiquidity see post-edit state.
        _syncSlot0FromEngine(id, engine, poolSlot0[id].protocolFee());
        poolLiquidity[id] = engine.getLiquidity(id);

        (BalanceDelta hookDelta, BalanceDelta feesHookDelta) = PluginDispatcher.dispatchAfterModifyLiquidity(
            key.plugin, permissions, msg.sender, key, params, callerDelta, feesAccrued, hookData
        );

        if (BalanceDelta.unwrap(hookDelta) != 0) {
            _validateHookDelta(key.plugin, hookDelta.amount0(), callerDelta.amount0());
            _validateHookDelta(key.plugin, hookDelta.amount1(), callerDelta.amount1());
            callerDelta = callerDelta.add(hookDelta);
        }

        if (BalanceDelta.unwrap(feesHookDelta) != 0) {
            _validateFeesHookDelta(key.plugin, feesHookDelta.amount0(), feesAccrued.amount0());
            _validateFeesHookDelta(key.plugin, feesHookDelta.amount1(), feesAccrued.amount1());
            feesAccrued = feesAccrued.sub(feesHookDelta);
            _redistributeConfiscatedFees(
                key, engine, uint256(uint128(feesHookDelta.amount0())), uint256(uint128(feesHookDelta.amount1()))
            );
        }

        BalanceDelta netCallerDelta = callerDelta.sub(feesAccrued);

        if (netCallerDelta.amount0() != 0) {
            vault.accountDelta(msg.sender, key.currency0, -netCallerDelta.amount0());
        }
        if (netCallerDelta.amount1() != 0) {
            vault.accountDelta(msg.sender, key.currency1, -netCallerDelta.amount1());
        }

        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
    }

    /// @inheritdoc IPoolManager
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
        // Delisting must disable hooks on already-initialized pools.
        _requirePluginAllowed(key.plugin);

        uint24 fee =
            PluginDispatcher.dispatchBeforeSwap(key.plugin, pluginPermissions[id], msg.sender, key, params, hookData);
        if (fee == 0) fee = key.fee;
        // 100% fee (1e6) bricks swaps in engines; reject equality as well as overflow.
        if (fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(fee);

        uint24 protocolFee = slot0.protocolFee();
        ICurveEngine engine = getCurveEngine(key.curveType);
        {
            uint256 protocolFeeAmount;
            (swapDelta, protocolFeeAmount) = engine.swap(key, params, fee, protocolFee);
            if (protocolFeeAmount > 0) {
                protocolFeesAccrued[params.zeroForOne ? key.currency0 : key.currency1] += protocolFeeAmount;
            }
        }

        // Sync before afterSwap so plugins (e.g. LVR oracle) read post-swap tick/liquidity.
        _syncSlot0FromEngine(id, engine, protocolFee);
        poolLiquidity[id] = engine.getLiquidity(id);

        swapDelta = _applySwapHookDelta(key, params, swapDelta, hookData);

        if (swapDelta.amount0() != 0) {
            vault.accountDelta(msg.sender, key.currency0, -swapDelta.amount0());
        }
        if (swapDelta.amount1() != 0) {
            vault.accountDelta(msg.sender, key.currency1, -swapDelta.amount1());
        }

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

    function _applySwapHookDelta(
        PoolKey memory key,
        SwapParams memory params,
        BalanceDelta swapDelta,
        bytes calldata hookData
    ) internal returns (BalanceDelta) {
        int128 hookDeltaSpecified = PluginDispatcher.dispatchAfterSwap(
            key.plugin, pluginPermissions[key.toId()], msg.sender, key, params, swapDelta, hookData
        );
        if (hookDeltaSpecified == 0) return swapDelta;

        int128 referenceAmount = params.zeroForOne ? swapDelta.amount0() : swapDelta.amount1();
        _validateHookDelta(key.plugin, hookDeltaSpecified, referenceAmount);
        if (params.zeroForOne) {
            return toBalanceDelta(swapDelta.amount0() + hookDeltaSpecified, swapDelta.amount1());
        }
        return toBalanceDelta(swapDelta.amount0(), swapDelta.amount1() + hookDeltaSpecified);
    }

    function _syncSlot0FromEngine(PoolId id, ICurveEngine engine, uint24 protocolFee) internal {
        Slot0 engineSlot0 = engine.getSlot0(id);
        poolSlot0[id] = Slot0Library.pack(
            engineSlot0.sqrtPriceX96(), engineSlot0.tick(), protocolFee, engineSlot0.dynamicFee(), true
        );
    }

    /// @inheritdoc IPoolManager
    function setProtocolFee(PoolKey memory key, uint24 protocolFee) external override onlyOwner {
        if (protocolFee > ProtocolFeeLib.MAX_PROTOCOL_FEE) revert PoolErrors.InvalidProtocolFee(protocolFee);
        PoolId id = key.toId();
        Slot0 slot0 = poolSlot0[id];
        if (!slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        poolSlot0[id] = slot0.setProtocolFee(protocolFee);
        emit ProtocolFeeUpdated(id, protocolFee);
    }

    /// @inheritdoc IPoolManager
    function collectProtocolFees(Currency currency, address recipient, uint256 amount)
        external
        override
        returns (uint256 collected)
    {
        if (msg.sender != protocolFeeController) revert PoolErrors.InvalidProtocolFeeController();
        if (recipient == address(0)) revert VaultErrors.Unauthorized();

        uint256 accrued = protocolFeesAccrued[currency];
        collected = amount > accrued ? accrued : amount;
        if (collected == 0) return 0;

        protocolFeesAccrued[currency] = accrued - collected;
        vault.accountDelta(recipient, currency, SafeCastLib.toInt256(collected));
        emit ProtocolFeesCollected(currency, recipient, collected);
    }

    /// @inheritdoc IPoolManager
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        override
        onlyUnlocked
        returns (BalanceDelta delta)
    {
        PoolId id = key.toId();
        _checkCircuitBreaker(id, key.curveType);
        if (!poolSlot0[id].isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        // Delisting must disable donate hooks on already-initialized pools.
        _requirePluginAllowed(key.plugin);

        PluginDispatcher.dispatchBeforeDonate(
            key.plugin, pluginPermissions[id], msg.sender, key, amount0, amount1, hookData
        );

        if (amount0 != 0) {
            vault.accountDelta(msg.sender, key.currency0, -SafeCastLib.toInt256(amount0));
        }
        if (amount1 != 0) {
            vault.accountDelta(msg.sender, key.currency1, -SafeCastLib.toInt256(amount1));
        }

        ICurveEngine engine = getCurveEngine(key.curveType);
        engine.donate(key, amount0, amount1);

        delta = toBalanceDelta(
            SafeCastLib.toInt128(SafeCastLib.toInt256(amount0)), SafeCastLib.toInt128(SafeCastLib.toInt256(amount1))
        );
        emit Donate(id, msg.sender, amount0, amount1);

        PluginDispatcher.dispatchAfterDonate(
            key.plugin, pluginPermissions[id], msg.sender, key, amount0, amount1, hookData
        );
    }

    /// @inheritdoc IPoolManager
    function getSlot0(PoolId id) external view override returns (Slot0) {
        return poolSlot0[id];
    }

    /// @inheritdoc IPoolManager
    function getLiquidity(PoolId id) external view override returns (uint128) {
        return poolLiquidity[id];
    }
}
