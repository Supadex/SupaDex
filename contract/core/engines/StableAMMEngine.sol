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
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";
import {ProtocolFeeLib} from "../../libraries/ProtocolFeeLib.sol";

/**
 * @title StableAMMEngine
 * @notice Stableswap AMM with global fee growth accrual to LP positions.
 */
contract StableAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;

    uint256 internal constant DEFAULT_A = 100;
    uint256 internal constant MAX_LOOP_LIMIT = 255;
    uint256 internal constant Q128 = 1 << 128;

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

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external override returns (int24 tick) {
        PoolId id = key.toId();
        if (pools[id].slot0.isInitialized()) {
            revert PoolErrors.PoolAlreadyInitialized(id);
        }

        pools[id].amplificationParameter = DEFAULT_A;
        pools[id].slot0 = Slot0Library.pack(sqrtPriceX96, 0, 0, key.fee, true);
        tick = 0;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        override
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) {
            revert PoolErrors.PoolNotInitialized(id);
        }

        bytes32 posKey = keccak256(abi.encodePacked(params.tickLower, params.tickUpper, params.salt));
        Position.Info storage position = pool.positions[posKey];

        uint128 positionLiquidity = position.liquidity;
        uint256 fees0;
        uint256 fees1;
        if (positionLiquidity > 0) {
            fees0 = FullMathLib.mulDiv(
                positionLiquidity, pool.feeGrowthGlobal0X128 - position.feeGrowthInside0LastX128, Q128
            );
            fees1 = FullMathLib.mulDiv(
                positionLiquidity, pool.feeGrowthGlobal1X128 - position.feeGrowthInside1LastX128, Q128
            );
        }

        uint256 amount0 = uint256(params.liquidityDelta > 0 ? params.liquidityDelta : -params.liquidityDelta);

        uint160 sqrtP = pool.slot0.sqrtPriceX96();
        uint256 amount1 = amount0;
        if (sqrtP > 0) {
            uint256 num = FullMathLib.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
            amount1 = FullMathLib.mulDiv(amount0, num, 1 << 96);
            if (amount0 > 0 && amount1 == 0) amount1 = 1;
        }

        if (params.liquidityDelta > 0) {
            pool.reserve0 += amount0;
            pool.reserve1 += amount1;
            pool.totalLiquidity += uint128(amount0);
            position.liquidity = positionLiquidity + uint128(amount0);
            callerDelta = toBalanceDelta(SafeCastLib.toInt128(int256(amount0)), SafeCastLib.toInt128(int256(amount1)));
        } else if (params.liquidityDelta < 0) {
            if (pool.reserve0 < amount0 || pool.reserve1 < amount1 || positionLiquidity < amount0) {
                revert PoolErrors.LiquidityOverflow();
            }
            pool.reserve0 -= amount0;
            pool.reserve1 -= amount1;
            pool.totalLiquidity -= uint128(amount0);
            position.liquidity = positionLiquidity - uint128(amount0);
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
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount)
    {
        PoolId id = key.toId();
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) {
            revert PoolErrors.PoolNotInitialized(id);
        }
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();

        uint256 x = pool.reserve0;
        uint256 y = pool.reserve1;
        uint256 A = pool.amplificationParameter;

        uint256 amountIn = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);
        uint256 feeAmount = FullMathLib.mulDivRoundingUp(amountIn, fee, 1e6);
        uint256 amountInAfterFee = amountIn > feeAmount ? amountIn - feeAmount : 0;

        uint256 lpFee;
        (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(feeAmount, protocolFee);

        if (lpFee > 0 && pool.totalLiquidity > 0) {
            uint256 delta = FullMathLib.mulDiv(lpFee, Q128, pool.totalLiquidity);
            if (params.zeroForOne) {
                pool.feeGrowthGlobal0X128 += delta;
            } else {
                pool.feeGrowthGlobal1X128 += delta;
            }
        }

        uint256 amountOut;

        if (params.zeroForOne) {
            uint256 newX = x + amountInAfterFee;
            uint256 newY = computeY(newX, x, y, A);
            amountOut = y > newY ? y - newY : 0;

            pool.reserve0 = newX;
            pool.reserve1 = newY;
            swapDelta = toBalanceDelta(SafeCastLib.toInt128(int256(amountIn)), -SafeCastLib.toInt128(int256(amountOut)));
        } else {
            uint256 newY = y + amountInAfterFee;
            uint256 newX = computeY(newY, y, x, A);
            amountOut = x > newX ? x - newX : 0;

            pool.reserve0 = newX;
            pool.reserve1 = newY;
            swapDelta = toBalanceDelta(-SafeCastLib.toInt128(int256(amountOut)), SafeCastLib.toInt128(int256(amountIn)));
        }
    }

    function computeD(uint256 x, uint256 y, uint256 A) public pure returns (uint256 D) {
        uint256 S = x + y;
        if (S == 0) return 0;

        uint256 prevD;
        D = S;
        uint256 Ann = A * 4;

        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 D_P = D;
            D_P = (D_P * D) / (x * 2);
            D_P = (D_P * D) / (y * 2);
            prevD = D;
            uint256 numerator = D * ((Ann * S) / 4 + D_P * 2);
            uint256 denominator = ((Ann - 1) * D) / 4 + D_P * 3;
            D = numerator / denominator;
            if (D > prevD ? D - prevD <= 1 : prevD - D <= 1) {
                return D;
            }
        }
    }

    function computeY(uint256 newX, uint256 x, uint256 y, uint256 A) public pure returns (uint256 Y) {
        uint256 D = computeD(x, y, A);
        uint256 Ann = A * 4;
        uint256 c = (D * D) / (newX * 2);
        c = (c * D) / (Ann * 2);
        uint256 b = newX + (D / Ann);

        uint256 prevY;
        Y = D;
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            prevY = Y;
            Y = (Y * Y + c) / (2 * Y + b - D);
            if (Y > prevY ? Y - prevY <= 1 : prevY - Y <= 1) {
                return Y;
            }
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
