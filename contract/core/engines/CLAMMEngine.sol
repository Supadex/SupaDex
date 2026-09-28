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
import {TickBitmapLib} from "../../libraries/TickBitmapLib.sol";
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";

/**
 * @title CLAMMEngine
 * @notice Concentrated Liquidity AMM engine implementing Q64.96 tick math and bitmap traversal.
 */
contract CLAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;
    using TickBitmapLib for mapping(int16 => uint256);

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
        mapping(int16 => uint256) tickBitmap;
        mapping(int24 => TickInfo) ticks;
        mapping(bytes32 => Position.Info) positions;
    }

    mapping(PoolId => PoolState) internal pools;

    /**
     * @inheritdoc ICurveEngine
     */
    function initialize(
        PoolKey memory key,
        uint160 sqrtPriceX96
    ) external override returns (int24 tick) {
        PoolId id = key.toId();
        if (pools[id].slot0.isInitialized())
            revert PoolErrors.PoolAlreadyInitialized(id);

        tick = TickMathLib.getTickAtSqrtRatio(sqrtPriceX96);
        pools[id].slot0 = Slot0Library.pack(
            sqrtPriceX96,
            tick,
            0,
            key.fee,
            true
        );
    }

    /**
     * @notice Updates tick bitmap and liquidity gross/net for lower and upper ticks.
     */
    function _updateTicks(
        PoolState storage pool,
        int24 tickLower,
        int24 tickUpper,
        int128 delta128,
        int24 tickSpacing
    ) internal {
        // Lower Tick
        TickInfo storage lower = pool.ticks[tickLower];
        uint128 lowerGrossBefore = lower.liquidityGross;
        uint128 lowerGrossAfter = delta128 < 0
            ? lowerGrossBefore - uint128(-delta128)
            : lowerGrossBefore + uint128(delta128);

        if (lowerGrossBefore == 0) {
            pool.tickBitmap.flipTick(tickLower, tickSpacing);
            lower.initialized = true;
        }
        lower.liquidityGross = lowerGrossAfter;
        lower.liquidityNet += delta128;

        // Upper Tick
        TickInfo storage upper = pool.ticks[tickUpper];
        uint128 upperGrossBefore = upper.liquidityGross;
        uint128 upperGrossAfter = delta128 < 0
            ? upperGrossBefore - uint128(-delta128)
            : upperGrossBefore + uint128(delta128);

        if (upperGrossBefore == 0) {
            pool.tickBitmap.flipTick(tickUpper, tickSpacing);
            upper.initialized = true;
        }
        upper.liquidityGross = upperGrossAfter;
        upper.liquidityNet -= delta128;
    }

    /**
     * @notice Computes amount0 and amount1 deltas for a position modification.
     */
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
            amount0 = SqrtPriceMathLib.getAmount0Delta(
                sqrtRatioAX96,
                sqrtRatioBX96,
                absDelta,
                isAdd
            );
        } else if (currentTick < tickUpper) {
            amount0 = SqrtPriceMathLib.getAmount0Delta(
                sqrtPriceX96,
                sqrtRatioBX96,
                absDelta,
                isAdd
            );
            amount1 = SqrtPriceMathLib.getAmount1Delta(
                sqrtRatioAX96,
                sqrtPriceX96,
                absDelta,
                isAdd
            );
        } else {
            amount1 = SqrtPriceMathLib.getAmount1Delta(
                sqrtRatioAX96,
                sqrtRatioBX96,
                absDelta,
                isAdd
            );
        }
    }

    /**
     * @inheritdoc ICurveEngine
     */
    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    )
        external
        override
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];
        Slot0 slot0 = pool.slot0;
        if (!slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);

        if (params.tickLower >= params.tickUpper) {
            revert PoolErrors.TicksMisordered(
                params.tickLower,
                params.tickUpper
            );
        }
        if (
            params.tickLower < TickMathLib.MIN_TICK ||
            params.tickUpper > TickMathLib.MAX_TICK
        ) {
            revert PoolErrors.TickOutOfBounds(params.tickLower);
        }

        uint256 amount0 = 0;
        uint256 amount1 = 0;

        if (params.liquidityDelta != 0) {
            int128 delta128 = SafeCastLib.toInt128(params.liquidityDelta);
            _updateTicks(
                pool,
                params.tickLower,
                params.tickUpper,
                delta128,
                key.tickSpacing
            );

            int24 currentTick = slot0.tick();
            (amount0, amount1) = _computeModifyAmounts(
                slot0.sqrtPriceX96(),
                currentTick,
                params.tickLower,
                params.tickUpper,
                delta128
            );

            if (
                currentTick >= params.tickLower &&
                currentTick < params.tickUpper
            ) {
                pool.liquidity = delta128 < 0
                    ? pool.liquidity - uint128(-delta128)
                    : pool.liquidity + uint128(delta128);
            }
        }

        int128 d0 = params.liquidityDelta > 0
            ? SafeCastLib.toInt128(SafeCastLib.toInt256(amount0))
            : -SafeCastLib.toInt128(SafeCastLib.toInt256(amount0));
        int128 d1 = params.liquidityDelta > 0
            ? SafeCastLib.toInt128(SafeCastLib.toInt256(amount1))
            : -SafeCastLib.toInt128(SafeCastLib.toInt256(amount1));

        callerDelta = toBalanceDelta(d0, d1);
        feesAccrued = toBalanceDelta(0, 0);
    }

    struct SwapExecutionState {
        uint160 sqrtPriceX96;
        int24 currentTick;
        uint128 liquidity;
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        bool exactInput;
    }

    /**
     * @inheritdoc ICurveEngine
     */
    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        uint24 fee
    ) external override returns (BalanceDelta swapDelta) {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];
        Slot0 slot0 = pool.slot0;
        if (!slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();

        SwapExecutionState memory state;
        state.sqrtPriceX96 = slot0.sqrtPriceX96();
        state.currentTick = slot0.tick();
        state.liquidity = pool.liquidity;
        state.exactInput = params.amountSpecified > 0;
        state.amountSpecifiedRemaining = state.exactInput
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        while (state.amountSpecifiedRemaining > 0 && state.liquidity > 0) {
            (int24 nextTick, bool initialized) = pool
                .tickBitmap
                .nextInitializedTickWithinOneWord(
                    state.currentTick,
                    key.tickSpacing,
                    params.zeroForOne
                );

            if (nextTick < TickMathLib.MIN_TICK)
                nextTick = TickMathLib.MIN_TICK;
            if (nextTick > TickMathLib.MAX_TICK)
                nextTick = TickMathLib.MAX_TICK;

            uint160 sqrtPriceNextX96 = TickMathLib.getSqrtRatioAtTick(nextTick);

            (
                uint160 sqrtPriceAfterStepX96,
                uint256 amountInStep,
                uint256 amountOutStep,
                uint256 feeAmountStep
            ) = computeSwapStep(
                    state.sqrtPriceX96,
                    sqrtPriceNextX96,
                    state.liquidity,
                    state.amountSpecifiedRemaining,
                    fee,
                    params.zeroForOne,
                    state.exactInput
                );

            if (state.exactInput) {
                state.amountSpecifiedRemaining -= (amountInStep +
                    feeAmountStep);
                state.amountCalculated += amountOutStep;
            } else {
                state.amountSpecifiedRemaining -= amountOutStep;
                state.amountCalculated += (amountInStep + feeAmountStep);
            }

            state.sqrtPriceX96 = sqrtPriceAfterStepX96;
            state.currentTick = TickMathLib.getTickAtSqrtRatio(
                state.sqrtPriceX96
            );

            if (state.sqrtPriceX96 == sqrtPriceNextX96) {
                if (initialized) {
                    int128 net = pool.ticks[nextTick].liquidityNet;
                    if (params.zeroForOne) net = -net;
                    state.liquidity = net < 0
                        ? state.liquidity - uint128(-net)
                        : state.liquidity + uint128(net);
                }
                state.currentTick = params.zeroForOne ? nextTick - 1 : nextTick;
            } else {
                break;
            }
        }

        pool.slot0 = slot0.setSqrtPriceX96(state.sqrtPriceX96).setTick(
            state.currentTick
        );
        pool.liquidity = state.liquidity;

        if (params.zeroForOne) {
            int128 a0 = state.exactInput
                ? SafeCastLib.toInt128(
                    params.amountSpecified -
                        SafeCastLib.toInt256(state.amountSpecifiedRemaining)
                )
                : SafeCastLib.toInt128(
                    SafeCastLib.toInt256(state.amountCalculated)
                );
            int128 a1 = state.exactInput
                ? -SafeCastLib.toInt128(
                    SafeCastLib.toInt256(state.amountCalculated)
                )
                : -SafeCastLib.toInt128(
                    -params.amountSpecified -
                        SafeCastLib.toInt256(state.amountSpecifiedRemaining)
                );
            swapDelta = toBalanceDelta(a0, a1);
        } else {
            int128 a0 = state.exactInput
                ? -SafeCastLib.toInt128(
                    SafeCastLib.toInt256(state.amountCalculated)
                )
                : -SafeCastLib.toInt128(
                    -params.amountSpecified -
                        SafeCastLib.toInt256(state.amountSpecifiedRemaining)
                );
            int128 a1 = state.exactInput
                ? SafeCastLib.toInt128(
                    params.amountSpecified -
                        SafeCastLib.toInt256(state.amountSpecifiedRemaining)
                )
                : SafeCastLib.toInt128(
                    SafeCastLib.toInt256(state.amountCalculated)
                );
            swapDelta = toBalanceDelta(a0, a1);
        }
    }

    /**
     * @notice Computes a single swap step within a tick range.
     */
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        uint256 amountRemaining,
        uint24 feePips,
        bool zeroForOne,
        bool exactInput
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        if (exactInput) {
            uint256 amountRemainingLessFee = FullMathLib.mulDiv(
                amountRemaining,
                1e6 - feePips,
                1e6
            );
            amountIn = zeroForOne
                ? SqrtPriceMathLib.getAmount0Delta(
                    sqrtPriceTargetX96,
                    sqrtPriceCurrentX96,
                    liquidity,
                    true
                )
                : SqrtPriceMathLib.getAmount1Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceTargetX96,
                    liquidity,
                    true
                );

            if (amountRemainingLessFee >= amountIn) {
                sqrtPriceNextX96 = sqrtPriceTargetX96;
            } else {
                sqrtPriceNextX96 = SqrtPriceMathLib.getNextSqrtPriceFromInput(
                    sqrtPriceCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
                amountIn = zeroForOne
                    ? SqrtPriceMathLib.getAmount0Delta(
                        sqrtPriceNextX96,
                        sqrtPriceCurrentX96,
                        liquidity,
                        true
                    )
                    : SqrtPriceMathLib.getAmount1Delta(
                        sqrtPriceCurrentX96,
                        sqrtPriceNextX96,
                        liquidity,
                        true
                    );
            }

            amountOut = zeroForOne
                ? SqrtPriceMathLib.getAmount1Delta(
                    sqrtPriceNextX96,
                    sqrtPriceCurrentX96,
                    liquidity,
                    false
                )
                : SqrtPriceMathLib.getAmount0Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceNextX96,
                    liquidity,
                    false
                );
            feeAmount = FullMathLib.mulDivRoundingUp(
                amountIn,
                feePips,
                1e6 - feePips
            );
        } else {
            amountOut = zeroForOne
                ? SqrtPriceMathLib.getAmount1Delta(
                    sqrtPriceTargetX96,
                    sqrtPriceCurrentX96,
                    liquidity,
                    false
                )
                : SqrtPriceMathLib.getAmount0Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceTargetX96,
                    liquidity,
                    false
                );

            if (amountRemaining >= amountOut) {
                sqrtPriceNextX96 = sqrtPriceTargetX96;
            } else {
                sqrtPriceNextX96 = SqrtPriceMathLib.getNextSqrtPriceFromOutput(
                    sqrtPriceCurrentX96,
                    liquidity,
                    amountRemaining,
                    zeroForOne
                );
                amountOut = zeroForOne
                    ? SqrtPriceMathLib.getAmount1Delta(
                        sqrtPriceNextX96,
                        sqrtPriceCurrentX96,
                        liquidity,
                        false
                    )
                    : SqrtPriceMathLib.getAmount0Delta(
                        sqrtPriceCurrentX96,
                        sqrtPriceNextX96,
                        liquidity,
                        false
                    );
            }

            amountIn = zeroForOne
                ? SqrtPriceMathLib.getAmount0Delta(
                    sqrtPriceNextX96,
                    sqrtPriceCurrentX96,
                    liquidity,
                    true
                )
                : SqrtPriceMathLib.getAmount1Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceNextX96,
                    liquidity,
                    true
                );
            feeAmount = FullMathLib.mulDivRoundingUp(
                amountIn,
                feePips,
                1e6 - feePips
            );
        }
    }

    /**
     * @notice Returns current Slot0 for a pool.
     */
    function getSlot0(PoolId id) external view returns (Slot0) {
        return pools[id].slot0;
    }

    /**
     * @notice Returns active liquidity for a pool.
     */
    function getLiquidity(PoolId id) external view returns (uint128) {
        return pools[id].liquidity;
    }
}
