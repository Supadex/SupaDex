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
import {TickMathLib} from "../../libraries/TickMathLib.sol";

/**
 * @title StableAMMEngine
 * @notice Stableswap AMM with global fee growth accrual to LP positions.
 */
contract StableAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;

    uint256 internal constant DEFAULT_A = 100;
    uint256 internal constant MAX_LOOP_LIMIT = 255;
    uint256 internal constant Q128 = 1 << 128;
    uint24 internal constant MAX_FEE_PIPS = 1_000_000;

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

        pools[id].amplificationParameter = DEFAULT_A;
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
            uint256 amount0 = uint256(params.liquidityDelta);
            uint160 sqrtP = pool.slot0.sqrtPriceX96();
            uint256 amount1 = amount0;
            if (sqrtP > 0) {
                uint256 num = FullMathLib.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
                amount1 = FullMathLib.mulDiv(amount0, num, 1 << 96);
                if (amount0 > 0 && amount1 == 0) amount1 = 1;
            }

            pool.reserve0 += amount0;
            pool.reserve1 += amount1;
            pool.totalLiquidity += uint128(amount0);
            position.liquidity = positionLiquidity + uint128(amount0);
            callerDelta = toBalanceDelta(SafeCastLib.toInt128(int256(amount0)), SafeCastLib.toInt128(int256(amount1)));
        } else if (params.liquidityDelta < 0) {
            uint256 shares = uint256(-params.liquidityDelta);
            if (positionLiquidity < shares || pool.totalLiquidity == 0) {
                revert PoolErrors.LiquidityOverflow();
            }
            uint256 amount0 = FullMathLib.mulDiv(shares, pool.reserve0, pool.totalLiquidity);
            uint256 amount1 = FullMathLib.mulDiv(shares, pool.reserve1, pool.totalLiquidity);

            pool.reserve0 -= amount0;
            pool.reserve1 -= amount1;
            pool.totalLiquidity -= uint128(shares);
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

        uint256 x = pool.reserve0;
        uint256 y = pool.reserve1;
        uint256 A = pool.amplificationParameter;

        if (params.sqrtPriceLimitX96 != 0) {
            uint160 current = pool.slot0.sqrtPriceX96();
            if (params.zeroForOne) {
                if (params.sqrtPriceLimitX96 >= current || params.sqrtPriceLimitX96 <= TickMathLib.MIN_SQRT_RATIO) {
                    revert PoolErrors.PriceLimitAlreadyExceeded(current, params.sqrtPriceLimitX96);
                }
            } else if (
                params.sqrtPriceLimitX96 <= current || params.sqrtPriceLimitX96 >= TickMathLib.MAX_SQRT_RATIO
            ) {
                revert PoolErrors.PriceLimitAlreadyExceeded(current, params.sqrtPriceLimitX96);
            }
        }

        bool exactInput = params.amountSpecified > 0;
        uint256 amountIn;
        uint256 amountOut;

        if (exactInput) {
            amountIn = uint256(params.amountSpecified);
            uint256 feeAmount = FullMathLib.mulDivRoundingUp(amountIn, fee, 1e6);
            uint256 amountInAfterFee = amountIn > feeAmount ? amountIn - feeAmount : 0;

            uint256 lpFee;
            (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(feeAmount, protocolFee);
            _accrueStableFee(pool, lpFee, params.zeroForOne);

            if (params.zeroForOne) {
                uint256 newX = x + amountInAfterFee;
                uint256 newY = computeY(newX, x, y, A);
                amountOut = y > newY ? y - newY : 0;
                if (amountOut == 0) revert PoolErrors.InsufficientLiquidity();
                pool.reserve0 = newX;
                pool.reserve1 = newY;
                swapDelta =
                    toBalanceDelta(SafeCastLib.toInt128(int256(amountIn)), -SafeCastLib.toInt128(int256(amountOut)));
            } else {
                uint256 newY = y + amountInAfterFee;
                uint256 newX = computeY(newY, y, x, A);
                amountOut = x > newX ? x - newX : 0;
                if (amountOut == 0) revert PoolErrors.InsufficientLiquidity();
                pool.reserve0 = newX;
                pool.reserve1 = newY;
                swapDelta =
                    toBalanceDelta(-SafeCastLib.toInt128(int256(amountOut)), SafeCastLib.toInt128(int256(amountIn)));
            }
        } else {
            amountOut = uint256(-params.amountSpecified);
            if (params.zeroForOne) {
                if (y < amountOut) revert PoolErrors.InsufficientLiquidity();
                uint256 newY = y - amountOut;
                // Given new Y, solve for X under the same invariant (axes swapped).
                uint256 newX = _computeIndependentForDependent(newY, y, x, A);
                if (newX <= x) revert PoolErrors.InsufficientLiquidity();
                uint256 amountInAfterFee = newX - x;
                amountIn = FullMathLib.mulDivRoundingUp(amountInAfterFee, 1e6, 1e6 - fee);
                uint256 feeAmount = amountIn - amountInAfterFee;

                uint256 lpFee;
                (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(feeAmount, protocolFee);
                _accrueStableFee(pool, lpFee, true);

                pool.reserve0 = x + amountInAfterFee;
                pool.reserve1 = newY;
                swapDelta =
                    toBalanceDelta(SafeCastLib.toInt128(int256(amountIn)), -SafeCastLib.toInt128(int256(amountOut)));
            } else {
                if (x < amountOut) revert PoolErrors.InsufficientLiquidity();
                uint256 newX = x - amountOut;
                uint256 newY = computeY(newX, x, y, A);
                if (newY <= y) revert PoolErrors.InsufficientLiquidity();
                uint256 amountInAfterFee = newY - y;
                amountIn = FullMathLib.mulDivRoundingUp(amountInAfterFee, 1e6, 1e6 - fee);
                uint256 feeAmount = amountIn - amountInAfterFee;

                uint256 lpFee;
                (lpFee, protocolFeeAmount) = ProtocolFeeLib.splitFee(feeAmount, protocolFee);
                _accrueStableFee(pool, lpFee, false);

                pool.reserve0 = newX;
                pool.reserve1 = y + amountInAfterFee;
                swapDelta =
                    toBalanceDelta(-SafeCastLib.toInt128(int256(amountOut)), SafeCastLib.toInt128(int256(amountIn)));
            }
        }

        // Update spot sqrt price from reserves for limit checks on subsequent swaps
        if (pool.reserve0 > 0 && pool.reserve1 > 0) {
            // price1/0 ~= reserve1/reserve0; sqrtPriceX96 ~= sqrt(price) * 2^96
            uint256 ratioX192 = FullMathLib.mulDiv(pool.reserve1, uint256(1) << 192, pool.reserve0);
            uint160 newSqrt = _sqrtPriceX96(ratioX192);
            pool.slot0 = pool.slot0.setSqrtPriceX96(newSqrt);
        }
    }

    function _accrueStableFee(StablePoolState storage pool, uint256 lpFee, bool zeroForOne) internal {
        if (lpFee > 0 && pool.totalLiquidity > 0) {
            uint256 delta = FullMathLib.mulDiv(lpFee, Q128, pool.totalLiquidity);
            if (zeroForOne) {
                pool.feeGrowthGlobal0X128 += delta;
            } else {
                pool.feeGrowthGlobal1X128 += delta;
            }
        }
    }

    /// @dev Given a new dependent reserve, solve for the independent reserve under the same D.
    function _computeIndependentForDependent(uint256 newDep, uint256 oldDep, uint256 oldInd, uint256 A)
        internal
        pure
        returns (uint256)
    {
        // Reuse computeY with swapped coordinates: treat dep as x-like input
        return computeY(newDep, oldDep, oldInd, A);
    }

    /**
     * @dev Integer sqrt of reserve ratio in Q192 space → sqrtPriceX96.
     * Reverts instead of truncating if the result does not fit in uint160.
     */
    function _sqrtPriceX96(uint256 ratioX192) internal pure returns (uint160) {
        if (ratioX192 == 0) revert PoolErrors.PriceLimitOutOfBounds(0);
        uint256 z = (ratioX192 + 1) / 2;
        uint256 y = ratioX192;
        while (z < y) {
            y = z;
            z = (ratioX192 / z + z) / 2;
        }
        if (y > type(uint160).max) revert PoolErrors.PriceLimitOutOfBounds(type(uint160).max);
        uint160 sqrtP = uint160(y);
        if (sqrtP <= TickMathLib.MIN_SQRT_RATIO || sqrtP >= TickMathLib.MAX_SQRT_RATIO) {
            revert PoolErrors.PriceLimitOutOfBounds(sqrtP);
        }
        return sqrtP;
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
