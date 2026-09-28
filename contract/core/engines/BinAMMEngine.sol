// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICurveEngine} from "../../interfaces/ICurveEngine.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId} from "../../types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "../../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../types/Slot0.sol";
import {PoolErrors} from "../../errors/PoolErrors.sol";
import {BinMathLib} from "../../libraries/BinMathLib.sol";
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";

/**
 * @title BinAMMEngine
 * @notice Discretized Liquidity AMM engine offering zero-slippage execution inside active price bins.
 * @dev This engine implements a discrete-price AMM by dividing the price space into non-overlapping bins.
 * Liquidity is only active within a specific bin, and swaps execute at the geometric mean price of that bin.
 */
contract BinAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;

    struct Bin {
        uint128 reserve0;
        uint128 reserve1;
    }

    struct BinPoolState {
        Slot0 slot0;
        uint24 activeBinId;
        uint16 binStep;
        mapping(uint24 => Bin) bins;
    }

    mapping(PoolId => BinPoolState) internal pools;

    /**
     * @inheritdoc ICurveEngine
     */
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external override returns (int24 tick) {
        PoolId id = key.toId();
        if (pools[id].slot0.isInitialized()) {
            revert PoolErrors.PoolAlreadyInitialized(id);
        }

        uint24 binId = BinMathLib.CENTER_BIN_ID;
        uint16 binStep = uint16(uint24(key.tickSpacing > 0 ? key.tickSpacing : int24(10)));

        pools[id].activeBinId = binId;
        pools[id].binStep = binStep;
        pools[id].slot0 = Slot0Library.pack(sqrtPriceX96, 0, 0, key.fee, true);
        tick = 0;
    }

    /**
     * @inheritdoc ICurveEngine
     */
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

        uint24 binId = uint24(uint256(int256(params.tickLower)));
        Bin storage bin = pool.bins[binId];

        uint128 deltaAmount =
            uint128(params.liquidityDelta > 0 ? uint256(params.liquidityDelta) : uint256(-params.liquidityDelta));

        if (params.liquidityDelta > 0) {
            bin.reserve0 += deltaAmount;
            bin.reserve1 += deltaAmount;
            callerDelta = toBalanceDelta(
                SafeCastLib.toInt128(int256(uint256(deltaAmount))), SafeCastLib.toInt128(int256(uint256(deltaAmount)))
            );
        } else {
            if (bin.reserve0 < deltaAmount || bin.reserve1 < deltaAmount) {
                revert PoolErrors.LiquidityOverflow();
            }
            bin.reserve0 -= deltaAmount;
            bin.reserve1 -= deltaAmount;
            callerDelta = toBalanceDelta(
                -SafeCastLib.toInt128(int256(uint256(deltaAmount))), -SafeCastLib.toInt128(int256(uint256(deltaAmount)))
            );
        }

        feesAccrued = toBalanceDelta(0, 0);
    }

    /**
     * @inheritdoc ICurveEngine
     */
    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint24 fee)
        external
        override
        returns (BalanceDelta swapDelta)
    {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) {
            revert PoolErrors.PoolNotInitialized(id);
        }
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();

        uint24 activeId = pool.activeBinId;
        Bin storage activeBin = pool.bins[activeId];

        uint256 amountIn = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);
        uint256 feeAmount = FullMathLib.mulDivRoundingUp(amountIn, fee, 1e6);
        uint256 amountInAfterFee = amountIn > feeAmount ? amountIn - feeAmount : 0;

        uint256 amountOut =
            BinMathLib.computeSwapAmountInBin(amountInAfterFee, activeId, pool.binStep, params.zeroForOne);

        if (params.zeroForOne) {
            if (activeBin.reserve1 < amountOut) amountOut = activeBin.reserve1;
            activeBin.reserve0 += uint128(amountIn);
            activeBin.reserve1 -= uint128(amountOut);
            swapDelta = toBalanceDelta(SafeCastLib.toInt128(int256(amountIn)), -SafeCastLib.toInt128(int256(amountOut)));
        } else {
            if (activeBin.reserve0 < amountOut) amountOut = activeBin.reserve0;
            activeBin.reserve1 += uint128(amountIn);
            activeBin.reserve0 -= uint128(amountOut);
            swapDelta = toBalanceDelta(-SafeCastLib.toInt128(int256(amountOut)), SafeCastLib.toInt128(int256(amountIn)));
        }
    }

    /**
     * @inheritdoc ICurveEngine
     */
    function getSlot0(PoolId id) external view override returns (Slot0) {
        return pools[id].slot0;
    }

    /**
     * @inheritdoc ICurveEngine
     */
    function getLiquidity(PoolId id) external view override returns (uint128) {
        uint24 activeId = pools[id].activeBinId;
        Bin storage bin = pools[id].bins[activeId];
        return uint128(bin.reserve0 + bin.reserve1);
    }

    /**
     * @notice Returns pool's active bin ID.
     * @param id The ID of the pool.
     */
    function getActiveBinId(PoolId id) external view returns (uint24) {
        return pools[id].activeBinId;
    }

    /**
     * @notice Returns bin reserves.
     * @param id The ID of the pool.
     * @param binId The ID of the bin.
     */
    function getBinReserves(PoolId id, uint24 binId) external view returns (uint128 reserve0, uint128 reserve1) {
        Bin storage bin = pools[id].bins[binId];
        return (bin.reserve0, bin.reserve1);
    }
}
