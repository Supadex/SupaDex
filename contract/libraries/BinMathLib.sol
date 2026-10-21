// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
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

    /// @notice Bin step bounds in basis points (PoolKey.tickSpacing carries the bin step for BIN_AMM pools).
    uint16 internal constant MIN_BIN_STEP = 1;
    uint16 internal constant MAX_BIN_STEP = 200;
    /// @dev 1e4 * ln(2^128) ~= 887_228: bins whose |id| * ln(1 + s) exceeds ln(2^128) are rejected up front.
    uint256 internal constant LN_PRICE_BOUND_E4 = 887_228;
    /// @notice |id| * binStep (in bps) bound: e^(880000 / 1e4) = e^88 < 2^127.
    uint256 internal constant MAX_ID_STEP_PRODUCT = 880_000;

    /**
     * @notice Returns the price of a bin at id `binId` (offset by CENTER_BIN_ID) with bin step `binStep` (bps).
     * @dev Price = (1 + binStep / 10000) ^ (binId - CENTER_BIN_ID), Q128. O(log |shift|) (Issue 1: replaces the
     * previous O(|shift|) loop).
     */
    function getPriceFromId(uint24 binId, uint16 binStep) internal pure returns (uint256 price) {
        return getPriceFromSignedId(int24(int256(uint256(binId)) - int256(uint256(CENTER_BIN_ID))), binStep);
    }

    /**
     * @notice Q128 price of signed bin `id`: (1 + binStep/1e4)^id, by binary exponentiation.
     * @dev Reverts `BinIdOutOfBounds`-style (via require-free bound) when |id| * ln(1 + s) is certainly above
     * ln(2^128): checked with ln(1+u) >= u / (1+u). Within the bound no intermediate overflows 2^256.
     */
    function getPriceFromSignedId(int24 id, uint16 binStep) internal pure returns (uint256 price) {
        if (!isIdWithinBound(id, binStep)) revert BinIdBeyondPriceRange(id, binStep);
        uint256 n = id < 0 ? uint256(-int256(id)) : uint256(int256(id));
        uint256 b = SCALE + (uint256(binStep) * SCALE) / 10_000;
        price = SCALE;
        while (n > 0) {
            if (n & 1 == 1) price = FullMathLib.mulDiv(price, b, SCALE);
            n >>= 1;
            if (n > 0) b = FullMathLib.mulDiv(b, b, SCALE);
        }
        if (id < 0) price = FullMathLib.mulDiv(SCALE, SCALE, price);
    }

    error BinIdBeyondPriceRange(int24 id, uint16 binStep);

    /// @notice Overflow-safe id range: |id| * binStep <= MAX_ID_STEP_PRODUCT.
    /// @dev (1 + s)^n <= e^(n s) <= e^88 < 2^127.0, so every Q128 intermediate and result is < 2^255.
    function isIdWithinBound(int24 id, uint16 binStep) internal pure returns (bool) {
        uint256 n = id < 0 ? uint256(-int256(id)) : uint256(int256(id));
        return n * uint256(binStep) <= MAX_ID_STEP_PRODUCT;
    }

    /// @notice Q128 price -> sqrtPriceX96 (sqrt(price) * 2^96); returns 0 if out of uint160 range.
    function priceX128ToSqrtPriceX96(uint256 priceX128) internal pure returns (uint256 r) {
        if (priceX128 < (uint256(1) << 192)) {
            r = _sqrt(priceX128 << 64);
        } else {
            r = _sqrt(priceX128) << 32;
        }
    }

    function _sqrt(uint256 x) private pure returns (uint256) {
        return FixedPointMathLib.sqrt(x);
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
