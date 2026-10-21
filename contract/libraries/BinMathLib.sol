// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FullMathLib} from "./FullMathLib.sol";

/**
 * @title BinMathLib
 * @notice Price math for discretised zero-slippage liquidity bins (ADR-0006 multi-bin engine).
 * @dev Bin price is in raw token1/token0 units (atomic), scaled by 2^128: price(id) = (1 + binStep / 10000) ^ id for a
 *      signed id (bin 0 = price 1). remediation-3 removed the unused single-bin-era helpers (unsigned CENTER_BIN_ID
 *      ids, approxIdFromPrice, log2, getSwapAmountInBin, computeSwapAmountInBin). The engine never called them.
 */
library BinMathLib {
    uint256 internal constant SCALE_OFFSET = 128;
    uint256 internal constant SCALE = 1 << SCALE_OFFSET;

    /// @notice Bin step bounds in basis points (PoolKey.tickSpacing carries the bin step for BIN_AMM pools).
    uint16 internal constant MIN_BIN_STEP = 1;
    uint16 internal constant MAX_BIN_STEP = 200;
    /// @dev 1e4 * ln(2^128) ~= 887_228: bins whose |id| * ln(1 + s) exceeds ln(2^128) are rejected up front.
    uint256 internal constant LN_PRICE_BOUND_E4 = 887_228;
    /// @notice |id| * binStep (in bps) bound: e^(880000 / 1e4) = e^88 < 2^127.
    uint256 internal constant MAX_ID_STEP_PRODUCT = 880_000;

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
}
