// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title BalanceDelta
 * @notice User-defined value type packing two int128 token deltas (amount0, amount1) into a single int256.
 */
type BalanceDelta is int256;

using {
    BalanceDeltaLibrary.amount0,
    BalanceDeltaLibrary.amount1,
    BalanceDeltaLibrary.add,
    BalanceDeltaLibrary.sub,
    BalanceDeltaLibrary.eq,
    BalanceDeltaLibrary.neq
} for BalanceDelta global;

/**
 * @notice Helper to pack amount0 and amount1 into a BalanceDelta.
 */
function toBalanceDelta(int128 _amount0, int128 _amount1) pure returns (BalanceDelta) {
    return BalanceDeltaLibrary.pack(_amount0, _amount1);
}

/**
 * @notice Library for operations on BalanceDelta value type.
 */
library BalanceDeltaLibrary {
    BalanceDelta public constant ZERO_DELTA = BalanceDelta.wrap(0);

    /**
     * @notice Packs amount0 and amount1 into a single BalanceDelta.
     */
    function pack(int128 _amount0, int128 _amount1) internal pure returns (BalanceDelta) {
        int256 packed;
        assembly {
            packed := or(shl(128, _amount0), and(0xffffffffffffffffffffffffffffffff, _amount1))
        }
        return BalanceDelta.wrap(packed);
    }

    /**
     * @notice Extracts amount0 from the packed BalanceDelta.
     */
    function amount0(BalanceDelta delta) internal pure returns (int128 _amount0) {
        assembly {
            _amount0 := sar(128, delta)
        }
    }

    /**
     * @notice Extracts amount1 from the packed BalanceDelta.
     */
    function amount1(BalanceDelta delta) internal pure returns (int128 _amount1) {
        assembly {
            _amount1 := signextend(15, delta)
        }
    }

    /**
     * @notice Adds two BalanceDeltas.
     */
    function add(BalanceDelta a, BalanceDelta b) internal pure returns (BalanceDelta) {
        int128 a0 = a.amount0();
        int128 a1 = a.amount1();
        int128 b0 = b.amount0();
        int128 b1 = b.amount1();
        return pack(a0 + b0, a1 + b1);
    }

    /**
     * @notice Subtracts BalanceDelta b from a.
     */
    function sub(BalanceDelta a, BalanceDelta b) internal pure returns (BalanceDelta) {
        int128 a0 = a.amount0();
        int128 a1 = a.amount1();
        int128 b0 = b.amount0();
        int128 b1 = b.amount1();
        return pack(a0 - b0, a1 - b1);
    }

    /**
     * @notice Checks equality of two BalanceDeltas.
     */
    function eq(BalanceDelta a, BalanceDelta b) internal pure returns (bool) {
        return BalanceDelta.unwrap(a) == BalanceDelta.unwrap(b);
    }

    /**
     * @notice Checks inequality of two BalanceDeltas.
     */
    function neq(BalanceDelta a, BalanceDelta b) internal pure returns (bool) {
        return BalanceDelta.unwrap(a) != BalanceDelta.unwrap(b);
    }
}
