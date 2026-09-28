// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICurveEngine} from "../../interfaces/ICurveEngine.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId} from "../../types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "../../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../types/Slot0.sol";
import {PoolErrors} from "../../errors/PoolErrors.sol";
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";

/**
 * @title StableAMMEngine
 * @notice High-efficiency AMM engine for pegged and correlated assets implementing the Stableswap amplified invariant.
 */
contract StableAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;

    uint256 internal constant DEFAULT_A = 100;
    uint256 internal constant MAX_LOOP_LIMIT = 255;

    struct StablePoolState {
        Slot0 slot0;
        uint256 reserve0;
        uint256 reserve1;
        uint256 amplificationParameter;
    }

    mapping(PoolId => StablePoolState) internal pools;

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

        pools[id].amplificationParameter = DEFAULT_A;
        pools[id].slot0 = Slot0Library.pack(sqrtPriceX96, 0, 0, key.fee, true);
        tick = 0;
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
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized())
            revert PoolErrors.PoolNotInitialized(id);

        uint256 amount = uint256(
            params.liquidityDelta > 0
                ? params.liquidityDelta
                : -params.liquidityDelta
        );

        if (params.liquidityDelta > 0) {
            pool.reserve0 += amount;
            pool.reserve1 += amount;
            callerDelta = toBalanceDelta(
                SafeCastLib.toInt128(int256(amount)),
                SafeCastLib.toInt128(int256(amount))
            );
        } else {
            if (pool.reserve0 < amount || pool.reserve1 < amount)
                revert PoolErrors.LiquidityOverflow();
            pool.reserve0 -= amount;
            pool.reserve1 -= amount;
            callerDelta = toBalanceDelta(
                -SafeCastLib.toInt128(int256(amount)),
                -SafeCastLib.toInt128(int256(amount))
            );
        }

        feesAccrued = toBalanceDelta(0, 0);
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
        StablePoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized())
            revert PoolErrors.PoolNotInitialized(id);
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();

        uint256 x = pool.reserve0;
        uint256 y = pool.reserve1;
        uint256 A = pool.amplificationParameter;

        uint256 amountIn = uint256(
            params.amountSpecified > 0
                ? params.amountSpecified
                : -params.amountSpecified
        );
        uint256 feeAmount = FullMathLib.mulDivRoundingUp(amountIn, fee, 1e6);
        uint256 amountInAfterFee = amountIn > feeAmount
            ? amountIn - feeAmount
            : 0;

        uint256 amountOut;

        if (params.zeroForOne) {
            uint256 newX = x + amountInAfterFee;
            uint256 newY = computeY(newX, x, y, A);
            amountOut = y > newY ? y - newY : 0;

            pool.reserve0 = newX;
            pool.reserve1 = newY;
            swapDelta = toBalanceDelta(
                SafeCastLib.toInt128(int256(amountIn)),
                -SafeCastLib.toInt128(int256(amountOut))
            );
        } else {
            uint256 newY = y + amountInAfterFee;
            uint256 newX = computeY(newY, y, x, A);
            amountOut = x > newX ? x - newX : 0;

            pool.reserve0 = newX;
            pool.reserve1 = newY;
            swapDelta = toBalanceDelta(
                -SafeCastLib.toInt128(int256(amountOut)),
                SafeCastLib.toInt128(int256(amountIn))
            );
        }
    }

    /**
     * @notice Computes invariant D for 2 balances given amplification parameter A.
     */
    function computeD(
        uint256 x,
        uint256 y,
        uint256 A
    ) public pure returns (uint256 D) {
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
            // D = (Ann * S + 2 * D_P) * D / ((Ann - 1) * D + 3 * D_P)
            uint256 numerator = D * ((Ann * S) / 4 + D_P * 2);
            uint256 denominator = ((Ann - 1) * D) / 4 + D_P * 3;
            D = numerator / denominator;
            if (D > prevD ? D - prevD <= 1 : prevD - D <= 1) {
                return D;
            }
        }
    }

    /**
     * @notice Computes output balance y given new balance x, initial balances, and A.
     * @param newX Balance of token x after swap.
     * @param x Balance of token x before swap.
     * @param y Balance of token x before swap.
     * @param A Amplification parameter.
     */
    function computeY(
        uint256 newX,
        uint256 x,
        uint256 y,
        uint256 A
    ) public pure returns (uint256 Y) {
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
        StablePoolState storage pool = pools[id];
        return uint128((pool.reserve0 + pool.reserve1) / 2);
    }

    /**
     * @notice Returns pool reserves.
     */
    function getReserves(
        PoolId id
    ) external view returns (uint256 reserve0, uint256 reserve1) {
        StablePoolState storage pool = pools[id];
        return (pool.reserve0, pool.reserve1);
    }
}
