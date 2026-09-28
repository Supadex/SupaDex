// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PoolId
 * @notice User-defined value type representing the unique keccak256 hash identifier of a pool.
 */
type PoolId is bytes32;

using {PoolIdLibrary.toIdBytes, PoolIdLibrary.equals} for PoolId global;

library PoolIdLibrary {
    /**
     * @notice Unwraps PoolId to bytes32.
     */
    function toIdBytes(PoolId id) internal pure returns (bytes32) {
        return PoolId.unwrap(id);
    }

    /**
     * @notice Equality check between two PoolIds.
     */
    function equals(PoolId a, PoolId b) internal pure returns (bool) {
        return PoolId.unwrap(a) == PoolId.unwrap(b);
    }
}
