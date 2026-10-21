// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICurveEngine} from "../../interfaces/ICurveEngine.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId} from "../../types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "../../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../types/Slot0.sol";
import {Position} from "../../types/Position.sol";
import {PoolErrors} from "../../errors/PoolErrors.sol";
import {TickMathLib} from "../../libraries/TickMathLib.sol";
import {SqrtPriceMathLib} from "../../libraries/SqrtPriceMathLib.sol";
import {TreeBitmapLib} from "../../libraries/TreeBitmapLib.sol";
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";
import {ProtocolFeeLib} from "../../libraries/ProtocolFeeLib.sol";

/**
 * @title CLAMMEngine
 * @notice Concentrated Liquidity AMM with Uniswap-style fee growth accrual to LPs.
 * @dev Remediation-2:
 *  - Issue 7 / APUS-SUPADEX-016: initialized ticks are indexed in a 3-level `TreeBitmapLib` tree, so the next
 *    initialized tick in either direction is found in O(1) storage reads, however far away it is. A swap through
 *    an empty range is one swap step (no per-word walk).
 *  - Issue 4: cumulative gross liquidity referencing any tick is capped at `maxLiquidityPerTick(tickSpacing)`
 *    (Uniswap v3 formula: uint128.max / number of usable ticks), so liquidityNet / pool liquidity can never
 *    overflow uint128 when every tick is crossed.
 *  - Ticks must be multiples of tickSpacing (`TickNotSpaced`).
 */
contract CLAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;
    using TreeBitmapLib for TreeBitmapLib.Tree;

    uint256 internal constant Q128 = 1 << 128;
    uint24 internal constant MAX_FEE_PIPS = 1_000_000;

    address public immutable override poolManager;

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert PoolErrors.NotPoolManager();
        _;
    }

    constructor(address _poolManager) {
        if (_poolManager == address(0)) revert PoolErrors.NotPoolManager();
        poolManager = _poolManager;
    }

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        bool initialized;
    }

    struct PoolState {
        Slot0 slot0;
        uint128 liquidity;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        TreeBitmapLib.Tree tickTree;
        mapping(int24 => TickInfo) ticks;
        mapping(bytes32 => Position.Info) positions;
    }

    mapping(PoolId => PoolState) internal pools;

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

        tick = TickMathLib.getTickAtSqrtRatio(sqrtPriceX96);
        pools[id].slot0 = Slot0Library.pack(sqrtPriceX96, tick, 0, key.fee, true);
    }

    function _getFeeGrowthInside(
        PoolState storage pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        TickInfo storage lower = pool.ticks[tickLower];
        TickInfo storage upper = pool.ticks[tickUpper];

        uint256 feeGrowthBelow0;
        uint256 feeGrowthBelow1;
        unchecked {
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0 = lower.feeGrowthOutside0X128;
                feeGrowthBelow1 = lower.feeGrowthOutside1X128;
            } else {
                feeGrowthBelow0 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
                feeGrowthBelow1 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
            }

            if (tickCurrent < tickUpper) {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1 - upper.feeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    feeGrowthGlobal0X128 - feeGrowthBelow0 - (feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128);
                feeGrowthInside1X128 =
                    feeGrowthGlobal1X128 - feeGrowthBelow1 - (feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128);
            }
        }
    }

    function _updateTick(
        PoolState storage pool,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool upper,
        int24 tickSpacing
    ) internal returns (bool flipped) {
        if (tick % tickSpacing != 0) revert PoolErrors.TickNotSpaced(tick, tickSpacing);
        TickInfo storage info = pool.ticks[tick];
        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = liquidityDelta < 0
            ? liquidityGrossBefore - uint128(-liquidityDelta)
            : liquidityGrossBefore + uint128(liquidityDelta);
        if (liquidityDelta > 0) {
            uint128 maxPerTick = maxLiquidityPerTick(tickSpacing);
            if (liquidityGrossAfter > maxPerTick) {
                revert PoolErrors.TickLiquidityOverflow(tick, liquidityGrossAfter, maxPerTick);
            }
        }

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // When initializing a tick at or below current, seed outside growth to global
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
            info.initialized = true;
            pool.tickTree.add(TreeBitmapLib.toKey(_compress(tick, tickSpacing)));
        }

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = upper ? info.liquidityNet - liquidityDelta : info.liquidityNet + liquidityDelta;

        if (liquidityGrossAfter == 0) {
            info.initialized = false;
            pool.tickTree.remove(TreeBitmapLib.toKey(_compress(tick, tickSpacing)));
        }
    }

    function _computeModifyAmounts(
        uint160 sqrtPriceX96,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int128 delta128
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtRatioAX96 = TickMathLib.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMathLib.getSqrtRatioAtTick(tickUpper);
        uint128 absDelta = uint128(delta128 < 0 ? -delta128 : delta128);
        bool isAdd = delta128 > 0;

        if (currentTick < tickLower) {
            amount0 = SqrtPriceMathLib.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, absDelta, isAdd);
        } else if (currentTick < tickUpper) {
            amount0 = SqrtPriceMathLib.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, absDelta, isAdd);
            amount1 = SqrtPriceMathLib.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, absDelta, isAdd);
        } else {
            amount1 = SqrtPriceMathLib.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, absDelta, isAdd);
        }
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, address owner)
        external
        override
        onlyPoolManager
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);

        if (params.tickLower >= params.tickUpper) {
            revert PoolErrors.TicksMisordered(params.tickLower, params.tickUpper);
        }
        if (params.tickLower < TickMathLib.MIN_TICK || params.tickUpper > TickMathLib.MAX_TICK) {
            revert PoolErrors.TickOutOfBounds(params.tickLower);
        }

        int128 delta128 = SafeCastLib.toInt128(params.liquidityDelta);
        (uint256 amount0, uint256 amount1) = _applyLiquidityDelta(pool, params, delta128, key.tickSpacing);
        (uint256 fees0, uint256 fees1) = _updatePosition(pool, params, owner, delta128);

        int128 d0;
        int128 d1;
        if (delta128 > 0) {
            d0 = SafeCastLib.toInt128(SafeCastLib.toInt256(amount0));
            d1 = SafeCastLib.toInt128(SafeCastLib.toInt256(amount1));
        } else if (delta128 < 0) {
            d0 = -SafeCastLib.toInt128(SafeCastLib.toInt256(amount0));
            d1 = -SafeCastLib.toInt128(SafeCastLib.toInt256(amount1));
        }
        callerDelta = toBalanceDelta(d0, d1);
        feesAccrued = toBalanceDelta(
            SafeCastLib.toInt128(SafeCastLib.toInt256(fees0)), SafeCastLib.toInt128(SafeCastLib.toInt256(fees1))
        );
    }

    /// @dev Updates both boundary ticks (Uniswap v3 order) and in-range liquidity; returns token amounts.
    function _applyLiquidityDelta(
        PoolState storage pool,
        IPoolManager.ModifyLiquidityParams memory params,
        int128 delta128,
        int24 tickSpacing
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (delta128 == 0) return (0, 0);
        Slot0 slot0 = pool.slot0;
        int24 currentTick = slot0.tick();
        uint256 g0 = pool.feeGrowthGlobal0X128;
        uint256 g1 = pool.feeGrowthGlobal1X128;
        _updateTick(pool, params.tickLower, currentTick, delta128, g0, g1, false, tickSpacing);
        _updateTick(pool, params.tickUpper, currentTick, delta128, g0, g1, true, tickSpacing);

        (amount0, amount1) =
            _computeModifyAmounts(slot0.sqrtPriceX96(), currentTick, params.tickLower, params.tickUpper, delta128);

        if (currentTick >= params.tickLower && currentTick < params.tickUpper) {
            pool.liquidity = delta128 < 0 ? pool.liquidity - uint128(-delta128) : pool.liquidity + uint128(delta128);
        }
    }

    /// @dev Updates the position's liquidity and fee checkpoints; returns fees owed since the last checkpoint.
    function _updatePosition(
        PoolState storage pool,
        IPoolManager.ModifyLiquidityParams memory params,
        address owner,
        int128 delta128
    ) internal returns (uint256 fees0, uint256 fees1) {
        Position.Info storage position =
            pool.positions[Position.getKey(owner, params.tickLower, params.tickUpper, params.salt)];
        uint128 liquidityBefore = position.liquidity;

        (uint256 inside0, uint256 inside1) = _getFeeGrowthInside(
            pool,
            params.tickLower,
            params.tickUpper,
            pool.slot0.tick(),
            pool.feeGrowthGlobal0X128,
            pool.feeGrowthGlobal1X128
        );

        if (liquidityBefore > 0) {
            unchecked {
                fees0 = FullMathLib.mulDiv(liquidityBefore, inside0 - position.feeGrowthInside0LastX128, Q128);
                fees1 = FullMathLib.mulDiv(liquidityBefore, inside1 - position.feeGrowthInside1LastX128, Q128);
            }
        }

        if (delta128 < 0) {
            if (liquidityBefore < uint128(-delta128)) revert PoolErrors.LiquidityOverflow();
            position.liquidity = liquidityBefore - uint128(-delta128);
        } else if (delta128 > 0) {
            position.liquidity = liquidityBefore + uint128(delta128);
        }
        position.feeGrowthInside0LastX128 = inside0;
        position.feeGrowthInside1LastX128 = inside1;
        position.lastModifiedBlock = uint64(block.number);
    }

    struct SwapExecutionState {
        uint160 sqrtPriceX96;
        int24 currentTick;
        uint128 liquidity;
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        bool exactInput;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint256 protocolFeeAmount;
    }

    struct SwapContext {
        bool zeroForOne;
        uint24 fee;
        uint24 protocolFee;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint24 fee, uint24 protocolFee)
        external
        override
        onlyPoolManager
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount)
    {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];
        Slot0 slot0 = pool.slot0;
        if (!slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();
        if (fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(fee);

        SwapExecutionState memory state;
        state.sqrtPriceX96 = slot0.sqrtPriceX96();
        state.currentTick = slot0.tick();
        state.liquidity = pool.liquidity;
        state.exactInput = params.amountSpecified > 0;
        state.amountSpecifiedRemaining =
            state.exactInput ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
        state.feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128;
        state.feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128;

        SwapContext memory ctx = SwapContext({
            zeroForOne: params.zeroForOne,
            fee: fee,
            protocolFee: protocolFee,
            tickSpacing: key.tickSpacing,
            sqrtPriceLimitX96: _resolvePriceLimit(params, state.sqrtPriceX96)
        });

        // SDX-004: keep stepping through zero-liquidity ranges (gaps) to the next initialized tick, as in
        // Uniswap v3/v4. Issue 7: the next initialized tick is found in O(1) (tree bitmap), so an empty range is
        // one step and the loop runs (initialized ticks crossed + 1) times.
        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != ctx.sqrtPriceLimitX96) {
            if (!_swapStep(pool, state, ctx)) break;
        }

        pool.slot0 = slot0.setSqrtPriceX96(state.sqrtPriceX96).setTick(state.currentTick);
        pool.liquidity = state.liquidity;
        pool.feeGrowthGlobal0X128 = state.feeGrowthGlobal0X128;
        pool.feeGrowthGlobal1X128 = state.feeGrowthGlobal1X128;
        protocolFeeAmount = state.protocolFeeAmount;
        swapDelta = _swapDelta(params, state);
    }

    /// @dev 0 means no limit (periphery default); otherwise the limit must be strictly on the swap side.
    function _resolvePriceLimit(IPoolManager.SwapParams memory params, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint160 limit)
    {
        limit = params.sqrtPriceLimitX96;
        if (limit == 0) {
            return params.zeroForOne ? TickMathLib.MIN_SQRT_RATIO + 1 : TickMathLib.MAX_SQRT_RATIO - 1;
        }
        if (params.zeroForOne) {
            if (limit >= sqrtPriceX96 || limit <= TickMathLib.MIN_SQRT_RATIO) {
                revert PoolErrors.PriceLimitAlreadyExceeded(sqrtPriceX96, limit);
            }
        } else if (limit <= sqrtPriceX96 || limit >= TickMathLib.MAX_SQRT_RATIO) {
            revert PoolErrors.PriceLimitAlreadyExceeded(sqrtPriceX96, limit);
        }
    }

    /// @dev One swap step towards the next initialized tick (or the price limit). Returns false to stop.
    function _swapStep(PoolState storage pool, SwapExecutionState memory state, SwapContext memory ctx)
        internal
        returns (bool)
    {
        (int24 nextTick, bool initialized) =
            _nextInitializedTick(pool, state.currentTick, ctx.tickSpacing, ctx.zeroForOne);
        if (nextTick < TickMathLib.MIN_TICK) nextTick = TickMathLib.MIN_TICK;
        if (nextTick > TickMathLib.MAX_TICK) nextTick = TickMathLib.MAX_TICK;

        uint160 sqrtPriceNextX96 = TickMathLib.getSqrtRatioAtTick(nextTick);
        _applyStep(state, ctx, sqrtPriceNextX96);

        if (state.sqrtPriceX96 != sqrtPriceNextX96) return false;
        if (initialized) {
            TickInfo storage tickInfo = pool.ticks[nextTick];
            // Flip fee growth outside on cross (unchecked wraparound)
            unchecked {
                tickInfo.feeGrowthOutside0X128 = state.feeGrowthGlobal0X128 - tickInfo.feeGrowthOutside0X128;
                tickInfo.feeGrowthOutside1X128 = state.feeGrowthGlobal1X128 - tickInfo.feeGrowthOutside1X128;
            }
            int128 net = tickInfo.liquidityNet;
            if (ctx.zeroForOne) net = -net;
            state.liquidity = net < 0 ? state.liquidity - uint128(-net) : state.liquidity + uint128(net);
        }
        state.currentTick = ctx.zeroForOne ? nextTick - 1 : nextTick;
        return true;
    }

    /// @dev Computes one step towards min(next tick, limit), updates amounts, fee growth and price in `state`.
    function _applyStep(SwapExecutionState memory state, SwapContext memory ctx, uint160 sqrtPriceNextX96)
        internal
        pure
    {
        uint160 sqrtPriceTargetX96 = sqrtPriceNextX96;
        if (ctx.zeroForOne ? sqrtPriceNextX96 < ctx.sqrtPriceLimitX96 : sqrtPriceNextX96 > ctx.sqrtPriceLimitX96) {
            sqrtPriceTargetX96 = ctx.sqrtPriceLimitX96;
        }

        (uint160 sqrtPriceAfterStepX96, uint256 amountInStep, uint256 amountOutStep, uint256 feeAmountStep) = computeSwapStep(
            state.sqrtPriceX96,
            sqrtPriceTargetX96,
            state.liquidity,
            state.amountSpecifiedRemaining,
            ctx.fee,
            ctx.zeroForOne,
            state.exactInput
        );

        if (state.exactInput) {
            state.amountSpecifiedRemaining -= (amountInStep + feeAmountStep);
            state.amountCalculated += amountOutStep;
        } else {
            state.amountSpecifiedRemaining -= amountOutStep;
            state.amountCalculated += (amountInStep + feeAmountStep);
        }

        // Accrue LP fees into global fee growth (protocol take withheld)
        if (feeAmountStep > 0 && state.liquidity > 0) {
            (uint256 lpFee, uint256 stepProtocol) = ProtocolFeeLib.splitFee(feeAmountStep, ctx.protocolFee);
            state.protocolFeeAmount += stepProtocol;
            if (lpFee > 0) {
                uint256 delta = FullMathLib.mulDiv(lpFee, Q128, state.liquidity);
                if (ctx.zeroForOne) {
                    state.feeGrowthGlobal0X128 += delta;
                } else {
                    state.feeGrowthGlobal1X128 += delta;
                }
            }
        }

        state.sqrtPriceX96 = sqrtPriceAfterStepX96;
        state.currentTick = TickMathLib.getTickAtSqrtRatio(sqrtPriceAfterStepX96);
    }

    function _swapDelta(IPoolManager.SwapParams memory params, SwapExecutionState memory state)
        internal
        pure
        returns (BalanceDelta)
    {
        int256 specifiedUsed = state.exactInput
            ? params.amountSpecified - SafeCastLib.toInt256(state.amountSpecifiedRemaining)
            : params.amountSpecified + SafeCastLib.toInt256(state.amountSpecifiedRemaining);
        int128 specified = SafeCastLib.toInt128(specifiedUsed);
        int128 calculated = SafeCastLib.toInt128(SafeCastLib.toInt256(state.amountCalculated));
        // exactInput: specified (input) > 0, calculated is output (negative). exactOutput: specified (output) < 0,
        // calculated is input (positive).
        if (state.exactInput) calculated = -calculated;
        // zeroForOne: token0 is the input; specified side = token0 iff exactInput.
        if (params.zeroForOne == state.exactInput) return toBalanceDelta(specified, calculated);
        return toBalanceDelta(calculated, specified);
    }

    /// @dev Floor division of a tick by the spacing (rounds toward negative infinity).
    function _compress(int24 tick, int24 tickSpacing) internal pure returns (int24 compressed) {
        compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
    }

    /**
     * @dev Next initialized tick in the swap direction, O(1) via the tree bitmap.
     * zeroForOne: largest initialized tick <= current; else smallest initialized tick > current.
     * If none exists the step targets MIN_TICK / MAX_TICK with `initialized = false`.
     */
    function _nextInitializedTick(PoolState storage pool, int24 tick, int24 tickSpacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        int24 compressed = _compress(tick, tickSpacing);
        uint24 key = TreeBitmapLib.toKey(compressed);
        if (lte) {
            if (pool.tickTree.contains(key)) return (compressed * tickSpacing, true);
            (bool found, uint24 k) = pool.tickTree.nextBelow(key);
            if (!found) return (TickMathLib.MIN_TICK, false);
            return (TreeBitmapLib.fromKey(k) * tickSpacing, true);
        }
        (bool foundUp, uint24 kUp) = pool.tickTree.nextAbove(key);
        if (!foundUp) return (TickMathLib.MAX_TICK, false);
        return (TreeBitmapLib.fromKey(kUp) * tickSpacing, true);
    }

    /**
     * @notice Uniswap v3 `tickSpacingToMaxLiquidityPerTick`: uint128.max split evenly over every usable tick.
     */
    function maxLiquidityPerTick(int24 tickSpacing) public pure returns (uint128) {
        if (tickSpacing <= 0) revert PoolErrors.InvalidTickSpacing(tickSpacing);
        int24 minTick = (TickMathLib.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMathLib.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        uint256 amountRemaining,
        uint24 feePips,
        bool zeroForOne,
        bool exactInput
    ) internal pure returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        if (feePips >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(feePips);
        if (exactInput) {
            uint256 amountRemainingLessFee = FullMathLib.mulDiv(amountRemaining, 1e6 - feePips, 1e6);
            amountIn = zeroForOne
                ? SqrtPriceMathLib.getAmount0Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, true)
                : SqrtPriceMathLib.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true);

            if (amountRemainingLessFee >= amountIn) {
                sqrtPriceNextX96 = sqrtPriceTargetX96;
            } else {
                sqrtPriceNextX96 = SqrtPriceMathLib.getNextSqrtPriceFromInput(
                    sqrtPriceCurrentX96, liquidity, amountRemainingLessFee, zeroForOne
                );
                amountIn = zeroForOne
                    ? SqrtPriceMathLib.getAmount0Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true)
                    : SqrtPriceMathLib.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);
            }

            amountOut = zeroForOne
                ? SqrtPriceMathLib.getAmount1Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, false)
                : SqrtPriceMathLib.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false);
            feeAmount = FullMathLib.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        } else {
            amountOut = zeroForOne
                ? SqrtPriceMathLib.getAmount1Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, false)
                : SqrtPriceMathLib.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, false);

            if (amountRemaining >= amountOut) {
                sqrtPriceNextX96 = sqrtPriceTargetX96;
            } else {
                sqrtPriceNextX96 = SqrtPriceMathLib.getNextSqrtPriceFromOutput(
                    sqrtPriceCurrentX96, liquidity, amountRemaining, zeroForOne
                );
                amountOut = zeroForOne
                    ? SqrtPriceMathLib.getAmount1Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, false)
                    : SqrtPriceMathLib.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false);
            }

            amountIn = zeroForOne
                ? SqrtPriceMathLib.getAmount0Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true)
                : SqrtPriceMathLib.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);
            feeAmount = FullMathLib.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }

    /// @inheritdoc ICurveEngine
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external override onlyPoolManager {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (amount0 == 0 && amount1 == 0) return;
        uint128 liquidity = pool.liquidity;
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
        return pools[id].liquidity;
    }

    function getTickInfo(PoolId id, int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet, bool initialized)
    {
        TickInfo storage info = pools[id].ticks[tick];
        return (info.liquidityGross, info.liquidityNet, info.initialized);
    }

    /// @notice Position state keyed by (owner, tickLower, tickUpper, salt); owner is the PoolManager caller.
    function getPosition(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (Position.Info memory)
    {
        return pools[id].positions[Position.getKey(owner, tickLower, tickUpper, salt)];
    }

    function getFeeGrowthGlobal(PoolId id)
        external
        view
        returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
    {
        PoolState storage pool = pools[id];
        return (pool.feeGrowthGlobal0X128, pool.feeGrowthGlobal1X128);
    }
}
