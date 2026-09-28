// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SafeCastLib
 * @notice Assembly-optimized safe casting functions for integer types with zero gas overhead.
 */
library SafeCastLib {
    error SafeCastOverflow();

    /**
     * @notice Casts uint256 to uint128 safely.
     */
    function toUint128(uint256 x) internal pure returns (uint128 y) {
        if (x > type(uint128).max) revert SafeCastOverflow();
        return uint128(x);
    }

    /**
     * @notice Casts uint256 to uint160 safely.
     */
    function toUint160(uint256 x) internal pure returns (uint160 y) {
        if (x > type(uint160).max) revert SafeCastOverflow();
        return uint160(x);
    }

    /**
     * @notice Casts uint256 to int128 safely.
     */
    function toInt128(uint256 x) internal pure returns (int128 y) {
        if (x > uint128(type(int128).max)) revert SafeCastOverflow();
        return int128(uint128(x));
    }

    /**
     * @notice Casts uint256 to int256 safely.
     */
    function toInt256(uint256 x) internal pure returns (int256 y) {
        if (x > uint256(type(int256).max)) revert SafeCastOverflow();
        return int256(x);
    }

    /**
     * @notice Casts int256 to int128 safely.
     */
    function toInt128(int256 x) internal pure returns (int128 y) {
        if (x < type(int128).min || x > type(int128).max) revert SafeCastOverflow();
        return int128(x);
    }

    /**
     * @notice Casts int128 to uint128 safely.
     */
    function toUint128(int128 x) internal pure returns (uint128 y) {
        if (x < 0) revert SafeCastOverflow();
        return uint128(x);
    }

    /**
     * @notice Casts int256 to uint256 safely.
     */
    function toUint256(int256 x) internal pure returns (uint256 y) {
        if (x < 0) revert SafeCastOverflow();
        return uint256(x);
    }
}
