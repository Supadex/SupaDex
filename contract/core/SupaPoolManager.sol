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
 * BIN_AMM pools are enabled again: ADR-0006 (multi-bin engine) supersedes the ADR-0004 gate.
 */
contract SupaPoolManager is IPoolManager {
    using Slot0Library for Slot0;

    uint24 internal constant MAX_FEE_PIPS = 1_000_000;

    /**
     * @notice I-01 redesign (2026-11-27): hard cap on a pool's configured
     * afterSwap haircut (1_000 bps = 10% of the unspecified leg per swap).
     * Same precedent as `DynamicFeeLib.MAX_FEE`.
     */
    uint16 internal constant MAX_HOOK_HAIRCUT_BPS = 1_000;

    /// @notice I-01 redesign (2026-11-27): basis-point denominator for hook-delta splits.
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /**
     * @notice ADR-0006: BinAMM is a real multi-bin engine (price moves bin to bin); BIN_AMM pools are enabled.
     * @dev Kept as a (virtual) view so integrators and the deploy verifier can assert the curve set, and so a
     * future redeploy can gate a curve again without changing the ABI. Supersedes the ADR-0004 gate.
     */
    function binAmmEnabled() public pure virtual returns (bool) {
        return true;
    }

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
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

    /**
     * @notice Tokens attributed to a pool, per currency (M-01). Outflows cannot exceed this balance,
     * so one pool cannot pay out another pool's reserves from the shared vault.
     * @dev Not a UUPS layout: PoolManager is immutable and redeployed. Protocol fees are booked outside
     * this pot (`protocolFeesAccrued`) at the moment they are split off the swap input.
     */
    mapping(PoolId => mapping(Currency => uint256)) public poolReserves;

    /**
     * @notice I-01 redesign (2026-11-27): per-pool afterSwap hook-delta
     * configuration. Default (never set) is all zeros: the feature is
     * disabled on the pool. Append-only storage (manager is not upgradeable).
     * @dev Internal mapping + explicit `hookDeltaConfigs` getter below: a
     * public struct mapping's auto-getter returns a flat tuple, which does
     * not satisfy the interface's `returns (HookDeltaConfig memory)`.
     */
    mapping(PoolId => HookDeltaConfig) internal _hookDeltaConfigs;

    /**
     * @notice I-01 redesign (2026-11-27): accrued hook-beneficiary fees, per
     * beneficiary per currency. Booked by moving the beneficiary share OUT of
     * the pool pot at distribution time (same pattern as
     * `protocolFeesAccrued` via `_moveToProtocol`), so the global invariant
     * `sum(poolReserves) + protocolFeesAccrued + sum(hookBeneficiaryFees) <=
     * reservesOf` counts every token exactly once. Collectable only by the
     * beneficiary themself via `collectHookFees`.
     * @dev Internal mapping + explicit `hookBeneficiaryFees` getter below (see
     * `_hookDeltaConfigs`).
     */
    mapping(address => mapping(Currency => uint256)) internal _hookBeneficiaryFees;

    /// @inheritdoc IPoolManager
    function hookDeltaConfigs(PoolId id) external view override returns (HookDeltaConfig memory) {
        return _hookDeltaConfigs[id];
    }

    /// @inheritdoc IPoolManager
    function hookBeneficiaryFees(address beneficiary, Currency currency) external view override returns (uint256) {
        return _hookBeneficiaryFees[beneficiary][currency];
    }

    /// @notice Nominated owner. Becomes `owner` only after `acceptOwnership`.
    address public pendingOwner;

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
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert VaultErrors.Unauthorized();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
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
     * @dev Liquidity-side hook deltas (afterModifyLiquidity principal / fee
     * haircuts) may only haircut user *credits* (negative reference):
     * - `referenceAmount > 0` (user debit): any non-zero hook underpays while engine state advances → reject.
     * - `referenceAmount < 0` (user credit): only non-negative haircuts with `hook <= |reference|`.
     * - `referenceAmount == 0`: non-zero hooks create value from nothing → reject.
     *
     * @notice I-01 (internal pre-audit 2026-11-26), RESOLVED by the 2026-11-27
     * redesign: the swap-side afterSwap path no longer uses this function —
     * `_applySwapHookDelta` now validates the haircut against the UNSPECIFIED
     * leg with its own per-pool cap and distributes it per the pool's
     * `HookDeltaConfig` (§4.4–§5 of the redesign doc). This function remains
     * the validator for the liquidity side only, where the credit-only rule
     * above is still the correct semantics.
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
            // No LPs left to donate to. Move the retained tokens out of this pool's pot so they cannot
            // also be paid out as liquidity, then book them as protocol fees.
            _moveToProtocol(key.toId(), key.currency0, amount0);
            _moveToProtocol(key.toId(), key.currency1, amount1);
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
        return _initialize(key, sqrtPriceX96, "");
    }

    /// @inheritdoc IPoolManager
    function initializeWithParams(
        PoolKey memory key,
        uint160 sqrtPriceX96,
        bytes calldata initParams,
        bytes calldata /* hookData */
    )
        external
        override
        returns (int24 tick)
    {
        return _initialize(key, sqrtPriceX96, initParams);
    }

    function _initialize(PoolKey memory key, uint160 sqrtPriceX96, bytes memory initParams)
        internal
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
        tick = engine.initialize(key, sqrtPriceX96, initParams);
        if (key.curveType == CurveType.STABLE_AMM) {
            // APUS-SUPADEX-026: STABLE pools always start at the engine's normalised peg; the caller's price is ignored.
            sqrtPriceX96 = engine.getSlot0(id).sqrtPriceX96();
        }

        Slot0 initialSlot0 = Slot0Library.pack(sqrtPriceX96, tick, 0, key.fee, true);
        poolSlot0[id] = initialSlot0;

        _emitInitialize(id, key, sqrtPriceX96, tick);

        PluginDispatcher.dispatchAfterInitialize(key.plugin, permissions, msg.sender, key, sqrtPriceX96, tick);
    }

    function _emitInitialize(PoolId id, PoolKey memory key, uint160 sqrtPriceX96, int24 tick) internal {
        emit Initialize(
            id,
            key.currency0,
            key.currency1,
            key.fee,
            key.tickSpacing,
            key.plugin,
            sqrtPriceX96,
            tick,
            uint8(key.curveType)
        );
    }

    /// @inheritdoc IPoolManager
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        override
        onlyUnlocked
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        uint32 permissions = _modifyLiquidityPermissions(key, id, params.liquidityDelta);

        PluginDispatcher.dispatchBeforeModifyLiquidity(key.plugin, permissions, msg.sender, key, params, hookData);

        ICurveEngine engine = getCurveEngine(key.curveType);
        (callerDelta, feesAccrued) = engine.modifyLiquidity(key, params, msg.sender);

        // Sync before after-hooks so plugins reading getSlot0/getLiquidity see post-edit state.
        _syncSlot0FromEngine(id, engine, poolSlot0[id].protocolFee());
        poolLiquidity[id] = engine.getLiquidity(id);

        (callerDelta, feesAccrued) =
            _afterModifyLiquidity(key, params, permissions, engine, callerDelta, feesAccrued, hookData);

        _accountCallerDelta(key, callerDelta.sub(feesAccrued));

        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
    }

    /**
     * @dev Withdraw-only pause + delisted-plugin semantics for modifyLiquidity (split out to keep the legacy
     * codegen pipeline, used by `forge coverage`, under the stack limit — Issue 5).
     * Removals / fee pokes (liquidityDelta <= 0) are always allowed. APUS-SUPADEX-011: a delisted plugin's
     * hooks are skipped on removals so LP principal is never trapped; adds revert.
     */
    function _modifyLiquidityPermissions(PoolKey memory key, PoolId id, int256 liquidityDelta)
        internal
        view
        returns (uint32 permissions)
    {
        if (liquidityDelta > 0) _checkCircuitBreaker(id, key.curveType);
        if (!poolSlot0[id].isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        permissions = pluginPermissions[id];
        if (liquidityDelta > 0) {
            _requirePluginAllowed(key.plugin);
        } else if (!_isPluginAllowed(key.plugin)) {
            permissions = 0;
        }
    }

    function _afterModifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint32 permissions,
        ICurveEngine engine,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal returns (BalanceDelta, BalanceDelta) {
        (BalanceDelta hookDelta, BalanceDelta feesHookDelta) = PluginDispatcher.dispatchAfterModifyLiquidity(
            key.plugin, permissions, msg.sender, key, params, callerDelta, feesAccrued, hookData
        );

        if (BalanceDelta.unwrap(hookDelta) != 0) {
            _validateHookDelta(key.plugin, hookDelta.amount0(), callerDelta.amount0());
            _validateHookDelta(key.plugin, hookDelta.amount1(), callerDelta.amount1());
            callerDelta = callerDelta.add(hookDelta);
            // APUS-SUPADEX-024: a principal haircut retained by a delta-returning plugin used to stay in the vault's
            // reservesOf, owned by no one and not sweepable. It is now redistributed like confiscated fees: donated
            // to in-range LPs, or booked as protocol fees when the pool has no active liquidity. The amounts are
            // validated above as non-negative and bounded by the LP's credit.
            _redistributeConfiscatedFees(
                key, engine, uint256(uint128(hookDelta.amount0())), uint256(uint128(hookDelta.amount1()))
            );
        }

        if (BalanceDelta.unwrap(feesHookDelta) != 0) {
            _validateFeesHookDelta(key.plugin, feesHookDelta.amount0(), feesAccrued.amount0());
            _validateFeesHookDelta(key.plugin, feesHookDelta.amount1(), feesAccrued.amount1());
            feesAccrued = feesAccrued.sub(feesHookDelta);
            _redistributeConfiscatedFees(
                key, engine, uint256(uint128(feesHookDelta.amount0())), uint256(uint128(feesHookDelta.amount1()))
            );
        }
        return (callerDelta, feesAccrued);
    }

    /// @dev Caller owes positive deltas (vault debit = negative account delta) and is owed negative ones.
    /// Positive deltas grow this pool's recorded reserves; negative deltas shrink them and revert if the
    /// pool does not hold the tokens (M-01).
    function _accountCallerDelta(PoolKey memory key, BalanceDelta delta) internal {
        _applyPoolLeg(key.toId(), key.currency0, delta.amount0());
        _applyPoolLeg(key.toId(), key.currency1, delta.amount1());
    }

    function _applyPoolLeg(PoolId id, Currency currency, int128 delta) internal {
        if (delta == 0) return;
        if (delta > 0) {
            poolReserves[id][currency] += uint256(uint128(delta));
        } else {
            uint256 owed = uint256(uint128(-delta));
            uint256 held = poolReserves[id][currency];
            if (held < owed) revert PoolErrors.PoolInsolvent(id, currency, owed, held);
            poolReserves[id][currency] = held - owed;
        }
        vault.accountDelta(msg.sender, currency, -int256(delta));
    }

    /// @dev Moves `amount` from the pool pot into the global protocol-fee pot. No vault delta: the tokens
    /// are already in the vault and become withdrawable only via `collectProtocolFees`.
    function _moveToProtocol(PoolId id, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        uint256 held = poolReserves[id][currency];
        if (held < amount) revert PoolErrors.PoolInsolvent(id, currency, amount, held);
        poolReserves[id][currency] = held - amount;
        protocolFeesAccrued[currency] += amount;
    }

    /// @dev keccak256("supadex.poolmanager.lastSwapFee") - 1
    bytes32 internal constant LAST_SWAP_FEE_SLOT = 0x0a138a554f16671ce335381b23c2354412de957b3ba305f936d3c64bc9f965d7;

    /// @inheritdoc IPoolManager
    function lastSwapFee() external view override returns (uint24 fee) {
        assembly ("memory-safe") {
            fee := tload(LAST_SWAP_FEE_SLOT)
        }
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
        assembly ("memory-safe") {
            tstore(LAST_SWAP_FEE_SLOT, fee)
        }

        uint24 protocolFee = slot0.protocolFee();
        ICurveEngine engine = getCurveEngine(key.curveType);
        uint256 protocolFeeAmount;
        (swapDelta, protocolFeeAmount) = engine.swap(key, params, fee, protocolFee);

        // Sync before afterSwap so plugins (e.g. LVR oracle) read post-swap tick/liquidity.
        _syncSlot0FromEngine(id, engine, protocolFee);
        poolLiquidity[id] = engine.getLiquidity(id);

        // I-01 redesign (§4.5): the hook haircuts the UNSPECIFIED leg only;
        // the specified leg is sacred. Distribution runs AFTER accounting so
        // every distributed share is covered by pool-pot balance.
        (BalanceDelta adjustedDelta, Currency haircutCurrency, uint256 haircut) =
            _applySwapHookDelta(key, params, swapDelta, hookData);
        swapDelta = adjustedDelta;

        // Credit the full input (fees included) to the pool, then move the protocol's share out of the pot.
        _accountCallerDelta(key, swapDelta);
        if (haircut > 0) _distributeHookHaircut(key, engine, haircutCurrency, haircut);
        _moveToProtocol(id, params.zeroForOne ? key.currency0 : key.currency1, protocolFeeAmount);

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
     * @notice I-01 redesign (2026-11-27): the afterSwap hook returns a haircut
     * on the UNSPECIFIED leg only — the specified leg is never read or written
     * here. SupaDEX's `amountSpecified` convention is INVERTED vs Uniswap v4
     * (`> 0` = exactInput, `< 0` = exactOutput), so the unspecified leg is the
     * output leg for exactInput and the input leg for exactOutput. The haircut
     * is applied with one uniform rule — add `H` to the unspecified leg — which
     * shrinks the user's credit (exactInput) or grows their debit (exactOutput)
     * by exactly `H`, leaving the specified amount exact in both modes.
     * @dev Validation is §4.4 of the redesign doc, in order: (1) `H == 0` fast
     * path, (2) `canPluginReturnDelta` gate, (3) negative reverts, (4) pool
     * must be configured, (5) per-swap cap `floor(|S| * maxHaircutBps /
     * 10_000)`, (6) absolute bound `H <= |S|`, (7) int128 headroom on the
     * adjusted leg. All failures revert the whole swap atomically.
     * @return adjusted The engine delta with the haircut applied to the
     * unspecified leg (identical to the engine delta when `H == 0`).
     * @return haircutCurrency Currency of the unspecified leg (the haircut).
     * @return haircut The haircut amount `H` (0 when the hook returned 0).
     */
    function _applySwapHookDelta(
        PoolKey memory key,
        SwapParams memory params,
        BalanceDelta swapDelta,
        bytes calldata hookData
    ) internal returns (BalanceDelta adjusted, Currency haircutCurrency, uint256 haircut) {
        int128 hookDeltaUnspecified = PluginDispatcher.dispatchAfterSwap(
            key.plugin, pluginPermissions[key.toId()], msg.sender, key, params, swapDelta, hookData
        );
        if (hookDeltaUnspecified == 0) {
            return (swapDelta, _unspecifiedLegCurrency(key, params), 0);
        }

        // (2) Plugin gate: only a whitelisted plugin with canReturnDelta may take.
        if (!pluginWhitelist.canPluginReturnDelta(key.plugin)) {
            revert PoolErrors.HookDeltaNotAllowed(key.plugin);
        }
        // (3) Hooks only take, never give.
        if (hookDeltaUnspecified < 0) revert PoolErrors.HookDeltaCapExceeded();

        // (4) Pool gate: the feature is off by default; governance enables it per pool.
        PoolId id = key.toId();
        HookDeltaConfig memory cfg = _hookDeltaConfigs[id];
        if (cfg.maxHaircutBps == 0) revert PoolErrors.HookDeltaNotEnabled(id);

        bool exactInput = params.amountSpecified > 0;
        int128 unspecified = _unspecifiedLegAmount(params, swapDelta);
        haircutCurrency = _unspecifiedLegCurrency(key, params);
        uint256 absUnspecified = _abs128(unspecified);
        haircut = uint256(uint128(hookDeltaUnspecified));

        // (5) Per-swap cap. A dust leg floors the cap to 0 (no skimming dust).
        uint256 cap = absUnspecified * cfg.maxHaircutBps / BPS_DENOMINATOR;
        if (haircut > cap) revert PoolErrors.HookDeltaCapExceeded();
        // (6) Absolute bound (defence in depth: the cap must never consume the whole leg).
        if (haircut > absUnspecified) revert PoolErrors.HookDeltaCapExceeded();
        // (7) int128 headroom on the adjusted leg, checked uniformly in int256
        // (exactInput legs shrink toward zero so this only binds exactOutput).
        int256 adjustedUnspecified = int256(unspecified) + int256(haircut);
        if (adjustedUnspecified > int256(type(int128).max) || adjustedUnspecified < int256(type(int128).min)) {
            revert PoolErrors.HookDeltaCapExceeded();
        }

        int128 adjustedLeg = int128(adjustedUnspecified);
        if (exactInput) {
            if (params.zeroForOne) {
                adjusted = toBalanceDelta(swapDelta.amount0(), adjustedLeg);
            } else {
                adjusted = toBalanceDelta(adjustedLeg, swapDelta.amount1());
            }
        } else {
            if (params.zeroForOne) {
                adjusted = toBalanceDelta(adjustedLeg, swapDelta.amount1());
            } else {
                adjusted = toBalanceDelta(swapDelta.amount0(), adjustedLeg);
            }
        }
    }

    /// @dev The unspecified leg of a swap: the output leg for exactInput
    /// (`amountSpecified > 0`), the input leg for exactOutput (`< 0`).
    function _unspecifiedLegAmount(SwapParams memory params, BalanceDelta swapDelta) internal pure returns (int128) {
        if (params.amountSpecified > 0) {
            return params.zeroForOne ? swapDelta.amount1() : swapDelta.amount0();
        }
        return params.zeroForOne ? swapDelta.amount0() : swapDelta.amount1();
    }

    /// @dev Currency of the unspecified leg (see `_unspecifiedLegAmount`).
    function _unspecifiedLegCurrency(PoolKey memory key, SwapParams memory params) internal pure returns (Currency) {
        if (params.amountSpecified > 0) {
            return params.zeroForOne ? key.currency1 : key.currency0;
        }
        return params.zeroForOne ? key.currency0 : key.currency1;
    }

    /**
     * @notice I-01 redesign (§5.2): splits a haircut exactly across the LP /
     * protocol / beneficiary shares of a pool config. `lpShare` and
     * `protocolShare` are floored; the remainder (0–2 wei) goes to the
     * beneficiary, or — when the beneficiary share is zero — to the LP share
     * (or the protocol share if the LP share is zero). A zero-bps recipient
     * therefore receives exactly zero, and the three shares always sum exactly
     * to `haircut`.
     * @dev Public pure (not internal) so forge fuzz and Halmos can verify the
     * exact-conservation property directly against this production code.
     */
    function _splitHookHaircut(uint256 haircut, HookDeltaConfig memory cfg)
        public
        pure
        returns (uint256 lpShare, uint256 protocolShare, uint256 beneficiaryShare)
    {
        lpShare = haircut * cfg.lpBps / BPS_DENOMINATOR;
        protocolShare = haircut * cfg.protocolBps / BPS_DENOMINATOR;
        beneficiaryShare = haircut - lpShare - protocolShare;
        if (cfg.beneficiaryBps == 0 && beneficiaryShare > 0) {
            // One of lpBps / protocolBps is non-zero (the splits sum to 10_000).
            if (cfg.lpBps > 0) lpShare += beneficiaryShare;
            else protocolShare += beneficiaryShare;
            beneficiaryShare = 0;
        }
    }

    /**
     * @notice I-01 redesign (§5.3): routes a validated haircut after accounting
     * (§4.5), so every share is covered by pool-pot balance. The LP share is
     * donated to in-range LPs via the existing Anti-JIT path
     * (`_redistributeConfiscatedFees`, which falls back to protocol when the
     * pool has no liquidity); the protocol and beneficiary shares are moved
     * OUT of the pool pot into their named accruals, so the global invariant
     * `sum(poolReserves) + protocolFeesAccrued + sum(hookBeneficiaryFees) <=
     * reservesOf` counts every token exactly once.
     */
    function _distributeHookHaircut(PoolKey memory key, ICurveEngine engine, Currency currency, uint256 haircut)
        internal
    {
        PoolId id = key.toId();
        HookDeltaConfig memory cfg = _hookDeltaConfigs[id];
        (uint256 lpShare, uint256 protocolShare, uint256 beneficiaryShare) = _splitHookHaircut(haircut, cfg);
        if (lpShare > 0) {
            if (Currency.unwrap(currency) == Currency.unwrap(key.currency0)) {
                _redistributeConfiscatedFees(key, engine, lpShare, 0);
            } else {
                _redistributeConfiscatedFees(key, engine, 0, lpShare);
            }
        }
        if (protocolShare > 0) _moveToProtocol(id, currency, protocolShare);
        if (beneficiaryShare > 0) _moveToBeneficiary(id, cfg.beneficiary, currency, beneficiaryShare);
        emit HookDeltaApplied(id, currency, haircut, lpShare, protocolShare, beneficiaryShare);
    }

    /// @dev Moves `amount` from the pool pot into a hook beneficiary's accrual.
    /// Mirrors `_moveToProtocol`: no vault delta (the tokens are already in the
    /// vault); the accrual is the claim that lets the beneficiary collect them.
    function _moveToBeneficiary(PoolId id, address beneficiary, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        uint256 held = poolReserves[id][currency];
        if (held < amount) revert PoolErrors.PoolInsolvent(id, currency, amount, held);
        poolReserves[id][currency] = held - amount;
        _hookBeneficiaryFees[beneficiary][currency] += amount;
    }

    /// @inheritdoc IPoolManager
    function setHookDeltaConfig(PoolKey memory key, HookDeltaConfig calldata cfg) external override onlyOwner {
        if (cfg.maxHaircutBps > MAX_HOOK_HAIRCUT_BPS) revert PoolErrors.InvalidHookDeltaConfig();
        if (uint256(cfg.lpBps) + uint256(cfg.protocolBps) + uint256(cfg.beneficiaryBps) != BPS_DENOMINATOR) {
            revert PoolErrors.InvalidHookDeltaConfig();
        }
        if ((cfg.beneficiaryBps > 0) != (cfg.beneficiary != address(0))) {
            revert PoolErrors.InvalidHookDeltaConfig();
        }
        PoolId id = key.toId();
        _hookDeltaConfigs[id] = cfg;
        emit HookDeltaConfigSet(id, cfg.maxHaircutBps, cfg.lpBps, cfg.protocolBps, cfg.beneficiaryBps, cfg.beneficiary);
    }

    /// @inheritdoc IPoolManager
    function collectHookFees(Currency currency, address recipient, uint256 amount)
        external
        override
        returns (uint256 collected)
    {
        if (recipient == address(0)) revert VaultErrors.Unauthorized();
        // The accrual is keyed by beneficiary, so only the beneficiary
        // themself can collect their own accrual. A caller with no accrual —
        // i.e. never named as a beneficiary, or already fully collected —
        // reverts rather than silently collecting zero (unlike
        // `collectProtocolFees`, which returns 0 on an empty accrual).
        uint256 accrued = _hookBeneficiaryFees[msg.sender][currency];
        if (accrued == 0) revert VaultErrors.Unauthorized();

        collected = amount > accrued ? accrued : amount;
        // accountDelta is int128-bounded. A larger balance is collected across calls.
        uint256 cap = uint256(uint128(type(int128).max));
        if (collected > cap) collected = cap;

        _hookBeneficiaryFees[msg.sender][currency] = accrued - collected;
        vault.accountDelta(recipient, currency, int256(collected));
        emit HookBeneficiaryFeesCollected(msg.sender, currency, recipient, collected);
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
        // accountDelta is int128-bounded. A larger balance is collected across calls.
        uint256 cap = uint256(uint128(type(int128).max));
        if (collected > cap) collected = cap;

        protocolFeesAccrued[currency] = accrued - collected;
        vault.accountDelta(recipient, currency, int256(collected));
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
            int128 a0 = SafeCastLib.toInt128(amount0);
            poolReserves[id][key.currency0] += uint256(uint128(a0));
            vault.accountDelta(msg.sender, key.currency0, -int256(a0));
        }
        if (amount1 != 0) {
            int128 a1 = SafeCastLib.toInt128(amount1);
            poolReserves[id][key.currency1] += uint256(uint128(a1));
            vault.accountDelta(msg.sender, key.currency1, -int256(a1));
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
