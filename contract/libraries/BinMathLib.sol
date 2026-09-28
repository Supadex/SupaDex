// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMathLib} from "./FullMathLib.sol";

/**
 * @title BinMathLib
 * @notice Computes price and swap execution for discretized zero-slippage liquidity bins.
 */
library BinMathLib {
    uint256 internal constant SCALE_OFFSET = 128;
    uint256 internal constant SCALE = 1 << SCALE_OFFSET;
    uint24 internal constant CENTER_BIN_ID = 8388608;

    /**
     * @notice Returns the price of a bin at id `binId` with basis points step `binStep`.
     * @dev Price = (1 + binStep / 10000) ^ (binId - 8388608).
     */
    function getPriceFromId(uint24 binId, uint16 binStep) internal pure returns (uint256 price) {
        int256 shift = int256(uint256(binId)) - 8388608;
        if (shift == 0) return SCALE;

        // Linear Taylor approximation for small binStep per bin
        uint256 base = SCALE + (uint256(binStep) * SCALE) / 10000;
        if (shift > 0) {
            price = SCALE;
            for (int256 i = 0; i < shift; i++) {
                price = (price * base) >> SCALE_OFFSET;
            }
        } else {
            price = SCALE;
            for (int256 i = 0; i < -shift; i++) {
                price = (price << SCALE_OFFSET) / base;
            }
        }
    }

    /**
     * @notice Computes output amount for a swap entirely within a single zero-slippage bin.
     */
    function getSwapAmountInBin(uint256 amountIn, uint256 binPrice, bool zeroForOne)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (zeroForOne) {
            // Selling token0 for token1 -> amountOut = amountIn * binPrice
            amountOut = (amountIn * binPrice) >> SCALE_OFFSET;
        } else {
            // Selling token1 for token0 -> amountOut = amountIn / binPrice
            amountOut = (amountIn << SCALE_OFFSET) / binPrice;
        }
    }

    /**
     * @notice Computes output amount for a swap within a bin given binId and binStep.
     */
    function computeSwapAmountInBin(uint256 amountIn, uint24 binId, uint16 binStep, bool zeroForOne)
        internal
        pure
        returns (uint256 amountOut)
    {
        uint256 price = getPriceFromId(binId, binStep);
        return getSwapAmountInBin(amountIn, price, zeroForOne);
    }
}
