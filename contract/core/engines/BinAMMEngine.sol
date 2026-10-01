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
import {BinMathLib} from "../../libraries/BinMathLib.sol";
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";
import {ProtocolFeeLib} from "../../libraries/ProtocolFeeLib.sol";

/**
 * @title BinAMMEngine
 * @notice Discretized Liquidity AMM with per-bin fee growth accrual to LP positions.
 */
contract BinAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;

    uint256 internal constant Q128 = 1 << 128;

    struct Bin {
        uint128 reserve0;
        uint128 reserve1;
        uint128 totalLiquidity;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
    }

    struct BinPoolState {
        Slot0 slot0;
        uint24 activeBinId;
        uint16 binStep;
        uint256 activePriceX128;
        mapping(uint24 => Bin) bins;
        mapping(bytes32 => Position.Info) positions;
    }

    mapping(PoolId => BinPoolState) internal pools;

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external override returns (int24 tick) {
        PoolId id = key.toId();
        if (pools[id].slot0.isInitialized()) {
            revert PoolErrors.PoolAlreadyInitialized(id);
        }

        uint16 binStep = uint16(uint24(key.tickSpacing > 0 ? key.tickSpacing : int24(10)));
        uint256 priceX128 = BinMathLib.getPriceX128FromSqrtPriceX96(sqrtPriceX96);
        if (priceX128 == 0) priceX128 = BinMathLib.SCALE;

        uint24 binId = BinMathLib.CENTER_BIN_ID;
        if (priceX128 != BinMathLib.SCALE && binStep > 0) {
            binId = BinMathLib.approxIdFromPrice(priceX128, binStep);
        }

        pools[id].activeBinId = binId;
        pools[id].binStep = binStep;
        pools[id].activePriceX128 = priceX128;
        int24 binTick = int24(uint24(binId));
        pools[id].slot0 = Slot0Library.pack(sqrtPriceX96, binTick, 0, key.fee, true);
        tick = binTick;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        override
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) {
            revert PoolErrors.PoolNotInitialized(id);
        }

        uint24 binId = pool.activeBinId;
        Bin storage bin = pool.bins[binId];
        uint256 priceX128 = pool.activePriceX128;
        if (priceX128 == 0) priceX128 = BinMathLib.SCALE;

        bytes32 posKey = keccak256(abi.encodePacked(params.tickLower, params.tickUpper, params.salt));
        Position.Info storage position = pool.positions[posKey];

        uint128 positionLiquidity = position.liquidity;
        uint256 fees0;
        uint256 fees1;
        if (positionLiquidity > 0) {
            fees0 = FullMathLib.mulDiv(positionLiquidity, bin.feeGrowth0X128 - position.feeGrowthInside0LastX128, Q128);
            fees1 = FullMathLib.mulDiv(positionLiquidity, bin.feeGrowth1X128 - position.feeGrowthInside1LastX128, Q128);
        }

        uint256 amount0 =
            uint256(params.liquidityDelta > 0 ? params.liquidityDelta : -params.liquidityDelta);
        uint256 amount1 = (amount0 * priceX128) >> BinMathLib.SCALE_OFFSET;
        if (amount0 > 0 && amount1 == 0 && priceX128 > 0) amount1 = 1;

        if (params.liquidityDelta > 0) {
            bin.reserve0 += uint128(amount0);
            bin.reserve1 += uint128(amount1);
            bin.totalLiquidity += uint128(amount0);
            position.liquidity = positionLiquidity + uint128(amount0);
            callerDelta = toBalanceDelta(
                SafeCastLib.toInt128(int256(amount0)), SafeCastLib.toInt128(int256(amount1))
            );
        } else if (params.liquidityDelta < 0) {
            if (bin.reserve0 < amount0 || bin.reserve1 < amount1 || positionLiquidity < amount0) {
                revert PoolErrors.LiquidityOverflow();
            }
            bin.reserve0 -= uint128(amount0);
            bin.reserve1 -= uint128(amount1);
            bin.totalLiquidity -= uint128(amount0);
            position.liquidity = positionLiquidity - uint128(amount0);
            callerDelta = toBalanceDelta(
                -SafeCastLib.toInt128(int256(amount0)), -SafeCastLib.toInt128(int256(amount1))
            );
        } else {
            callerDelta = toBalanceDelta(0, 0);
        }

        position.feeGrowthInside0LastX128 = bin.feeGrowth0X128;
        position.feeGrowthInside1LastX128 = bin.feeGrowth1X128;
        position.lastModifiedBlock = uint64(block.number);

        feesAccrued = toBalanceDelta(
            fees0 > 0 ? SafeCastLib.toInt128(SafeCastLib.toInt256(fees0)) : int128(0),
            fees1 > 0 ? SafeCastLib.toInt128(SafeCastLib.toInt256(fees1)) : int128(0)
        );
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint24 fee, uint24 protocolFee)
        external
        override
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount)
    {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) {
            revert PoolErrors.PoolNotInitialized(id);
        }
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();

        uint24 activeId = pool.activeBinId;
        Bin storage activeBin = pool.bins[activeId];
        uint256 priceX128 = pool.activePriceX128;
        if (priceX128 == 0) priceX128 = BinMathLib.SCALE;

        uint256 amountIn = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);
        uint256 feeAmount = FullMathLib.mulDivRoundingUp(amountIn, fee, 1e6);
        uint256 amountInAfterFee = amountIn > feeAmount ? amountIn - feeAmount : 0;

        uint256 amountOut = BinMathLib.getSwapAmountInBin(amountInAfterFee, priceX128, params.zeroForOne);

        uint256 lpFee;
        (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(feeAmount, protocolFee);

        // Accrue LP portion via fee growth (fee not added as free reserve)
        if (lpFee > 0 && activeBin.totalLiquidity > 0) {
            uint256 delta = FullMathLib.mulDiv(lpFee, Q128, activeBin.totalLiquidity);
            if (params.zeroForOne) {
                activeBin.feeGrowth0X128 += delta;
            } else {
                activeBin.feeGrowth1X128 += delta;
            }
        }

        if (params.zeroForOne) {
            if (activeBin.reserve1 < amountOut) amountOut = activeBin.reserve1;
            activeBin.reserve0 += uint128(amountInAfterFee);
            activeBin.reserve1 -= uint128(amountOut);
            swapDelta = toBalanceDelta(SafeCastLib.toInt128(int256(amountIn)), -SafeCastLib.toInt128(int256(amountOut)));
        } else {
            if (activeBin.reserve0 < amountOut) amountOut = activeBin.reserve0;
            activeBin.reserve1 += uint128(amountInAfterFee);
            activeBin.reserve0 -= uint128(amountOut);
            swapDelta = toBalanceDelta(-SafeCastLib.toInt128(int256(amountOut)), SafeCastLib.toInt128(int256(amountIn)));
        }
    }

    function getSlot0(PoolId id) external view override returns (Slot0) {
        return pools[id].slot0;
    }

    function getLiquidity(PoolId id) external view override returns (uint128) {
        uint24 activeId = pools[id].activeBinId;
        return pools[id].bins[activeId].totalLiquidity;
    }

    function getActiveBinId(PoolId id) external view returns (uint24) {
        return pools[id].activeBinId;
    }

    function getBinReserves(PoolId id, uint24 binId) external view returns (uint128 reserve0, uint128 reserve1) {
        Bin storage bin = pools[id].bins[binId];
        return (bin.reserve0, bin.reserve1);
    }
}
