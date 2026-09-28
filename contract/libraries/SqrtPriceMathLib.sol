// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMathLib} from "./FullMathLib.sol";
import {SafeCastLib} from "./SafeCastLib.sol";

/**
 * @title SqrtPriceMathLib
 * @notice Computes token amounts for liquidity transitions across price ranges.
 */
library SqrtPriceMathLib {
    using SafeCastLib for uint256;

    /**
     * @notice Calculates amount0 delta for given liquidity and price range.
     */
    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 numerator1 = uint256(liquidity) << 96;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        require(sqrtRatioAX96 > 0);

        return roundUp
            ? FullMathLib.mulDivRoundingUp(
                FullMathLib.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96), 1, sqrtRatioAX96
            )
            : FullMathLib.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /**
     * @notice Calculates amount1 delta for given liquidity and price range.
     */
    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return roundUp
            ? FullMathLib.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96)
            : FullMathLib.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
    }

    /**
     * @notice Calculates signed amount0 delta.
     */
    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity)
        internal
        pure
        returns (int256 amount0)
    {
        return liquidity < 0
            ? -int256(getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false))
            : int256(getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true));
    }

    /**
     * @notice Calculates signed amount1 delta.
     */
    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity)
        internal
        pure
        returns (int256 amount1)
    {
        return liquidity < 0
            ? -int256(getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false))
            : int256(getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true));
    }

    /**
     * @notice Computes the next sqrt price given input token0.
     */
    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << 96;

        if (add) {
            uint256 product = amount * sqrtPX96;
            if (product / amount == sqrtPX96) {
                uint256 denominator = numerator1 + product;
                if (denominator >= numerator1) {
                    return uint160(FullMathLib.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
                }
            }
            return uint160(FullMathLib.mulDivRoundingUp(numerator1, 1, (numerator1 / sqrtPX96) + amount));
        } else {
            uint256 product = amount * sqrtPX96;
            require(product / amount == sqrtPX96 && numerator1 > product);
            uint256 denominator = numerator1 - product;
            return uint160(FullMathLib.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
        }
    }

    /**
     * @notice Computes the next sqrt price given input token1.
     */
    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (add) {
            uint256 quotient = (amount << 96) / liquidity;
            return uint160(uint256(sqrtPX96) + quotient);
        } else {
            uint256 quotient = FullMathLib.mulDivRoundingUp(amount, 1 << 96, liquidity);
            require(sqrtPX96 > quotient);
            return uint160(uint256(sqrtPX96) - quotient);
        }
    }

    /**
     * @notice Computes next sqrt price given an input amount.
     */
    function getNextSqrtPriceFromInput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint160) {
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    /**
     * @notice Computes next sqrt price given an output amount.
     */
    function getNextSqrtPriceFromOutput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint160) {
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }
}
