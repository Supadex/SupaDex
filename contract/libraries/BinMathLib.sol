// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMathLib} from "./FullMathLib.sol";

/**
 * @title BinMathLib
 * @notice Computes price and swap execution for discretized zero-slippage liquidity bins.
 * @dev Bin price is in raw token1/token0 units (atomic), scaled by 2^128.
 *      Price = (1 + binStep / 10000) ^ (binId - CENTER_BIN_ID).
 */
library BinMathLib {
    uint256 internal constant SCALE_OFFSET = 128;
    uint256 internal constant SCALE = 1 << SCALE_OFFSET;
    uint24 internal constant CENTER_BIN_ID = 8388608;

    /**
     * @notice Returns the price of a bin at id `binId` with basis points step `binStep`.
     * @dev Price = (1 + binStep / 10000) ^ (binId - 8388608), in Q128.
     */
    function getPriceFromId(uint24 binId, uint16 binStep) internal pure returns (uint256 price) {
        int256 shift = int256(uint256(binId)) - 8388608;
        if (shift == 0) return SCALE;

        uint256 base = SCALE + (uint256(binStep) * SCALE) / 10000;
        price = SCALE;
        if (shift > 0) {
            for (int256 i = 0; i < shift; i++) {
                price = FullMathLib.mulDiv(price, base, SCALE);
            }
        } else {
            for (int256 i = 0; i < -shift; i++) {
                price = FullMathLib.mulDiv(price, SCALE, base);
            }
        }
    }

    /**
     * @notice Converts Q64.96 sqrtPriceX96 into Q128 raw price (token1/token0 atomic).
     * @dev rawPrice = (sqrtPriceX96 / 2^96)^2 → priceX128 = sqrtPriceX96^2 / 2^64
     */
    function getPriceX128FromSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256 priceX128) {
        if (sqrtPriceX96 == 0) return 0;
        return FullMathLib.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 64);
    }

    /**
     * @notice Fast approximate bin id from Q128 price using log2 (O(1)).
     * @dev Pricing uses cached activePriceX128; this id is for indexing/display only.
     */
    function approxIdFromPrice(uint256 priceX128, uint16 binStep) internal pure returns (uint24) {
        if (priceX128 == 0 || binStep == 0 || priceX128 == SCALE) return CENTER_BIN_ID;

        // ln(x) ≈ log2(x) * ln(2); ln(1+s) ≈ s for small s=binStep/10000
        // shift ≈ log2(price/SCALE) * ln(2) / (binStep/10000)
        //       ≈ log2(price/SCALE) * 693147 / binStep   (ln2*1e6 ≈ 693147, s*1e6 = binStep*100)
        // wait: / (binStep/10000) = * 10000 / binStep
        // shift ≈ log2(ratio) * 0.693147 * 10000 / binStep
        //       ≈ log2(ratio) * 6931.47 / binStep

        int256 log2Ratio;
        if (priceX128 > SCALE) {
            log2Ratio = int256(log2(priceX128)) - 128; // log2(SCALE)=128
        } else {
            log2Ratio = int256(log2(priceX128)) - 128;
        }

        // shift = log2Ratio * 693147 / 1000 / binStep   (using 693.147 ≈ ln2*1000)
        // more precisely: log2Ratio * ln(2) * 10000 / binStep
        // use 693147/1e6 for ln2 → shift = log2Ratio * 693147 * 10000 / (1e6 * binStep)
        //                    = log2Ratio * 693147 / (100 * binStep)
        int256 shift = (log2Ratio * 693147) / (int256(uint256(binStep)) * 100);
        int256 id = int256(uint256(CENTER_BIN_ID)) + shift;
        if (id < 0) id = 0;
        if (id > int256(uint256(type(uint24).max))) id = int256(uint256(type(uint24).max));
        return uint24(uint256(id));
    }

    /// @dev Floor(log2(x)) for x > 0.
    function log2(uint256 x) internal pure returns (uint256 r) {
        unchecked {
            if (x >= 0x100000000000000000000000000000000) {
                x >>= 128;
                r += 128;
            }
            if (x >= 0x10000000000000000) {
                x >>= 64;
                r += 64;
            }
            if (x >= 0x100000000) {
                x >>= 32;
                r += 32;
            }
            if (x >= 0x10000) {
                x >>= 16;
                r += 16;
            }
            if (x >= 0x100) {
                x >>= 8;
                r += 8;
            }
            if (x >= 0x10) {
                x >>= 4;
                r += 4;
            }
            if (x >= 0x4) {
                x >>= 2;
                r += 2;
            }
            if (x >= 0x2) r += 1;
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
        if (binPrice == 0) return 0;
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
