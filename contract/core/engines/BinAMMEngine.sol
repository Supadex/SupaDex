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
    uint24 internal constant MAX_FEE_PIPS = 1_000_000;

    address public immutable override poolManager;

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

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, address owner)
        external
        override
        onlyPoolManager
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

        bytes32 posKey = Position.getKey(owner, params.tickLower, params.tickUpper, params.salt);
        Position.Info storage position = pool.positions[posKey];

        uint128 positionLiquidity = position.liquidity;
        uint256 fees0;
        uint256 fees1;
        if (positionLiquidity > 0) {
            unchecked {
                fees0 = FullMathLib.mulDiv(
                    positionLiquidity, bin.feeGrowth0X128 - position.feeGrowthInside0LastX128, Q128
                );
                fees1 = FullMathLib.mulDiv(
                    positionLiquidity, bin.feeGrowth1X128 - position.feeGrowthInside1LastX128, Q128
                );
            }
        }

        if (params.liquidityDelta > 0) {
            uint256 amount0 = uint256(params.liquidityDelta);
            uint256 amount1 = (amount0 * priceX128) >> BinMathLib.SCALE_OFFSET;
            if (amount0 > 0 && amount1 == 0 && priceX128 > 0) amount1 = 1;

            bin.reserve0 += uint128(amount0);
            bin.reserve1 += uint128(amount1);
            bin.totalLiquidity += uint128(amount0);
            position.liquidity = positionLiquidity + uint128(amount0);
            callerDelta = toBalanceDelta(
                SafeCastLib.toInt128(int256(amount0)), SafeCastLib.toInt128(int256(amount1))
            );
        } else if (params.liquidityDelta < 0) {
            uint256 shares = uint256(-params.liquidityDelta);
            if (positionLiquidity < shares || bin.totalLiquidity == 0) {
                revert PoolErrors.LiquidityOverflow();
            }
            // Pro-rata exit against current reserves
            uint256 amount0 = FullMathLib.mulDiv(shares, bin.reserve0, bin.totalLiquidity);
            uint256 amount1 = FullMathLib.mulDiv(shares, bin.reserve1, bin.totalLiquidity);

            bin.reserve0 -= uint128(amount0);
            bin.reserve1 -= uint128(amount1);
            bin.totalLiquidity -= uint128(shares);
            position.liquidity = positionLiquidity - uint128(shares);
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
        onlyPoolManager
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount)
    {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) {
            revert PoolErrors.PoolNotInitialized(id);
        }
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();
        if (fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(fee);

        Bin storage activeBin = pool.bins[pool.activeBinId];
        uint256 priceX128 = pool.activePriceX128;
        if (priceX128 == 0) priceX128 = BinMathLib.SCALE;
        _enforcePriceLimit(priceX128, params.sqrtPriceLimitX96, params.zeroForOne);

        if (params.amountSpecified > 0) {
            return _swapExactIn(activeBin, params, fee, protocolFee, priceX128);
        }
        return _swapExactOut(activeBin, params, fee, protocolFee, priceX128);
    }

    function _swapExactIn(
        Bin storage activeBin,
        IPoolManager.SwapParams memory params,
        uint24 fee,
        uint24 protocolFee,
        uint256 priceX128
    ) internal returns (BalanceDelta swapDelta, uint256 protocolFeeAmount) {
        uint256 amountIn = uint256(params.amountSpecified);
        uint256 feeAmount = FullMathLib.mulDivRoundingUp(amountIn, fee, 1e6);
        uint256 amountInAfterFee = amountIn > feeAmount ? amountIn - feeAmount : 0;
        uint256 amountOut = BinMathLib.getSwapAmountInBin(amountInAfterFee, priceX128, params.zeroForOne);

        uint256 lpFee;
        (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(feeAmount, protocolFee);
        _accrueBinFee(activeBin, lpFee, params.zeroForOne);
        swapDelta = _applyBinSwap(activeBin, params.zeroForOne, amountIn, amountInAfterFee, amountOut, true);
    }

    function _swapExactOut(
        Bin storage activeBin,
        IPoolManager.SwapParams memory params,
        uint24 fee,
        uint24 protocolFee,
        uint256 priceX128
    ) internal returns (BalanceDelta swapDelta, uint256 protocolFeeAmount) {
        uint256 amountOut = uint256(-params.amountSpecified);
        if (params.zeroForOne) {
            if (activeBin.reserve1 < amountOut) revert PoolErrors.InsufficientLiquidity();
        } else if (activeBin.reserve0 < amountOut) {
            revert PoolErrors.InsufficientLiquidity();
        }

        uint256 amountInAfterFee = params.zeroForOne
            ? (amountOut << BinMathLib.SCALE_OFFSET) / priceX128
            : (amountOut * priceX128) >> BinMathLib.SCALE_OFFSET;
        if (amountInAfterFee == 0 && amountOut > 0) amountInAfterFee = 1;

        uint256 amountIn = FullMathLib.mulDivRoundingUp(amountInAfterFee, 1e6, 1e6 - fee);
        uint256 feeAmount = amountIn - amountInAfterFee;
        uint256 lpFee;
        (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(feeAmount, protocolFee);
        _accrueBinFee(activeBin, lpFee, params.zeroForOne);
        swapDelta = _applyBinSwap(activeBin, params.zeroForOne, amountIn, amountInAfterFee, amountOut, false);
    }

    function _applyBinSwap(
        Bin storage activeBin,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountInAfterFee,
        uint256 amountOut,
        bool checkLiquidity
    ) internal returns (BalanceDelta) {
        if (zeroForOne) {
            if (checkLiquidity && activeBin.reserve1 < amountOut) revert PoolErrors.InsufficientLiquidity();
            activeBin.reserve0 += uint128(amountInAfterFee);
            activeBin.reserve1 -= uint128(amountOut);
            return toBalanceDelta(SafeCastLib.toInt128(int256(amountIn)), -SafeCastLib.toInt128(int256(amountOut)));
        }
        if (checkLiquidity && activeBin.reserve0 < amountOut) revert PoolErrors.InsufficientLiquidity();
        activeBin.reserve1 += uint128(amountInAfterFee);
        activeBin.reserve0 -= uint128(amountOut);
        return toBalanceDelta(-SafeCastLib.toInt128(int256(amountOut)), SafeCastLib.toInt128(int256(amountIn)));
    }

    function _accrueBinFee(Bin storage activeBin, uint256 lpFee, bool zeroForOne) internal {
        if (lpFee > 0 && activeBin.totalLiquidity > 0) {
            uint256 delta = FullMathLib.mulDiv(lpFee, Q128, activeBin.totalLiquidity);
            if (zeroForOne) {
                activeBin.feeGrowth0X128 += delta;
            } else {
                activeBin.feeGrowth1X128 += delta;
            }
        }
    }

    function _enforcePriceLimit(uint256 priceX128, uint160 sqrtPriceLimitX96, bool zeroForOne) internal pure {
        if (sqrtPriceLimitX96 == 0) return;
        uint256 limitPriceX128 = BinMathLib.getPriceX128FromSqrtPriceX96(sqrtPriceLimitX96);
        if (zeroForOne) {
            if (limitPriceX128 >= priceX128) {
                revert PoolErrors.PriceLimitAlreadyExceeded(uint160(priceX128 >> 32), sqrtPriceLimitX96);
            }
        } else if (limitPriceX128 <= priceX128) {
            revert PoolErrors.PriceLimitAlreadyExceeded(uint160(priceX128 >> 32), sqrtPriceLimitX96);
        }
    }

    /// @inheritdoc ICurveEngine
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external override onlyPoolManager {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (amount0 == 0 && amount1 == 0) return;
        Bin storage activeBin = pool.bins[pool.activeBinId];
        uint128 liquidity = activeBin.totalLiquidity;
        if (liquidity == 0) revert PoolErrors.NoLiquidityToDonate();
        if (amount0 > 0) {
            activeBin.feeGrowth0X128 += FullMathLib.mulDiv(amount0, Q128, liquidity);
        }
        if (amount1 > 0) {
            activeBin.feeGrowth1X128 += FullMathLib.mulDiv(amount1, Q128, liquidity);
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
