// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICurveEngine} from "../../interfaces/ICurveEngine.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId} from "../../types/PoolId.sol";
import {Currency} from "../../types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../types/Slot0.sol";
import {Position} from "../../types/Position.sol";
import {PoolErrors} from "../../errors/PoolErrors.sol";
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";
import {ProtocolFeeLib} from "../../libraries/ProtocolFeeLib.sol";
import {TickMathLib} from "../../libraries/TickMathLib.sol";

/**
 * @title StableAMMEngine
 * @notice Two-coin StableSwap engine (Curve invariant, n = 2) with proportional LP shares and
 * global fee-growth accrual to LP positions.
 * @dev ADR-0001:
 *  - ONE invariant is used everywhere: A·n^n·Σx + D = A·n^n·D + D^(n+1) / (n^n·Πx), with Ann = A·4.
 *    `computeD` and `computeY` are the reference Curve Newton iterations for that same invariant.
 *  - Newton iterations revert (`StableMathNotConverged`) instead of returning a stale value.
 *  - Swap outputs round down and swap inputs round up (always against the trader).
 *  - LP shares are minted proportionally to reserves (`shares · reserve / totalShares`, rounded up
 *    for deposits, down for withdrawals); the first deposit locks `MINIMUM_LIQUIDITY` shares forever.
 *  - Both tokens must report the same `decimals()` (enforced at initialize). Decimal scaling and
 *    A-ramping are follow-up work (SDX-013); the amplification parameter is fixed at `DEFAULT_A`.
 *  - `liquidityDelta` is denominated in LP shares. For the first deposit, `liquidityDelta` units of
 *    token0 are deposited together with token1 at the pool's initial price.
 */
contract StableAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;

    uint256 public constant DEFAULT_A = 100;
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
        uint256 amplificationParameter;
        uint128 totalLiquidity;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        mapping(bytes32 => Position.Info) positions;
    }

    mapping(PoolId => StablePoolState) internal pools;

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert PoolErrors.NotPoolManager();
        _;
    }

    constructor(address _poolManager) {
        if (_poolManager == address(0)) revert PoolErrors.NotPoolManager();
        poolManager = _poolManager;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (int24 tick)
    {
        PoolId id = key.toId();
        if (pools[id].slot0.isInitialized()) {
            revert PoolErrors.PoolAlreadyInitialized(id);
        }
        if (key.fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(key.fee);
        if (sqrtPriceX96 <= TickMathLib.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMathLib.MAX_SQRT_RATIO) {
            revert PoolErrors.PriceLimitOutOfBounds(sqrtPriceX96);
        }

        uint8 d0 = _decimals(key.currency0);
        uint8 d1 = _decimals(key.currency1);
        if (d0 != d1) revert PoolErrors.StableDecimalsMismatch(d0, d1);

        pools[id].amplificationParameter = DEFAULT_A;
        // Tick is not meaningful for StableSwap and is kept at 0 (LVR is disabled on STABLE pools).
        pools[id].slot0 = Slot0Library.pack(sqrtPriceX96, 0, 0, key.fee, true);
        tick = 0;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, address owner)
        external
        override
        onlyPoolManager
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) {
            revert PoolErrors.PoolNotInitialized(id);
        }

        bytes32 posKey = Position.getKey(owner, params.tickLower, params.tickUpper, params.salt);
        Position.Info storage position = pool.positions[posKey];

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

        if (params.liquidityDelta > 0) {
            uint128 shares = SafeCastLib.toUint128(uint256(params.liquidityDelta));
            uint128 totalShares = pool.totalLiquidity;
            uint256 amount0;
            uint256 amount1;

            if (totalShares == 0) {
                if (shares <= MINIMUM_LIQUIDITY) {
                    revert PoolErrors.InsufficientInitialLiquidity(shares, MINIMUM_LIQUIDITY);
                }
                amount0 = shares;
                uint160 sqrtP = pool.slot0.sqrtPriceX96();
                uint256 priceX96 = FullMathLib.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
                amount1 = FullMathLib.mulDivRoundingUp(amount0, priceX96, 1 << 96);
                if (amount1 == 0) revert PoolErrors.InsufficientLiquidity();
                pool.totalLiquidity = shares;
                // MINIMUM_LIQUIDITY shares are owned by nobody and can never be withdrawn.
                position.liquidity = positionLiquidity + (shares - MINIMUM_LIQUIDITY);
            } else {
                amount0 = FullMathLib.mulDivRoundingUp(shares, pool.reserve0, totalShares);
                amount1 = FullMathLib.mulDivRoundingUp(shares, pool.reserve1, totalShares);
                pool.totalLiquidity = totalShares + shares;
                position.liquidity = positionLiquidity + shares;
            }

            pool.reserve0 += amount0;
            pool.reserve1 += amount1;
            callerDelta = toBalanceDelta(SafeCastLib.toInt128(int256(amount0)), SafeCastLib.toInt128(int256(amount1)));
        } else if (params.liquidityDelta < 0) {
            uint256 shares = uint256(-params.liquidityDelta);
            uint128 totalShares = pool.totalLiquidity;
            if (positionLiquidity < shares || totalShares == 0) {
                revert PoolErrors.LiquidityOverflow();
            }
            uint256 amount0 = FullMathLib.mulDiv(shares, pool.reserve0, totalShares);
            uint256 amount1 = FullMathLib.mulDiv(shares, pool.reserve1, totalShares);

            pool.reserve0 -= amount0;
            pool.reserve1 -= amount1;
            pool.totalLiquidity = totalShares - uint128(shares);
            position.liquidity = positionLiquidity - uint128(shares);
            callerDelta = toBalanceDelta(-SafeCastLib.toInt128(int256(amount0)), -SafeCastLib.toInt128(int256(amount1)));
        } else {
            callerDelta = toBalanceDelta(0, 0);
        }

        position.feeGrowthInside0LastX128 = pool.feeGrowthGlobal0X128;
        position.feeGrowthInside1LastX128 = pool.feeGrowthGlobal1X128;
        position.lastModifiedBlock = uint64(block.number);

        feesAccrued = toBalanceDelta(
            fees0 > 0 ? SafeCastLib.toInt128(SafeCastLib.toInt256(fees0)) : int128(0),
            fees1 > 0 ? SafeCastLib.toInt128(SafeCastLib.toInt256(fees1)) : int128(0)
        );
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint24 fee, uint24 protocolFee)
        external
        override
        onlyPoolManager
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount)
    {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) {
            revert PoolErrors.PoolNotInitialized(id);
        }
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();
        if (fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(fee);

        // Reserves oriented as (in, out).
        (uint256 rIn, uint256 rOut) =
            params.zeroForOne ? (pool.reserve0, pool.reserve1) : (pool.reserve1, pool.reserve0);
        if (rIn == 0 || rOut == 0) revert PoolErrors.InsufficientLiquidity();
        uint256 A = pool.amplificationParameter;
        uint256 D = computeD(pool.reserve0, pool.reserve1, A);

        uint256 amountIn;
        uint256 amountOut;
        uint256 amountInAfterFee;

        if (params.amountSpecified > 0) {
            amountIn = uint256(params.amountSpecified);
            uint256 feeAmount = FullMathLib.mulDivRoundingUp(amountIn, fee, MAX_FEE_PIPS);
            if (feeAmount >= amountIn) revert PoolErrors.ZeroSwapAmount();
            amountInAfterFee = amountIn - feeAmount;

            uint256 newOut = _getY(rIn + amountInAfterFee, D, A);
            // Round against the trader: measure from min(rOut, solved y at the CURRENT x) so integer error in D
            // cannot be paid out, then give 1 wei less than the exact invariant solution.
            uint256 baseOut = _getY(rIn, D, A);
            if (baseOut > rOut) baseOut = rOut;
            if (newOut + 1 >= baseOut) revert PoolErrors.InsufficientLiquidity();
            amountOut = baseOut - newOut - 1;
        } else {
            amountOut = uint256(-params.amountSpecified);
            if (amountOut >= rOut) revert PoolErrors.InsufficientLiquidity();
            // Round against the trader: require 1 wei more input than the exact solution.
            uint256 newIn = _getY(rOut - amountOut, D, A) + 1;
            // Round against the trader: measure from min(rIn, solved x at the CURRENT y).
            uint256 baseIn = _getY(rOut, D, A);
            if (baseIn > rIn) baseIn = rIn;
            if (newIn <= baseIn) revert PoolErrors.InsufficientLiquidity();
            amountInAfterFee = newIn - baseIn;
            amountIn = FullMathLib.mulDivRoundingUp(amountInAfterFee, MAX_FEE_PIPS, MAX_FEE_PIPS - fee);
        }

        {
            uint256 lpFee;
            (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(amountIn - amountInAfterFee, protocolFee);
            _accrueStableFee(pool, lpFee, params.zeroForOne);
        }

        if (params.zeroForOne) {
            pool.reserve0 = rIn + amountInAfterFee;
            pool.reserve1 = rOut - amountOut;
            swapDelta = toBalanceDelta(SafeCastLib.toInt128(int256(amountIn)), -SafeCastLib.toInt128(int256(amountOut)));
        } else {
            pool.reserve1 = rIn + amountInAfterFee;
            pool.reserve0 = rOut - amountOut;
            swapDelta = toBalanceDelta(-SafeCastLib.toInt128(int256(amountOut)), SafeCastLib.toInt128(int256(amountIn)));
        }

        // Price-limit check against the post-swap spot (reserve ratio).
        uint160 newSqrt = _spotSqrtPriceX96(pool.reserve0, pool.reserve1);
        if (params.sqrtPriceLimitX96 != 0) {
            if (params.zeroForOne ? newSqrt < params.sqrtPriceLimitX96 : newSqrt > params.sqrtPriceLimitX96) {
                revert PoolErrors.PriceLimitAlreadyExceeded(newSqrt, params.sqrtPriceLimitX96);
            }
        }
        pool.slot0 = pool.slot0.setSqrtPriceX96(newSqrt);
    }

    function _accrueStableFee(StablePoolState storage pool, uint256 lpFee, bool zeroForOne) internal {
        // totalLiquidity >= MINIMUM_LIQUIDITY whenever reserves are non-zero, so fees are never orphaned.
        if (lpFee > 0 && pool.totalLiquidity > 0) {
            uint256 delta = FullMathLib.mulDiv(lpFee, Q128, pool.totalLiquidity);
            if (zeroForOne) {
                pool.feeGrowthGlobal0X128 += delta;
            } else {
                pool.feeGrowthGlobal1X128 += delta;
            }
        }
    }

    /**
     * @dev Integer sqrt of reserve ratio in Q192 space → sqrtPriceX96 (clamped into TickMath bounds).
     *      This is the reserve-ratio indicator reported in slot0, NOT the exact StableSwap marginal price
     *      (which stays near 1 inside the flat region of the curve). Swaps use the invariant, not this value,
     *      except for `sqrtPriceLimitX96` checks against the post-swap indicator.
     */
    function _spotSqrtPriceX96(uint256 reserve0, uint256 reserve1) internal pure returns (uint160) {
        uint256 r;
        if (reserve1 / reserve0 < (uint256(1) << 63)) {
            r = _sqrt(FullMathLib.mulDiv(reserve1, uint256(1) << 192, reserve0));
        } else {
            // Avoid mulDiv overflow for extreme ratios: sqrt(ratio·2^128)·2^32 (lower precision, still monotone).
            r = _sqrt(FullMathLib.mulDiv(reserve1, uint256(1) << 128, reserve0)) << 32;
        }
        if (r <= TickMathLib.MIN_SQRT_RATIO) return TickMathLib.MIN_SQRT_RATIO + 1;
        if (r >= TickMathLib.MAX_SQRT_RATIO) return TickMathLib.MAX_SQRT_RATIO - 1;
        return uint160(r);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x >> 1) + 1;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
    }

    /**
     * @notice StableSwap invariant D for balances (x, y) and amplification A (Curve, n = 2).
     * @dev Reverts if either balance is zero or the iteration does not converge.
     */
    function computeD(uint256 x, uint256 y, uint256 A) public pure returns (uint256 D) {
        uint256 S = x + y;
        if (S == 0) return 0;
        if (x == 0 || y == 0) revert PoolErrors.InsufficientLiquidity();

        uint256 Ann = A * N_COINS * N_COINS;
        D = S;
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 D_P = D;
            D_P = (D_P * D) / (x * N_COINS);
            D_P = (D_P * D) / (y * N_COINS);
            uint256 prevD = D;
            D = ((Ann * S + D_P * N_COINS) * D) / ((Ann - 1) * D + (N_COINS + 1) * D_P);
            if (D > prevD ? D - prevD <= 1 : prevD - D <= 1) {
                return D;
            }
        }
        revert PoolErrors.StableMathNotConverged();
    }

    /**
     * @notice Solves the other balance given a new balance `newX` and the invariant of (x, y).
     * @dev Uses the SAME invariant as `computeD`, so computeY(x, x, y, A) == y ± 1.
     */
    function computeY(uint256 newX, uint256 x, uint256 y, uint256 A) public pure returns (uint256) {
        return _getY(newX, computeD(x, y, A), A);
    }

    function _getY(uint256 newX, uint256 D, uint256 A) internal pure returns (uint256 Y) {
        if (newX == 0) revert PoolErrors.InsufficientLiquidity();
        uint256 Ann = A * N_COINS * N_COINS;
        uint256 c = (D * D) / (newX * N_COINS);
        c = (c * D) / (Ann * N_COINS);
        uint256 b = newX + D / Ann;

        Y = D;
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 prevY = Y;
            Y = (Y * Y + c) / (2 * Y + b - D);
            if (Y > prevY ? Y - prevY <= 1 : prevY - Y <= 1) {
                return Y;
            }
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

    /// @inheritdoc ICurveEngine
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external override onlyPoolManager {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (amount0 == 0 && amount1 == 0) return;
        uint128 liquidity = pool.totalLiquidity;
        if (liquidity == 0) revert PoolErrors.NoLiquidityToDonate();
        if (amount0 > 0) {
            pool.feeGrowthGlobal0X128 += FullMathLib.mulDiv(amount0, Q128, liquidity);
        }
        if (amount1 > 0) {
            pool.feeGrowthGlobal1X128 += FullMathLib.mulDiv(amount1, Q128, liquidity);
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
}
