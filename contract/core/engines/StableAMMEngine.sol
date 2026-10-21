// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICurveEngine} from "../../interfaces/ICurveEngine.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {IPoolManagerAdmin} from "../../interfaces/IPoolManagerAdmin.sol";
import {ICircuitBreaker} from "../../interfaces/ICircuitBreaker.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId} from "../../types/PoolId.sol";
import {Currency} from "../../types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../types/Slot0.sol";
import {Position} from "../../types/Position.sol";
import {PoolErrors} from "../../errors/PoolErrors.sol";
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";
import {ProtocolFeeLib} from "../../libraries/ProtocolFeeLib.sol";
import {TickMathLib} from "../../libraries/TickMathLib.sol";

/**
 * @title StableAMMEngine
 * @notice Two-coin StableSwap engine (Curve invariant, n = 2) with decimal normalisation, governed amplification
 * ramps, a bounded imbalance range, proportional LP shares and global fee-growth accrual to LP positions.
 * @dev ADR-0001 (single invariant, trader-adverse rounding, proportional shares, MINIMUM_LIQUIDITY lock) plus
 * remediation-2 (ADR-0007, ADR-0008):
 *  - Decimals (Issue 2): each token's balance is normalised to 18 decimals with an exact integer multiplier
 *    `rate = 10^(18 - decimals)` (tokens with > 18 decimals are rejected). All invariant math runs on normalised
 *    balances; raw amounts are rounded against the trader when converted back (outputs down, inputs up).
 *  - Amplification (Issue 2, ADR-0007 rev. 2): the creator passes the initial A in `initParams` (tickSpacing must be 1),
 *    within the governance range [minA, maxA] (hard bounds [MIN_A, MAX_A]); governance
 *    (PoolManager owner = timelock) can ramp A linearly over >= MIN_RAMP_TIME by at most MAX_A_CHANGE x, Curve-style;
 *    governance or a circuit-breaker guardian can stop a ramp. A uses A_PRECISION = 100 internally.
 *  - Imbalance (Issue 6 / APUS-SUPADEX-015): a swap may not leave the normalised reserves more imbalanced than
 *    MAX_IMBALANCE_RATIO : 1 (`StableImbalanceExceeded`), and the post-swap invariant must be re-computable and not
 *    lower than before (`StableInvariantViolated`). Newton solvers stop when the (monotone after one step) iteration
 *    stops decreasing, so integer-rounding 2- and 4-cycles no longer cause false non-convergence; any genuine
 *    non-convergence still reverts with `StableMathNotConverged`. Proportional LP add/remove never changes the ratio,
 *    so exits always work.
 *  - Price (slot0): `sqrtPriceX96` is the exact marginal price dy/dx of the invariant at the current reserves (raw
 *    token1 per raw token0), and `tick` is its TickMath tick. Price limits are checked against this marginal price.
 *  - `liquidityDelta` is denominated in LP shares. For the first deposit, `liquidityDelta` is in 18-decimal
 *    normalised token0 units: amount0 = ceil(shares / rate0) and amount1 is set by the pool's initial price.
 */
contract StableAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;

    /// @notice Recommended creator default for USD-stable pairs (frontend default; not enforced).
    uint256 public constant DEFAULT_A = 100;
    /// @notice Hard protocol outer bounds for any A (initial, range or ramp target).
    uint256 public constant MIN_A = 1;
    uint256 public constant MAX_A = 10_000;
    /// @notice Initial governance creator range [minA, maxA] (timelock can change within [MIN_A, MAX_A]).
    uint256 public constant INITIAL_MIN_A = 10;
    uint256 public constant INITIAL_MAX_A = 5_000;
    uint256 public constant A_PRECISION = 100;
    uint256 public constant MIN_RAMP_TIME = 1 days;
    uint256 public constant MAX_A_CHANGE = 10;
    /// @notice Largest supported normalised reserve ratio (high : low) a swap may leave behind.
    uint256 public constant MAX_IMBALANCE_RATIO = 10_000;
    /// @notice Per-side cap on normalised reserves (keeps every intermediate product far below 2^256).
    uint256 public constant MAX_NORMALIZED_RESERVE = 1e34;
    /// @notice Largest D / x the y-solver accepts. Supported states have D / lo <= MAX_IMBALANCE_RATIO + 1, so this is a
    /// 5x margin; beyond it the Newton iterates (~D^2 / (16 A x)) could overflow, so we revert with the classified
    /// `StableImbalanceExceeded` instead of panicking (Edith G-1 / 8-A).
    uint256 internal constant SOLVER_DOMAIN_RATIO = 50_000;
    /// @notice D may come out a few wei lower after a swap purely from solver rounding.
    uint256 internal constant D_TOLERANCE = 16;
    uint256 internal constant N_COINS = 2;
    uint256 internal constant MAX_LOOP_LIMIT = 255;
    uint256 internal constant Q128 = 1 << 128;
    uint24 internal constant MAX_FEE_PIPS = 1_000_000;
    /// @notice LP shares permanently locked on the first deposit (first-depositor protection).
    uint128 public constant MINIMUM_LIQUIDITY = 1000;

    address public immutable override poolManager;

    struct StablePoolState {
        Slot0 slot0;
        uint256 reserve0;
        uint256 reserve1;
        uint128 totalLiquidity;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint64 rate0;
        uint64 rate1;
        uint64 initialAPrecise;
        uint64 futureAPrecise;
        uint40 initialATime;
        uint40 futureATime;
        mapping(bytes32 => Position.Info) positions;
    }

    mapping(PoolId => StablePoolState) internal pools;

    /// @notice Creator-selectable amplification range (human units). Timelock-only via setAmplificationRange.
    uint256 public minA;
    uint256 public maxA;

    event RampA(PoolId indexed id, uint256 oldAPrecise, uint256 newAPrecise, uint256 initialTime, uint256 futureTime);
    event StopRampA(PoolId indexed id, uint256 currentAPrecise, uint256 time);
    event StableAInitialized(PoolId indexed id, uint256 aPrecise);
    event AmplificationRangeSet(uint256 minA, uint256 maxA);

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert PoolErrors.NotPoolManager();
        _;
    }

    constructor(address _poolManager) {
        if (_poolManager == address(0)) revert PoolErrors.NotPoolManager();
        poolManager = _poolManager;
        minA = INITIAL_MIN_A;
        maxA = INITIAL_MAX_A;
    }

    // ------------------------------------------------------------------ initialize

    function initialize(PoolKey memory key, uint160 sqrtPriceX96, bytes memory initParams)
        external
        override
        onlyPoolManager
        returns (int24 tick)
    {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (pool.slot0.isInitialized()) revert PoolErrors.PoolAlreadyInitialized(id);
        if (key.fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(key.fee);
        if (sqrtPriceX96 <= TickMathLib.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMathLib.MAX_SQRT_RATIO) {
            revert PoolErrors.PriceLimitOutOfBounds(sqrtPriceX96);
        }

        uint8 d0 = _decimals(key.currency0);
        uint8 d1 = _decimals(key.currency1);
        if (d0 > 18 || d1 > 18) revert PoolErrors.StableDecimalsUnsupported(d0, d1);
        pool.rate0 = uint64(10 ** (18 - d0));
        pool.rate1 = uint64(10 ** (18 - d1));

        uint256 aPrecise = _initialAPrecise(key, initParams);
        pool.initialAPrecise = uint64(aPrecise);
        pool.futureAPrecise = uint64(aPrecise);
        pool.initialATime = uint40(block.timestamp);
        pool.futureATime = uint40(block.timestamp);

        tick = TickMathLib.getTickAtSqrtRatio(sqrtPriceX96);
        pool.slot0 = Slot0Library.pack(sqrtPriceX96, tick, 0, key.fee, true);
    }

    /**
     * @dev Initial amplification (ADR-0007 rev. 2, Edith 7-A; Curve-factory style, decided 2026-10-21):
     *  - A is NOT part of the pool identity: STABLE pools require `key.tickSpacing == 1` (one canonical pool per
     *    pair / fee / plugin) and the creator passes A in `initParams = abi.encode(uint256 A)`;
     *  - A must lie in the governance range [minA, maxA] (timelock-set; hard outer bounds MIN_A / MAX_A);
     *  - after creation A only changes through the timelocked, bounded `rampA`. Read it via `getAmplification`.
     */
    function _initialAPrecise(PoolKey memory key, bytes memory initParams) internal returns (uint256) {
        if (key.tickSpacing != 1) revert PoolErrors.InvalidTickSpacing(key.tickSpacing);
        if (initParams.length != 32) revert PoolErrors.InvalidInitParams();
        uint256 a = abi.decode(initParams, (uint256));
        if (a < minA || a > maxA) revert PoolErrors.StableInvalidAmplification(a);
        emit StableAInitialized(key.toId(), a * A_PRECISION);
        return a * A_PRECISION;
    }

    /**
     * @notice Set the A range pool creators may choose from. Only the PoolManager owner (timelock).
     * @dev Does not affect existing pools; ramps stay bounded by the hard MIN_A / MAX_A constants and MAX_A_CHANGE.
     */
    function setAmplificationRange(uint256 newMinA, uint256 newMaxA) external {
        if (msg.sender != _governance()) revert PoolErrors.NotGovernance();
        if (newMinA < MIN_A || newMinA > newMaxA || newMaxA > MAX_A) {
            revert PoolErrors.StableInvalidARange(newMinA, newMaxA);
        }
        minA = newMinA;
        maxA = newMaxA;
        emit AmplificationRangeSet(newMinA, newMaxA);
    }

    // ------------------------------------------------------------------ liquidity

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, address owner)
        external
        override
        onlyPoolManager
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);

        Position.Info storage position =
            pool.positions[Position.getKey(owner, params.tickLower, params.tickUpper, params.salt)];
        feesAccrued = _collectPositionFees(pool, position);

        if (params.liquidityDelta > 0) {
            callerDelta = _addLiquidity(pool, position, SafeCastLib.toUint128(uint256(params.liquidityDelta)));
        } else if (params.liquidityDelta < 0) {
            callerDelta = _removeLiquidity(pool, position, uint256(-params.liquidityDelta));
        }
        position.lastModifiedBlock = uint64(block.number);
    }

    function _collectPositionFees(StablePoolState storage pool, Position.Info storage position)
        internal
        returns (BalanceDelta)
    {
        uint128 positionLiquidity = position.liquidity;
        uint256 fees0;
        uint256 fees1;
        if (positionLiquidity > 0) {
            unchecked {
                fees0 = FullMathLib.mulDiv(
                    positionLiquidity, pool.feeGrowthGlobal0X128 - position.feeGrowthInside0LastX128, Q128
                );
                fees1 = FullMathLib.mulDiv(
                    positionLiquidity, pool.feeGrowthGlobal1X128 - position.feeGrowthInside1LastX128, Q128
                );
            }
        }
        position.feeGrowthInside0LastX128 = pool.feeGrowthGlobal0X128;
        position.feeGrowthInside1LastX128 = pool.feeGrowthGlobal1X128;
        return toBalanceDelta(
            SafeCastLib.toInt128(SafeCastLib.toInt256(fees0)), SafeCastLib.toInt128(SafeCastLib.toInt256(fees1))
        );
    }

    function _addLiquidity(StablePoolState storage pool, Position.Info storage position, uint128 shares)
        internal
        returns (BalanceDelta)
    {
        uint128 totalShares = pool.totalLiquidity;
        uint256 amount0;
        uint256 amount1;
        if (totalShares == 0) {
            if (shares <= MINIMUM_LIQUIDITY) {
                revert PoolErrors.InsufficientInitialLiquidity(shares, MINIMUM_LIQUIDITY);
            }
            amount0 = _divUp(shares, pool.rate0);
            uint160 sqrtP = pool.slot0.sqrtPriceX96();
            uint256 priceX96 = FullMathLib.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
            amount1 = FullMathLib.mulDivRoundingUp(amount0, priceX96, 1 << 96);
            if (amount1 == 0) revert PoolErrors.InsufficientLiquidity();
            pool.totalLiquidity = shares;
            // MINIMUM_LIQUIDITY shares are owned by nobody and can never be withdrawn.
            position.liquidity += shares - MINIMUM_LIQUIDITY;
        } else {
            amount0 = FullMathLib.mulDivRoundingUp(shares, pool.reserve0, totalShares);
            amount1 = FullMathLib.mulDivRoundingUp(shares, pool.reserve1, totalShares);
            pool.totalLiquidity = totalShares + shares;
            position.liquidity += shares;
        }

        pool.reserve0 += amount0;
        pool.reserve1 += amount1;
        (uint256 xp0, uint256 xp1) = _xp(pool);
        _checkReserveBounds(xp0, xp1);
        if (totalShares == 0) {
            // First deposit fixes the composition: refresh slot0 to the invariant's marginal price.
            _writePrice(pool, xp0, xp1, _currentAPrecise(pool));
        }
        return toBalanceDelta(SafeCastLib.toInt128(int256(amount0)), SafeCastLib.toInt128(int256(amount1)));
    }

    function _removeLiquidity(StablePoolState storage pool, Position.Info storage position, uint256 shares)
        internal
        returns (BalanceDelta)
    {
        uint128 totalShares = pool.totalLiquidity;
        if (position.liquidity < shares || totalShares == 0) revert PoolErrors.LiquidityOverflow();
        uint256 amount0 = FullMathLib.mulDiv(shares, pool.reserve0, totalShares);
        uint256 amount1 = FullMathLib.mulDiv(shares, pool.reserve1, totalShares);
        pool.reserve0 -= amount0;
        pool.reserve1 -= amount1;
        pool.totalLiquidity = totalShares - uint128(shares);
        position.liquidity -= uint128(shares);
        return toBalanceDelta(-SafeCastLib.toInt128(int256(amount0)), -SafeCastLib.toInt128(int256(amount1)));
    }

    // ------------------------------------------------------------------ swap

    struct SwapVars {
        uint256 rateIn;
        uint256 rateOut;
        uint256 xpIn;
        uint256 xpOut;
        uint256 aPrecise;
        uint256 d;
        uint256 amountIn;
        uint256 amountInAfterFee;
        uint256 amountOut;
        uint256 xp0Before;
        uint256 xp1Before;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint24 fee, uint24 protocolFee)
        external
        override
        onlyPoolManager
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount)
    {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();
        if (fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(fee);

        SwapVars memory v;
        (uint256 xp0, uint256 xp1) = _xp(pool);
        if (xp0 == 0 || xp1 == 0) revert PoolErrors.InsufficientLiquidity();
        (v.xp0Before, v.xp1Before) = (xp0, xp1);
        (v.xpIn, v.xpOut) = params.zeroForOne ? (xp0, xp1) : (xp1, xp0);
        (v.rateIn, v.rateOut) = params.zeroForOne ? (pool.rate0, pool.rate1) : (pool.rate1, pool.rate0);
        v.aPrecise = _currentAPrecise(pool);
        v.d = _computeD(xp0, xp1, v.aPrecise);

        if (params.amountSpecified > 0) {
            _quoteExactIn(v, uint256(params.amountSpecified), fee);
        } else {
            _quoteExactOut(v, uint256(-params.amountSpecified), fee);
        }

        {
            uint256 lpFee;
            (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(v.amountIn - v.amountInAfterFee, protocolFee);
            _accrueStableFee(pool, lpFee, params.zeroForOne);
        }

        if (params.zeroForOne) {
            pool.reserve0 += v.amountInAfterFee;
            pool.reserve1 -= v.amountOut;
            swapDelta =
                toBalanceDelta(SafeCastLib.toInt128(int256(v.amountIn)), -SafeCastLib.toInt128(int256(v.amountOut)));
        } else {
            pool.reserve1 += v.amountInAfterFee;
            pool.reserve0 -= v.amountOut;
            swapDelta =
                toBalanceDelta(-SafeCastLib.toInt128(int256(v.amountOut)), SafeCastLib.toInt128(int256(v.amountIn)));
        }

        _postSwapChecks(pool, v, params);
    }

    /// @dev Exact input: fee taken from the input; output rounded down (and 2 wei normalised safety margin).
    function _quoteExactIn(SwapVars memory v, uint256 amountIn, uint24 fee) internal pure {
        v.amountIn = amountIn;
        uint256 feeAmount = FullMathLib.mulDivRoundingUp(amountIn, fee, MAX_FEE_PIPS);
        if (feeAmount >= amountIn) revert PoolErrors.ZeroSwapAmount();
        v.amountInAfterFee = amountIn - feeAmount;
        // The input side can never exceed the per-side cap; reject before `amount * rate` can overflow.
        if (v.amountInAfterFee > (MAX_NORMALIZED_RESERVE - _min(v.xpIn, MAX_NORMALIZED_RESERVE)) / v.rateIn) {
            revert PoolErrors.StableImbalanceExceeded(type(uint256).max, v.xpOut, MAX_IMBALANCE_RATIO);
        }

        uint256 newOut = _getY(v.xpIn + v.amountInAfterFee * v.rateIn, v.d, v.aPrecise);
        // Measure from min(xpOut, solved y at the CURRENT x) so solver error in D cannot be paid out.
        uint256 baseOut = _getY(v.xpIn, v.d, v.aPrecise);
        if (baseOut > v.xpOut) baseOut = v.xpOut;
        if (newOut + 2 >= baseOut) revert PoolErrors.InsufficientLiquidity();
        v.amountOut = (baseOut - newOut - 2) / v.rateOut;
        if (v.amountOut == 0) revert PoolErrors.InsufficientLiquidity();
    }

    /// @dev Exact output: input rounded up (2 wei normalised safety margin), fee grossed up on top.
    function _quoteExactOut(SwapVars memory v, uint256 amountOut, uint24 fee) internal pure {
        v.amountOut = amountOut;
        // amountOut * rateOut < xpOut  <=>  amountOut <= (xpOut - 1) / rateOut  (checked before multiplying).
        if (amountOut > (v.xpOut - 1) / v.rateOut) revert PoolErrors.InsufficientLiquidity();
        uint256 outNorm = amountOut * v.rateOut;
        uint256 outAfter = v.xpOut - outNorm;
        // Edith G-1 / 8-A: the input side only grows on exact-out, so the result is at least xpIn : outAfter.
        // Classify a trade that necessarily leaves the pool beyond the bound BEFORE solving (the solver would
        // otherwise run far outside its domain). Condition 7: allowed only if it strictly reduces an existing breach.
        if (v.xpIn / MAX_IMBALANCE_RATIO > outAfter) {
            (uint256 hiB, uint256 loB) = v.xpIn >= v.xpOut ? (v.xpIn, v.xpOut) : (v.xpOut, v.xpIn);
            bool preBreach = hiB / MAX_IMBALANCE_RATIO > loB;
            // post ratio >= xpIn / outAfter; strictly reducing requires xpIn / outAfter < hiB / loB.
            if (!preBreach || v.xpIn * loB >= hiB * outAfter) {
                revert PoolErrors.StableImbalanceExceeded(v.xpIn, outAfter, MAX_IMBALANCE_RATIO);
            }
        }
        uint256 newIn = _getY(v.xpOut - outNorm, v.d, v.aPrecise) + 2;
        uint256 baseIn = _getY(v.xpOut, v.d, v.aPrecise);
        if (baseIn > v.xpIn) baseIn = v.xpIn;
        if (newIn <= baseIn) revert PoolErrors.InsufficientLiquidity();
        v.amountInAfterFee = _divUp(newIn - baseIn, v.rateIn);
        v.amountIn = FullMathLib.mulDivRoundingUp(v.amountInAfterFee, MAX_FEE_PIPS, MAX_FEE_PIPS - fee);
    }

    /// @dev Issue 6: bounded imbalance, recomputable and non-decreasing invariant, price limit, slot0 refresh.
    function _postSwapChecks(StablePoolState storage pool, SwapVars memory v, IPoolManager.SwapParams memory params)
        internal
    {
        (uint256 xp0, uint256 xp1) = _xp(pool);
        _checkSwapBounds(v.xp0Before, v.xp1Before, xp0, xp1);
        uint256 dAfter = _computeD(xp0, xp1, v.aPrecise);
        if (dAfter + D_TOLERANCE < v.d) revert PoolErrors.StableInvariantViolated(v.d, dAfter);

        uint160 newSqrt = _writePriceWithD(pool, xp0, xp1, v.aPrecise, dAfter);
        if (params.sqrtPriceLimitX96 != 0) {
            if (params.zeroForOne ? newSqrt < params.sqrtPriceLimitX96 : newSqrt > params.sqrtPriceLimitX96) {
                revert PoolErrors.PriceLimitAlreadyExceeded(newSqrt, params.sqrtPriceLimitX96);
            }
        }
    }

    function _accrueStableFee(StablePoolState storage pool, uint256 lpFee, bool zeroForOne) internal {
        // totalLiquidity >= MINIMUM_LIQUIDITY whenever reserves are non-zero, so fees are never orphaned.
        if (lpFee > 0 && pool.totalLiquidity > 0) {
            uint256 delta = FullMathLib.mulDiv(lpFee, Q128, pool.totalLiquidity);
            // mod-2^256 accumulator (Uniswap semantics); positions take wrapping differences.
            unchecked {
                if (zeroForOne) {
                    pool.feeGrowthGlobal0X128 += delta;
                } else {
                    pool.feeGrowthGlobal1X128 += delta;
                }
            }
        }
    }

    function _xp(StablePoolState storage pool) internal view returns (uint256 xp0, uint256 xp1) {
        xp0 = pool.reserve0 * pool.rate0;
        xp1 = pool.reserve1 * pool.rate1;
    }

    /// @dev Supported operating range: both sides <= MAX_NORMALIZED_RESERVE and high/low <= MAX_IMBALANCE_RATIO.
    function _checkReserveBounds(uint256 xp0, uint256 xp1) internal pure {
        (uint256 hi, uint256 lo) = xp0 >= xp1 ? (xp0, xp1) : (xp1, xp0);
        if (hi > MAX_NORMALIZED_RESERVE || lo == 0 || hi / MAX_IMBALANCE_RATIO > lo) {
            revert PoolErrors.StableImbalanceExceeded(hi, lo, MAX_IMBALANCE_RATIO);
        }
    }

    /**
     * @dev Swap bound (Edith 8-B / condition 7). A swap must leave the pool inside the fixed, ungoverned bound —
     * EXCEPT when the pool is already outside it (only reachable through proportional-remove rounding at the
     * boundary): then a swap is allowed iff it STRICTLY reduces the imbalance ratio (and respects the per-side cap).
     * MAX_IMBALANCE_RATIO stays a compile-time constant.
     */
    function _checkSwapBounds(uint256 pre0, uint256 pre1, uint256 post0, uint256 post1) internal pure {
        (uint256 hi, uint256 lo) = post0 >= post1 ? (post0, post1) : (post1, post0);
        if (hi <= MAX_NORMALIZED_RESERVE && lo != 0 && hi / MAX_IMBALANCE_RATIO <= lo) return;
        (uint256 hiB, uint256 loB) = pre0 >= pre1 ? (pre0, pre1) : (pre1, pre0);
        bool preBreach = hiB / MAX_IMBALANCE_RATIO > loB;
        // ratios compared by cross-multiplication; both sides <= ~1e34 so products fit in 256 bits.
        if (preBreach && hi <= MAX_NORMALIZED_RESERVE && lo != 0 && hi * loB < hiB * lo) return;
        revert PoolErrors.StableImbalanceExceeded(hi, lo, MAX_IMBALANCE_RATIO);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ------------------------------------------------------------------ amplification governance

    function _currentAPrecise(StablePoolState storage pool) internal view returns (uint256) {
        uint256 t1 = pool.futureATime;
        uint256 a1 = pool.futureAPrecise;
        if (block.timestamp >= t1) return a1;
        uint256 t0 = pool.initialATime;
        uint256 a0 = pool.initialAPrecise;
        if (a1 > a0) return a0 + (a1 - a0) * (block.timestamp - t0) / (t1 - t0);
        return a0 - (a0 - a1) * (block.timestamp - t0) / (t1 - t0);
    }

    function _governance() internal view returns (address) {
        return IPoolManagerAdmin(poolManager).owner();
    }

    /**
     * @notice Start a linear A ramp (Curve semantics). Only the PoolManager owner (timelock).
     * @param futureA Target A in human units (not A_PRECISION-scaled), within [MIN_A, MAX_A].
     * @param futureTime Unix time the ramp completes; >= now + MIN_RAMP_TIME.
     */
    function rampA(PoolKey calldata key, uint256 futureA, uint256 futureTime) external {
        if (msg.sender != _governance()) revert PoolErrors.NotGovernance();
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (
            block.timestamp < uint256(pool.initialATime) + MIN_RAMP_TIME || futureTime < block.timestamp + MIN_RAMP_TIME
                || futureA < MIN_A || futureA > MAX_A || futureTime > type(uint40).max
        ) revert PoolErrors.StableInvalidRamp(futureA, futureTime);

        uint256 current = _currentAPrecise(pool);
        uint256 target = futureA * A_PRECISION;
        if (target > current ? target > current * MAX_A_CHANGE : target * MAX_A_CHANGE < current) {
            revert PoolErrors.StableInvalidRamp(futureA, futureTime);
        }
        pool.initialAPrecise = uint64(current);
        pool.futureAPrecise = uint64(target);
        pool.initialATime = uint40(block.timestamp);
        pool.futureATime = uint40(futureTime);
        emit RampA(id, current, target, block.timestamp, futureTime);
    }

    /// @notice Freeze A at its current value. PoolManager owner (timelock) or any circuit-breaker guardian.
    /// @dev Only while a ramp is active (Edith 7-B): otherwise a guardian could keep resetting `initialATime` and
    /// block governance ramps (which require MIN_RAMP_TIME since the last change) indefinitely.
    function stopRampA(PoolKey calldata key) external {
        if (msg.sender != _governance()) {
            ICircuitBreaker cb = IPoolManagerAdmin(poolManager).circuitBreaker();
            if (address(cb) == address(0) || !cb.isGuardian(msg.sender)) revert PoolErrors.NotGovernance();
        }
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (block.timestamp >= pool.futureATime) revert PoolErrors.StableNoActiveRamp(pool.futureATime);
        uint256 current = _currentAPrecise(pool);
        pool.initialAPrecise = uint64(current);
        pool.futureAPrecise = uint64(current);
        pool.initialATime = uint40(block.timestamp);
        pool.futureATime = uint40(block.timestamp);
        emit StopRampA(id, current, block.timestamp);
    }

    // ------------------------------------------------------------------ price

    function _writePrice(StablePoolState storage pool, uint256 xp0, uint256 xp1, uint256 aPrecise)
        internal
        returns (uint160)
    {
        return _writePriceWithD(pool, xp0, xp1, aPrecise, _computeD(xp0, xp1, aPrecise));
    }

    function _writePriceWithD(StablePoolState storage pool, uint256 xp0, uint256 xp1, uint256 aPrecise, uint256 d)
        internal
        returns (uint160 sqrtP)
    {
        sqrtP = _marginalSqrtPriceX96(xp0, xp1, aPrecise, d, pool.rate0, pool.rate1);
        pool.slot0 = pool.slot0.setSqrtPriceX96(sqrtP).setTick(TickMathLib.getTickAtSqrtRatio(sqrtP));
    }

    /**
     * @dev Marginal price of token0 in token1 at (x, y): with f = Ann(x+y) + D - Ann D - D^3/(4xy) = 0,
     *   p = (Ann + D^3/(4x^2 y)) / (Ann + D^3/(4x y^2))    (normalised units, 1e18 fixed point)
     * Converted to raw units (p * rate0 / rate1), then to sqrtPriceX96 (clamped into TickMath bounds).
     */
    function _marginalSqrtPriceX96(uint256 x, uint256 y, uint256 aPrecise, uint256 d, uint256 rate0, uint256 rate1)
        internal
        pure
        returns (uint160)
    {
        uint256 annE = aPrecise * N_COINS * N_COINS * 1e18 / A_PRECISION;
        uint256 termX = FullMathLib.mulDiv(FullMathLib.mulDiv(FullMathLib.mulDiv(d, d, 2 * x), d, 2 * x), 1e18, y);
        uint256 termY = FullMathLib.mulDiv(FullMathLib.mulDiv(FullMathLib.mulDiv(d, d, 2 * y), d, 2 * y), 1e18, x);
        uint256 priceX128 = FullMathLib.mulDiv((annE + termX) * rate0, Q128, (annE + termY) * rate1);
        uint256 r;
        if (priceX128 < (uint256(1) << 192)) {
            r = _sqrt(priceX128 << 64);
        } else {
            r = _sqrt(priceX128) << 32;
        }
        if (r <= TickMathLib.MIN_SQRT_RATIO) return TickMathLib.MIN_SQRT_RATIO + 1;
        if (r >= TickMathLib.MAX_SQRT_RATIO) return TickMathLib.MAX_SQRT_RATIO - 1;
        return uint160(r);
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        return FixedPointMathLib.sqrt(x);
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ------------------------------------------------------------------ invariant math

    /**
     * @notice StableSwap invariant D for normalised balances (x, y) and amplification A (human units).
     * @dev Reverts if either balance is zero or the iteration does not converge.
     */
    function computeD(uint256 x, uint256 y, uint256 A) public pure returns (uint256) {
        return _computeD(x, y, A * A_PRECISION);
    }

    /**
     * @notice Solves the other balance given a new balance `newX` and the invariant of (x, y).
     * @dev Uses the SAME invariant as `computeD`, so computeY(x, x, y, A) == y within solver tolerance.
     */
    function computeY(uint256 newX, uint256 x, uint256 y, uint256 A) public pure returns (uint256) {
        uint256 aPrecise = A * A_PRECISION;
        return _getY(newX, _computeD(x, y, aPrecise), aPrecise);
    }

    /**
     * @dev Curve D Newton iteration (A_PRECISION form). After the first step the iterates decrease monotonically
     * towards the root in exact arithmetic; we stop as soon as they stop decreasing (integer rounding floor), which
     * also terminates the 2/4-cycles plain `|D - Dprev| <= 1` checks can get stuck in.
     */
    function _computeD(uint256 x, uint256 y, uint256 aPrecise) internal pure returns (uint256 d) {
        uint256 s = x + y;
        if (s == 0) return 0;
        if (x == 0 || y == 0) revert PoolErrors.InsufficientLiquidity();
        if (aPrecise == 0) revert PoolErrors.StableInvalidAmplification(0);
        uint256 ann = aPrecise * N_COINS * N_COINS;
        d = _stepD(s, x, y, s, ann);
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 next = _stepD(d, x, y, s, ann);
            if (next >= d) return d;
            if (d - next <= 1) return next;
            d = next;
        }
        revert PoolErrors.StableMathNotConverged();
    }

    function _stepD(uint256 d, uint256 x, uint256 y, uint256 s, uint256 ann) private pure returns (uint256) {
        uint256 dP = FullMathLib.mulDiv(FullMathLib.mulDiv(d, d, x * N_COINS), d, y * N_COINS);
        return FullMathLib.mulDiv(
            ann * s / A_PRECISION + dP * N_COINS, d, (ann - A_PRECISION) * d / A_PRECISION + (N_COINS + 1) * dP
        );
    }

    /// @dev Curve get_y Newton iteration; one unconditional step, then monotone-decreasing stop rule.
    function _getY(uint256 newX, uint256 d, uint256 aPrecise) internal pure returns (uint256 y) {
        if (newX == 0) revert PoolErrors.InsufficientLiquidity();
        // Solver domain guard (Edith G-1): far outside the supported range the iterates overflow; classify instead.
        if (d / SOLVER_DOMAIN_RATIO > newX) revert PoolErrors.StableImbalanceExceeded(d, newX, MAX_IMBALANCE_RATIO);
        uint256 ann = aPrecise * N_COINS * N_COINS;
        uint256 c = FullMathLib.mulDiv(FullMathLib.mulDiv(d, d, newX * N_COINS), d * A_PRECISION, ann * N_COINS);
        uint256 b = newX + d * A_PRECISION / ann;
        y = (d * d + c) / (2 * d + b - d);
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 next = (y * y + c) / (2 * y + b - d);
            if (next >= y) return y;
            if (y - next <= 1) return next;
            y = next;
        }
        revert PoolErrors.StableMathNotConverged();
    }

    function _decimals(Currency currency) internal view returns (uint8) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return 18;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert PoolErrors.StableDecimalsMismatch(0, 0);
        uint256 dec = abi.decode(data, (uint256));
        if (dec > 255) revert PoolErrors.StableDecimalsMismatch(0, 0);
        return uint8(dec);
    }

    // ------------------------------------------------------------------ donate / views

    /// @inheritdoc ICurveEngine
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external override onlyPoolManager {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (amount0 == 0 && amount1 == 0) return;
        uint128 liquidity = pool.totalLiquidity;
        if (liquidity == 0) revert PoolErrors.NoLiquidityToDonate();
        uint256 g0 = amount0 > 0 ? FullMathLib.mulDiv(amount0, Q128, liquidity) : 0;
        uint256 g1 = amount1 > 0 ? FullMathLib.mulDiv(amount1, Q128, liquidity) : 0;
        // mod-2^256 accumulator (Uniswap semantics).
        unchecked {
            pool.feeGrowthGlobal0X128 += g0;
            pool.feeGrowthGlobal1X128 += g1;
        }
    }

    function getSlot0(PoolId id) external view override returns (Slot0) {
        return pools[id].slot0;
    }

    function getLiquidity(PoolId id) external view override returns (uint128) {
        return pools[id].totalLiquidity;
    }

    function getReserves(PoolId id) external view returns (uint256 reserve0, uint256 reserve1) {
        StablePoolState storage pool = pools[id];
        return (pool.reserve0, pool.reserve1);
    }

    /// @notice Current amplification in human units (A_PRECISION removed, rounded down).
    function getA(PoolId id) external view returns (uint256) {
        return _currentAPrecise(pools[id]) / A_PRECISION;
    }

    /// @notice Full amplification state (A values are A_PRECISION-scaled).
    function getAmplification(PoolId id)
        external
        view
        returns (
            uint256 currentAPrecise,
            uint256 initialAPrecise,
            uint256 futureAPrecise,
            uint256 initialTime,
            uint256 futureTime
        )
    {
        StablePoolState storage pool = pools[id];
        return (_currentAPrecise(pool), pool.initialAPrecise, pool.futureAPrecise, pool.initialATime, pool.futureATime);
    }

    /// @notice Normalisation multipliers (10^(18 - decimals)) for token0 and token1.
    function getRates(PoolId id) external view returns (uint256 rate0, uint256 rate1) {
        return (pools[id].rate0, pools[id].rate1);
    }

    /// @notice Invariant D (18-decimal normalised) per LP share, 1e18-scaled (0 if no shares).
    function getVirtualPrice(PoolId id) external view returns (uint256) {
        StablePoolState storage pool = pools[id];
        if (pool.totalLiquidity == 0) return 0;
        (uint256 xp0, uint256 xp1) = _xp(pool);
        return FullMathLib.mulDiv(_computeD(xp0, xp1, _currentAPrecise(pool)), 1e18, pool.totalLiquidity);
    }

    function getPosition(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (Position.Info memory)
    {
        return pools[id].positions[Position.getKey(owner, tickLower, tickUpper, salt)];
    }
}
