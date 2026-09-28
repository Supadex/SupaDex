// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../../types/Currency.sol";
import {PoolKey, CurveType} from "../../types/PoolKey.sol";
import {PeripheryErrors} from "../../errors/PeripheryErrors.sol";

/**
 * @title PathKeyLib
 * @notice Functions for encoding and decoding multi-hop swap paths for SupaDex.
 * Path layout: currencyIn (20 bytes) || fee (3 bytes) || tickSpacing (3 bytes) || plugin (20 bytes) || curveType (1 byte) || currencyOut (20 bytes)
 */
library PathKeyLib {
    /**
     * @dev Length of a single hop's parameters excluding the trailing currency (20 + 3 + 3 + 20 + 1 = 47 bytes).
     */
    uint256 private constant NEXT_HOP_OFFSET = 47;
    /**
     * @dev Full length of a single-hop path (20 + 3 + 3 + 20 + 1 + 20 = 67 bytes).
     */
    uint256 private constant FIRST_HOP_LENGTH = 67;

    /**
     * @notice Returns true if the path contains more than one pool.
     */
    function hasMultiplePools(bytes memory path) internal pure returns (bool) {
        return path.length >= FIRST_HOP_LENGTH + NEXT_HOP_OFFSET;
    }

    /**
     * @notice Returns total number of pool hops in the encoded path.
     */
    function numPools(bytes memory path) internal pure returns (uint256) {
        if (path.length < FIRST_HOP_LENGTH) return 0;
        return ((path.length - FIRST_HOP_LENGTH) / NEXT_HOP_OFFSET) + 1;
    }

    /**
     * @notice Decodes the first hop parameters from a path.
     */
    function decodeFirstPool(bytes memory path)
        internal
        pure
        returns (
            Currency currencyIn,
            Currency currencyOut,
            uint24 fee,
            int24 tickSpacing,
            address plugin,
            CurveType curveType
        )
    {
        if (path.length < FIRST_HOP_LENGTH) revert PeripheryErrors.InvalidPath();

        assembly {
            // path points to length (32 bytes), data starts at path + 32
            let dataPtr := add(path, 32)
            currencyIn := shr(96, mload(dataPtr))
            fee := shr(232, mload(add(dataPtr, 20)))
            tickSpacing := signextend(2, shr(232, mload(add(dataPtr, 23))))
            plugin := shr(96, mload(add(dataPtr, 26)))
            curveType := shr(248, mload(add(dataPtr, 46)))
            currencyOut := shr(96, mload(add(dataPtr, 47)))
        }
    }

    /**
     * @notice Constructs the canonical PoolKey, input currency, output currency, and zeroForOne flag.
     */
    function getFirstPoolKey(bytes memory path)
        internal
        pure
        returns (PoolKey memory poolKey, Currency currencyIn, Currency currencyOut, bool zeroForOne)
    {
        uint24 fee;
        int24 tickSpacing;
        address plugin;
        CurveType curveType;
        (currencyIn, currencyOut, fee, tickSpacing, plugin, curveType) = decodeFirstPool(path);

        if (Currency.unwrap(currencyIn) == Currency.unwrap(currencyOut)) {
            revert PeripheryErrors.IdenticalCurrencies();
        }

        zeroForOne = Currency.unwrap(currencyIn) < Currency.unwrap(currencyOut);
        Currency currency0 = zeroForOne ? currencyIn : currencyOut;
        Currency currency1 = zeroForOne ? currencyOut : currencyIn;

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            plugin: plugin,
            curveType: curveType
        });
    }

    /**
     * @notice Skips the first pool hop and returns the remaining path bytes.
     */
    function skipToken(bytes memory path) internal pure returns (bytes memory remainingPath) {
        if (path.length < FIRST_HOP_LENGTH) revert PeripheryErrors.InvalidPath();
        uint256 remainingLength = path.length - NEXT_HOP_OFFSET;
        remainingPath = new bytes(remainingLength);

        assembly {
            let src := add(add(path, 32), NEXT_HOP_OFFSET)
            let dst := add(remainingPath, 32)
            for { let i := 0 } lt(i, remainingLength) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
    }

    /**
     * @notice Encodes a single hop into a byte slice.
     */
    function encodeHop(
        Currency currencyIn,
        Currency currencyOut,
        uint24 fee,
        int24 tickSpacing,
        address plugin,
        CurveType curveType
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(currencyIn, fee, tickSpacing, plugin, uint8(curveType), currencyOut);
    }
}
