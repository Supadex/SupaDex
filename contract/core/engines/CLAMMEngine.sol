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
import {ProtocolFeeLib} from "../../libraries/ProtocolFeeLib.sol";

/**
 * @title CLAMMEngine
 * @notice Concentrated Liquidity AMM with Uniswap-style fee growth accrual to LPs.
 */
contract CLAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;
    using TickBitmapLib for mapping(int16 => uint256);

    uint256 internal constant Q128 = 1 << 128;

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
        mapping(int16 => uint256) tickBitmap;
        mapping(int24 => TickInfo) ticks;
        mapping(bytes32 => Position.Info) positions;
    }

    mapping(PoolId => PoolState) internal pools;

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external override returns (int24 tick) {
        PoolId id = key.toId();
        if (pools[id].slot0.isInitialized()) {
            revert PoolErrors.PoolAlreadyInitialized(id);
        }

        tick = TickMathLib.getTickAtSqrtRatio(sqrtPriceX96);
        pools[id].slot0 = Slot0Library.pack(sqrtPriceX96, tick, 0, key.fee, true);
    }

    function _positionKey(int24 tickLower, int24 tickUpper, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tickLower, tickUpper, salt));
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
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        uint256 feeGrowthAbove0;
        uint256 feeGrowthAbove1;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0 - feeGrowthAbove0;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1 - feeGrowthAbove1;
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
        TickInfo storage info = pool.ticks[tick];
        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = liquidityDelta < 0
            ? liquidityGrossBefore - uint128(-liquidityDelta)
            : liquidityGrossBefore + uint128(liquidityDelta);

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // When initializing a tick at or below current, seed outside growth to global
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
            info.initialized = true;
            pool.tickBitmap.flipTick(tick, tickSpacing);
        }

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = upper ? info.liquidityNet - liquidityDelta : info.liquidityNet + liquidityDelta;

        if (liquidityGrossAfter == 0) {
            info.initialized = false;
            pool.tickBitmap.flipTick(tick, tickSpacing);
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

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        override
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];
        Slot0 slot0 = pool.slot0;
        if (!slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);

        if (params.tickLower >= params.tickUpper) {
            revert PoolErrors.TicksMisordered(params.tickLower, params.tickUpper);
        }
        if (params.tickLower < TickMathLib.MIN_TICK || params.tickUpper > TickMathLib.MAX_TICK) {
            revert PoolErrors.TickOutOfBounds(params.tickLower);
        }

        int24 currentTick = slot0.tick();
        uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128;

        bytes32 posKey = _positionKey(params.tickLower, params.tickUpper, params.salt);
        Position.Info storage position = pool.positions[posKey];

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(
            pool, params.tickLower, params.tickUpper, currentTick, feeGrowthGlobal0X128, feeGrowthGlobal1X128
        );

        uint128 positionLiquidity = position.liquidity;
        uint256 fees0;
        uint256 fees1;
        if (positionLiquidity > 0) {
            fees0 = FullMathLib.mulDiv(
                positionLiquidity, feeGrowthInside0X128 - position.feeGrowthInside0LastX128, Q128
            );
            fees1 = FullMathLib.mulDiv(
                positionLiquidity, feeGrowthInside1X128 - position.feeGrowthInside1LastX128, Q128
            );
        }

        uint256 amount0;
        uint256 amount1;

        if (params.liquidityDelta != 0) {
            int128 delta128 = SafeCastLib.toInt128(params.liquidityDelta);

            _updateTick(
                pool,
                params.tickLower,
                currentTick,
                delta128,
                feeGrowthGlobal0X128,
                feeGrowthGlobal1X128,
                false,
                key.tickSpacing
            );
            _updateTick(
                pool,
                params.tickUpper,
                currentTick,
                delta128,
                feeGrowthGlobal0X128,
                feeGrowthGlobal1X128,
                true,
                key.tickSpacing
            );

            (amount0, amount1) = _computeModifyAmounts(
                slot0.sqrtPriceX96(), currentTick, params.tickLower, params.tickUpper, delta128
            );

            if (currentTick >= params.tickLower && currentTick < params.tickUpper) {
                pool.liquidity =
                    delta128 < 0 ? pool.liquidity - uint128(-delta128) : pool.liquidity + uint128(delta128);
            }

            if (delta128 < 0) {
                if (positionLiquidity < uint128(-delta128)) revert PoolErrors.LiquidityOverflow();
                position.liquidity = positionLiquidity - uint128(-delta128);
            } else {
                position.liquidity = positionLiquidity + uint128(delta128);
            }
        }

        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        position.lastModifiedBlock = uint64(block.number);

        int128 d0 = params.liquidityDelta > 0
            ? SafeCastLib.toInt128(SafeCastLib.toInt256(amount0))
            : params.liquidityDelta < 0
                ? -SafeCastLib.toInt128(SafeCastLib.toInt256(amount0))
                : int128(0);
        int128 d1 = params.liquidityDelta > 0
            ? SafeCastLib.toInt128(SafeCastLib.toInt256(amount1))
            : params.liquidityDelta < 0
                ? -SafeCastLib.toInt128(SafeCastLib.toInt256(amount1))
                : int128(0);

        callerDelta = toBalanceDelta(d0, d1);
        feesAccrued = toBalanceDelta(
            fees0 > 0 ? SafeCastLib.toInt128(SafeCastLib.toInt256(fees0)) : int128(0),
            fees1 > 0 ? SafeCastLib.toInt128(SafeCastLib.toInt256(fees1)) : int128(0)
        );
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
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint24 fee, uint24 protocolFee)
        external
        override
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount)
    {
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
        state.amountSpecifiedRemaining =
            state.exactInput ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
        state.feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128;
        state.feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128;

        while (state.amountSpecifiedRemaining > 0 && state.liquidity > 0) {
            (int24 nextTick, bool initialized) = pool.tickBitmap.nextInitializedTickWithinOneWord(
                state.currentTick, key.tickSpacing, params.zeroForOne
            );

            if (nextTick < TickMathLib.MIN_TICK) nextTick = TickMathLib.MIN_TICK;
            if (nextTick > TickMathLib.MAX_TICK) nextTick = TickMathLib.MAX_TICK;

            uint160 sqrtPriceNextX96 = TickMathLib.getSqrtRatioAtTick(nextTick);

            (uint160 sqrtPriceAfterStepX96, uint256 amountInStep, uint256 amountOutStep, uint256 feeAmountStep) =
                computeSwapStep(
                    state.sqrtPriceX96,
                    sqrtPriceNextX96,
                    state.liquidity,
                    state.amountSpecifiedRemaining,
                    fee,
                    params.zeroForOne,
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
                (uint256 lpFee, uint256 stepProtocol) = ProtocolFeeLib.splitFee(feeAmountStep, protocolFee);
                protocolFeeAmount += stepProtocol;
                if (lpFee > 0) {
                    uint256 delta = FullMathLib.mulDiv(lpFee, Q128, state.liquidity);
                    if (params.zeroForOne) {
                        state.feeGrowthGlobal0X128 += delta;
                    } else {
                        state.feeGrowthGlobal1X128 += delta;
                    }
                }
            }

            state.sqrtPriceX96 = sqrtPriceAfterStepX96;
            state.currentTick = TickMathLib.getTickAtSqrtRatio(state.sqrtPriceX96);

            if (state.sqrtPriceX96 == sqrtPriceNextX96) {
                if (initialized) {
                    TickInfo storage tickInfo = pool.ticks[nextTick];
                    // Flip fee growth outside on cross
                    tickInfo.feeGrowthOutside0X128 =
                        state.feeGrowthGlobal0X128 - tickInfo.feeGrowthOutside0X128;
                    tickInfo.feeGrowthOutside1X128 =
                        state.feeGrowthGlobal1X128 - tickInfo.feeGrowthOutside1X128;

                    int128 net = tickInfo.liquidityNet;
                    if (params.zeroForOne) net = -net;
                    state.liquidity = net < 0 ? state.liquidity - uint128(-net) : state.liquidity + uint128(net);
                }
                state.currentTick = params.zeroForOne ? nextTick - 1 : nextTick;
            } else {
                break;
            }
        }

        pool.slot0 = slot0.setSqrtPriceX96(state.sqrtPriceX96).setTick(state.currentTick);
        pool.liquidity = state.liquidity;
        pool.feeGrowthGlobal0X128 = state.feeGrowthGlobal0X128;
        pool.feeGrowthGlobal1X128 = state.feeGrowthGlobal1X128;

        if (params.zeroForOne) {
            int128 a0 = state.exactInput
                ? SafeCastLib.toInt128(params.amountSpecified - SafeCastLib.toInt256(state.amountSpecifiedRemaining))
                : SafeCastLib.toInt128(SafeCastLib.toInt256(state.amountCalculated));
            int128 a1 = state.exactInput
                ? -SafeCastLib.toInt128(SafeCastLib.toInt256(state.amountCalculated))
                : -SafeCastLib.toInt128(-params.amountSpecified - SafeCastLib.toInt256(state.amountSpecifiedRemaining));
            swapDelta = toBalanceDelta(a0, a1);
        } else {
            int128 a0 = state.exactInput
                ? -SafeCastLib.toInt128(SafeCastLib.toInt256(state.amountCalculated))
                : -SafeCastLib.toInt128(-params.amountSpecified - SafeCastLib.toInt256(state.amountSpecifiedRemaining));
            int128 a1 = state.exactInput
                ? SafeCastLib.toInt128(params.amountSpecified - SafeCastLib.toInt256(state.amountSpecifiedRemaining))
                : SafeCastLib.toInt128(SafeCastLib.toInt256(state.amountCalculated));
            swapDelta = toBalanceDelta(a0, a1);
        }
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

    function getSlot0(PoolId id) external view override returns (Slot0) {
        return pools[id].slot0;
    }

    function getLiquidity(PoolId id) external view override returns (uint128) {
        return pools[id].liquidity;
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
