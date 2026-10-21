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
import {PoolKey, CurveType} from "../../types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../types/PoolId.sol";
import {BalanceDelta} from "../../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../types/Slot0.sol";
import {VolatilityTWAPOracle} from "./VolatilityTWAPOracle.sol";
import {IAggregatorV3} from "../../interfaces/external/IAggregatorV3.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";
import {Currency, CurrencyLibrary} from "../../types/Currency.sol";

/**
 * @title LVRShieldPlugin
 * @notice Native adaptive-fee plugin. Two layered signals (ADR-0003, superseded in part by ADR-0009):
 *         1. ENDOGENOUS: realised |Δtick| of this pool over the last `VOLATILITY_WINDOW` seconds
 *            (VolatilityTWAPOracle), with half-life decay. Applies to every curve: CLAMM ticks, STABLE
 *            marginal-price ticks, and BIN active ids normalised to ~1bp ticks (id × binStep).
 *         2. EXOGENOUS (optional, per pool, governance-configured): a Chainlink-style aggregator. When the pool
 *            price deviates from the feed by more than `deadbandBps`, swaps in the ARBITRAGE direction (those that
 *            move the pool toward the feed) pay `base + alpha × (deviation − deadband)`. Swaps in the other
 *            direction pay only the endogenous fee.
 * @dev Trust assumptions / failure handling (ADR-0009):
 *      - The feed is trusted for liveness/accuracy only up to the checks below; it is NOT trusted to never fail.
 *      - Every read is a gas-capped staticcall: bad return size, revert, answer <= 0, updatedAt == 0, updatedAt in
 *        the future, age > heartbeat, conversion overflow, or deviation > maxDeviationBps ⇒ the swap is NOT
 *        blocked; the fee is floored at `fallbackFeePips` and `LVROracleFallback` is emitted.
 *      - A caller cannot force the fallback by starving the feed call of gas: if less than the full oracle gas
 *        stipend is available the swap reverts instead.
 *      - The oracle surcharge does not feed back into `lastFee` (no decay carry-over onto non-arbitrage swaps).
 *      - Manipulation resistance is bounded by the feed: this plugin makes no claim beyond "arbitrage against a
 *        correct, fresh feed is surcharged". Endogenous signal remains manipulable (see ADR-0003).
 *      - Plugin min/max fee bounds (pips, 1e6 = 100%) are authoritative after every computation.
 *      - L2 sequencer (Edith 9-A): with a Chainlink L2 sequencer-uptime feed set, the price feed is used only while
 *        the sequencer is up AND has been up for more than `sequencerGracePeriod` (>= 1 h); otherwise fallback
 *        reason 7. On known L2 chain ids `setOracleConfig` refuses to configure a feed until the uptime feed is set.
 *      - Acceptable feeds (Edith 9-B, governance runbook + script/OracleConfigCheck.sol): official Chainlink Data
 *        Feed proxies on the same chain, direct pair to the pool's assets. Never a DEX TWAP/spot price.
 */
contract LVRShieldPlugin is BaseHook, IPluginEvents {
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;
    using CurrencyLibrary for Currency;

    uint24 internal constant MAX_FEE_PIPS = 1_000_000;
    /// @notice APUS-SUPADEX-009: hard cap for plugin min/max fee bounds (= DynamicFeeLib.MAX_FEE, 10%).
    uint24 public constant FEE_CAP_PIPS = DynamicFeeLib.MAX_FEE;
    /// @dev Observation ring capacity grown at pool init for usable TWAP history.
    uint16 internal constant ORACLE_CARDINALITY = 64;
    /// @dev Look-back window for the |Δtick| signal (one Ethereum block).
    uint32 internal constant VOLATILITY_WINDOW = 12;
    /// @dev Only this address may perform the first `setRoles` call (prevents a deploy-time front-run).
    address public immutable deployer;

    IVolatilityTWAPOracle public immutable oracle;
    ISupaRoles public roles;

    struct PoolLVRState {
        uint24 baseFee;
        uint24 lastFee;
        uint32 lastSwapTimestamp;
        int24 lastTick;
        uint32 decayHalfLife;
        uint24 volatilityAlpha;
        uint24 minFeePips;
        uint24 maxFeePips;
        bool isInitialized;
    }

    mapping(PoolId => PoolLVRState) public poolLVRStates;

    /// @dev ADR-0009 oracle constants.
    uint256 internal constant Q96 = 2 ** 96;
    uint256 public constant ORACLE_CALL_GAS = 60_000;
    uint32 public constant MIN_HEARTBEAT = 60;
    uint32 public constant MAX_HEARTBEAT = 2 days;
    uint16 public constant MAX_DEVIATION_CAP_BPS = 5_000; // 50%
    uint256 internal constant MAX_ANSWER = 2 ** 100;
    /// @notice Sequencer-uptime grace bounds (Edith 9-A: >= 1 h after a restart before the feed is trusted again).
    uint32 public constant MIN_SEQUENCER_GRACE = 1 hours;
    uint32 public constant MAX_SEQUENCER_GRACE = 1 days;

    /// @notice Chainlink L2 sequencer-uptime feed (answer 0 = up, 1 = down; startedAt = last status change).
    IAggregatorV3 public sequencerUptimeFeed;
    uint32 public sequencerGracePeriod;

    event SequencerUptimeFeedSet(address indexed feed, uint32 gracePeriod);

    /// @notice ADR-0009 per-pool external price feed. Price convention: token1 per token0 in raw units
    /// (same as the pool's sqrtPriceX96²). `invert` = the feed quotes token0 per token1.
    struct OracleConfig {
        IAggregatorV3 feed;
        uint32 heartbeat;
        uint16 deviationAlphaBps; // share of (deviation − deadband) charged, 10_000 = 100%
        uint16 deadbandBps; // ignore deviations below this (>= the feed's own deviation threshold)
        uint16 maxDeviationBps; // above this the feed or pool is considered unsafe ⇒ fallback
        uint24 fallbackFeePips; // fee floor whenever the feed is unusable
        uint8 feedDecimals;
        uint8 decimals0;
        uint8 decimals1;
        bool invert;
    }

    mapping(PoolId => OracleConfig) internal _oracleConfigs;

    /// @dev APUS-SUPADEX-009: fee parameters are governance-only (`roles.owner()`, the timelock in production);
    /// the un-timelocked OPERATOR role has no power here.
    modifier onlyRolesOwner() {
        // Unset roles ⇒ no one may change parameters.
        if (address(roles) == address(0) || msg.sender != roles.owner()) {
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
        deployer = msg.sender;
    }

    /**
     * @notice Wires the operator registry (callable once by current roles owner or unset).
     * @dev Zero address rejected so setters cannot be re-opened as permissionless.
     */
    function setRoles(ISupaRoles _roles) external {
        if (address(_roles) == address(0)) revert PluginErrors.PluginPermissionDenied(address(this), 0);
        if (address(roles) == address(0) ? msg.sender != deployer : msg.sender != roles.owner()) {
            revert PluginErrors.PluginPermissionDenied(address(this), 0);
        }
        roles = _roles;
    }

    function getPluginPermissions() public pure override returns (uint32 permissions) {
        return
            PluginDispatcher.AFTER_INITIALIZE_FLAG | PluginDispatcher.BEFORE_SWAP_FLAG
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
        // ADR-0009: every curve participates; BIN ids are normalised to ~1bp ticks.
        tick = _normalizedTick(key, tick);
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
            minFeePips: minFee,
            maxFeePips: maxFee,
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
        hookData;
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];

        if (!state.isInitialized) {
            return (this.beforeSwap.selector, 0);
        }

        uint24 dynamicFee = _endogenousFee(poolId, state);
        state.lastFee = dynamicFee;
        state.lastSwapTimestamp = uint32(block.timestamp);

        OracleConfig memory cfg = _oracleConfigs[poolId];
        if (address(cfg.feed) != address(0)) {
            dynamicFee = _applyOracle(poolId, cfg, state, params.zeroForOne, dynamicFee);
        }
        return (this.beforeSwap.selector, dynamicFee);
    }

    /// @dev Endogenous (ADR-0003) fee: |Δtick| surcharge with half-life decay, clamped to plugin bounds.
    function _endogenousFee(PoolId poolId, PoolLVRState storage state) internal returns (uint24 dynamicFee) {
        uint32 currentTime = uint32(block.timestamp);
        uint32 timeElapsed = currentTime >= state.lastSwapTimestamp ? currentTime - state.lastSwapTimestamp : 0;

        uint256 volatility = oracle.getInstantaneousVolatility(poolId, VOLATILITY_WINDOW);
        // Scale volatility by alpha (100 units ~= 1 bp surcharge unit)
        uint256 scaledVol = (volatility * state.volatilityAlpha) / 100;
        if (scaledVol > type(uint24).max) scaledVol = type(uint24).max;

        dynamicFee = DynamicFeeLib.computeDynamicFee(
            state.baseFee, state.lastFee, uint24(scaledVol), timeElapsed, state.decayHalfLife
        );
        dynamicFee = _clamp(dynamicFee, state);
        emit DynamicFeeUpdated(poolId, state.baseFee, dynamicFee, uint24(scaledVol), timeElapsed);
    }

    function _clamp(uint256 fee, PoolLVRState storage state) internal view returns (uint24) {
        if (fee < state.minFeePips) return state.minFeePips;
        if (fee > state.maxFeePips) return state.maxFeePips;
        return uint24(fee);
    }

    /// @dev ADR-0009 exogenous overlay. Never reverts on feed failure (fallback floor instead).
    function _applyOracle(
        PoolId poolId,
        OracleConfig memory cfg,
        PoolLVRState storage state,
        bool zeroForOne,
        uint24 endogenousFee
    ) internal returns (uint24) {
        (uint8 reason, uint256 oracleQ96) = _readOraclePriceQ96(cfg);
        uint256 deviationBps;
        bool poolAbove;
        if (reason == 0) {
            uint256 poolQ96 = _poolPriceQ96(poolId);
            poolAbove = poolQ96 > oracleQ96;
            uint256 diff = poolAbove ? poolQ96 - oracleQ96 : oracleQ96 - poolQ96;
            deviationBps = FullMathLib.mulDiv(diff, 10_000, oracleQ96);
            if (deviationBps > cfg.maxDeviationBps) reason = 6;
        }
        if (reason != 0) {
            emit LVROracleFallback(poolId, reason);
            return _clamp(endogenousFee > cfg.fallbackFeePips ? endogenousFee : cfg.fallbackFeePips, state);
        }
        // Arbitrage direction: pool above feed ⇒ selling token0 (zeroForOne) pushes it down toward the feed.
        if (deviationBps <= cfg.deadbandBps || zeroForOne != poolAbove) return endogenousFee;

        uint256 surcharge = ((deviationBps - cfg.deadbandBps) * 100 * cfg.deviationAlphaBps) / 10_000;
        if (surcharge > FEE_CAP_PIPS) surcharge = FEE_CAP_PIPS;
        uint256 oracleFee = uint256(state.baseFee) + surcharge;
        uint24 fee = _clamp(oracleFee > endogenousFee ? oracleFee : endogenousFee, state);
        emit LVROracleSurcharge(poolId, deviationBps, uint24(surcharge), zeroForOne);
        return fee;
    }

    /// @dev Pool price (token1 per token0, raw units) in Q96. sqrtP < 2^160 ⇒ no overflow.
    function _poolPriceQ96(PoolId poolId) internal view returns (uint256) {
        uint256 sqrtP = poolManager.getSlot0(poolId).sqrtPriceX96();
        return FullMathLib.mulDiv(sqrtP, sqrtP, Q96);
    }

    /// @notice Reads and validates the feed. `reason` 0 = valid, otherwise an `LVROracleFallback` code.
    function _readOraclePriceQ96(OracleConfig memory cfg) internal view returns (uint8 reason, uint256 priceQ96) {
        // Gas-griefing guard: the caller must not be able to force the fallback by under-funding the call.
        IAggregatorV3 seq = sequencerUptimeFeed;
        uint256 calls = address(seq) == address(0) ? 1 : 2;
        if (gasleft() < calls * ((ORACLE_CALL_GAS * 64) / 63) + 5_000) {
            revert PluginErrors.PluginGasExceeded(address(this), gasleft(), calls * ORACLE_CALL_GAS);
        }
        if (calls == 2 && !_sequencerUp(seq)) return (7, 0);
        (bool ok, bytes memory ret) =
            address(cfg.feed).staticcall{gas: ORACLE_CALL_GAS}(abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!ok || ret.length != 160) return (1, 0);
        (, int256 answer,, uint256 updatedAt,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0) return (2, 0);
        if (updatedAt == 0) return (3, 0);
        if (updatedAt > block.timestamp) return (4, 0);
        if (block.timestamp - updatedAt > cfg.heartbeat) return (3, 0);
        if (uint256(answer) >= MAX_ANSWER) return (5, 0);
        priceQ96 = _scale(uint256(answer), cfg);
        if (priceQ96 == 0) return (5, 0);
    }

    /// @dev True iff the sequencer reports up (answer == 0) and has been up for MORE than the grace period.
    /// Any malformed / reverting / future-dated response counts as down (fail-safe: fallback fee, never revert).
    function _sequencerUp(IAggregatorV3 seq) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            address(seq).staticcall{gas: ORACLE_CALL_GAS}(abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!ok || ret.length != 160) return false;
        (, int256 answer, uint256 startedAt,,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        if (answer != 0) return false;
        if (startedAt == 0 || startedAt > block.timestamp) return false;
        return block.timestamp - startedAt > sequencerGracePeriod;
    }

    /// @dev raw price = answer / 10^feedDec × 10^dec1 / 10^dec0 (or its inverse), in Q96. answer < 2^100,
    /// decimals <= 18 ⇒ every intermediate product < 2^256.
    function _scale(uint256 answer, OracleConfig memory cfg) internal pure returns (uint256) {
        if (!cfg.invert) {
            return
                FullMathLib.mulDiv(answer, Q96 * 10 ** cfg.decimals1, 10 ** (uint256(cfg.feedDecimals) + cfg.decimals0));
        }
        return FullMathLib.mulDiv(10 ** (uint256(cfg.feedDecimals) + cfg.decimals1), Q96, answer * 10 ** cfg.decimals0);
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
            int24 tick = _normalizedTick(key, slot0.tick());
            state.lastTick = tick;
            uint128 liquidity = poolManager.getLiquidity(poolId);
            // Fail loud: silent catch previously hid oracle write failures.
            oracle.write(poolId, uint32(block.timestamp), tick, liquidity > 0 ? liquidity : 1);
        }

        return (this.afterSwap.selector, 0);
    }

    function setDecayHalfLife(PoolKey calldata key, uint32 newDecayHalfLife) external onlyRolesOwner {
        if (newDecayHalfLife == 0) revert PluginErrors.InvalidDecayHalfLife();
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        state.decayHalfLife = newDecayHalfLife;
        _emitParams(poolId, state);
    }

    function setVolatilityAlpha(PoolKey calldata key, uint24 newAlpha) external onlyRolesOwner {
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        state.volatilityAlpha = newAlpha;
        _emitParams(poolId, state);
    }

    function setMinFeePips(PoolKey calldata key, uint24 newMin) external onlyRolesOwner {
        if (newMin > FEE_CAP_PIPS) revert PluginErrors.InvalidFeeParameter(newMin);
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        if (newMin > state.maxFeePips) revert PluginErrors.InvalidFeeBounds(newMin, state.maxFeePips);
        state.minFeePips = newMin;
        _emitParams(poolId, state);
    }

    function setMaxFeePips(PoolKey calldata key, uint24 newMax) external onlyRolesOwner {
        if (newMax > FEE_CAP_PIPS) revert PluginErrors.InvalidFeeParameter(newMax);
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        if (state.minFeePips > newMax) revert PluginErrors.InvalidFeeBounds(state.minFeePips, newMax);
        state.maxFeePips = newMax;
        _emitParams(poolId, state);
    }

    function setDecayParameters(
        PoolKey calldata key,
        uint32 newDecayHalfLife,
        uint24 newAlpha,
        uint24 newMin,
        uint24 newMax
    ) external onlyRolesOwner {
        if (newDecayHalfLife == 0) revert PluginErrors.InvalidDecayHalfLife();
        if (newMin > FEE_CAP_PIPS) revert PluginErrors.InvalidFeeParameter(newMin);
        if (newMax > FEE_CAP_PIPS) revert PluginErrors.InvalidFeeParameter(newMax);
        if (newMin > newMax) revert PluginErrors.InvalidFeeBounds(newMin, newMax);
        PoolId poolId = key.toId();
        PoolLVRState storage state = poolLVRStates[poolId];
        if (!state.isInitialized) return;
        state.decayHalfLife = newDecayHalfLife;
        state.volatilityAlpha = newAlpha;
        state.minFeePips = newMin;
        state.maxFeePips = newMax;
        _emitParams(poolId, state);
    }

    /**
     * @notice ADR-0009: configure (or replace) the external price feed for a pool. Governance only (timelock).
     * @param feed Chainlink-style aggregator. Must have code and report decimals <= 18.
     * @param invert True when the feed quotes currency0 per currency1.
     */
    function setOracleConfig(
        PoolKey calldata key,
        IAggregatorV3 feed,
        bool invert,
        uint32 heartbeat,
        uint16 deviationAlphaBps,
        uint16 deadbandBps,
        uint16 maxDeviationBps,
        uint24 fallbackFeePips
    ) external onlyRolesOwner {
        if (address(feed) == address(0) || address(feed).code.length == 0) {
            revert PluginErrors.InvalidOracleConfig(1);
        }
        if (heartbeat < MIN_HEARTBEAT || heartbeat > MAX_HEARTBEAT) revert PluginErrors.InvalidOracleConfig(2);
        if (deviationAlphaBps > 10_000) revert PluginErrors.InvalidOracleConfig(3);
        if (deadbandBps >= maxDeviationBps) revert PluginErrors.InvalidOracleConfig(4);
        if (maxDeviationBps > MAX_DEVIATION_CAP_BPS) revert PluginErrors.InvalidOracleConfig(5);
        if (fallbackFeePips > FEE_CAP_PIPS) revert PluginErrors.InvalidOracleConfig(6);
        PoolId poolId = key.toId();
        if (!poolLVRStates[poolId].isInitialized) revert OraclePoolNotInitialized();
        // Edith 9-A: no feed on an L2 without the sequencer-uptime check.
        if (isKnownL2(block.chainid) && address(sequencerUptimeFeed) == address(0)) {
            revert PluginErrors.InvalidOracleConfig(9);
        }

        OracleConfig memory cfg;
        cfg.feed = feed;
        cfg.invert = invert;
        cfg.heartbeat = heartbeat;
        cfg.deviationAlphaBps = deviationAlphaBps;
        cfg.deadbandBps = deadbandBps;
        cfg.maxDeviationBps = maxDeviationBps;
        cfg.fallbackFeePips = fallbackFeePips;
        cfg.feedDecimals = _readDecimals(address(feed), 7);
        cfg.decimals0 = _currencyDecimals(key.currency0);
        cfg.decimals1 = _currencyDecimals(key.currency1);
        _oracleConfigs[poolId] = cfg;
        emit LVROracleConfigured(
            poolId, address(feed), heartbeat, deviationAlphaBps, deadbandBps, maxDeviationBps, fallbackFeePips
        );
    }

    /**
     * @notice Set (or clear, only on chains that are not known L2s) the Chainlink L2 sequencer-uptime feed.
     * Governance only. `gracePeriod` in [MIN_SEQUENCER_GRACE, MAX_SEQUENCER_GRACE]; recommended 3,600 s.
     */
    function setSequencerUptimeFeed(IAggregatorV3 feed, uint32 gracePeriod) external onlyRolesOwner {
        if (address(feed) == address(0)) {
            if (isKnownL2(block.chainid)) revert PluginErrors.InvalidOracleConfig(9);
            gracePeriod = 0;
        } else {
            if (address(feed).code.length == 0) revert PluginErrors.InvalidOracleConfig(9);
            if (gracePeriod < MIN_SEQUENCER_GRACE || gracePeriod > MAX_SEQUENCER_GRACE) {
                revert PluginErrors.InvalidOracleConfig(10);
            }
        }
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerUptimeFeedSet(address(feed), gracePeriod);
    }

    /// @notice Chain ids of rollups with a single sequencer (feed config requires the uptime feed there).
    function isKnownL2(uint256 chainId) public pure returns (bool) {
        return chainId == 8453 // Base
            || chainId == 84532 // Base Sepolia
            || chainId == 10 // OP Mainnet
            || chainId == 11155420 // OP Sepolia
            || chainId == 42161 // Arbitrum One
            || chainId == 421614 // Arbitrum Sepolia
            || chainId == 59144 // Linea
            || chainId == 534352 // Scroll
            || chainId == 324; // zkSync Era
    }

    /// @notice ADR-0009: remove the external feed (pool reverts to endogenous-only pricing).
    function clearOracleConfig(PoolKey calldata key) external onlyRolesOwner {
        PoolId poolId = key.toId();
        delete _oracleConfigs[poolId];
        emit LVROracleConfigured(poolId, address(0), 0, 0, 0, 0, 0);
    }

    /// @notice Current oracle configuration of a pool (feed == address(0) ⇒ none).
    function getOracleConfig(PoolId poolId) external view returns (OracleConfig memory) {
        return _oracleConfigs[poolId];
    }

    /// @notice What the oracle path would report right now: status 0 = valid (else fallback reason), the feed
    /// price and pool price in Q96 and their deviation in bps. For UIs and monitoring.
    function previewOracle(PoolId poolId)
        external
        view
        returns (uint8 status, uint256 oraclePriceQ96, uint256 poolPriceQ96, uint256 deviationBps)
    {
        OracleConfig memory cfg = _oracleConfigs[poolId];
        if (address(cfg.feed) == address(0)) return (255, 0, 0, 0);
        (status, oraclePriceQ96) = _readOraclePriceQ96(cfg);
        poolPriceQ96 = _poolPriceQ96(poolId);
        if (status == 0) {
            uint256 diff = poolPriceQ96 > oraclePriceQ96 ? poolPriceQ96 - oraclePriceQ96 : oraclePriceQ96 - poolPriceQ96;
            deviationBps = FullMathLib.mulDiv(diff, 10_000, oraclePriceQ96);
            if (deviationBps > cfg.maxDeviationBps) status = 6;
        }
    }

    error OraclePoolNotInitialized();

    function _currencyDecimals(Currency currency) internal view returns (uint8) {
        if (currency.isNative()) return 18;
        return _readDecimals(currency.toAddress(), 8);
    }

    function _readDecimals(address target, uint8 code) internal view returns (uint8 dec) {
        (bool ok, bytes memory ret) = target.staticcall{gas: 30_000}(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length != 32) revert PluginErrors.InvalidOracleConfig(code);
        uint256 d = abi.decode(ret, (uint256));
        if (d > 18) revert PluginErrors.InvalidOracleConfig(code);
        dec = uint8(d);
    }

    /// @dev BIN active ids → ~1bp ticks (id × binStep); CLAMM/STABLE ticks are already 1bp ticks.
    function _normalizedTick(PoolKey calldata key, int24 tick) internal pure returns (int24) {
        if (key.curveType == CurveType.BIN_AMM) return int24(int256(tick) * int256(key.tickSpacing));
        return tick;
    }

    function _emitParams(PoolId poolId, PoolLVRState storage state) internal {
        emit LVRParametersUpdated(
            poolId, state.decayHalfLife, state.volatilityAlpha, state.minFeePips, state.maxFeePips
        );
    }
}
