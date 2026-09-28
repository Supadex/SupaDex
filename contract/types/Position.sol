// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Position
 * @notice Struct holding state for an individual liquidity position.
 */
library Position {
    /**
     * @notice Struct representing an active position within a tick range.
     */
    struct Info {
        /**
         * @dev Amount of liquidity in the position.
         */
        uint128 liquidity;
        /**
         * @dev Fee growth per unit of liquidity on token0 as of last update.
         */
        uint256 feeGrowthInside0LastX128;
        /**
         * @dev Fee growth per unit of liquidity on token1 as of last update.
         */
        uint256 feeGrowthInside1LastX128;
        /**
         * @dev Block number when liquidity was added/modified (Anti-JIT protection).
         */
        uint64 lastModifiedBlock;
    }

    /**
     * @notice Computes unique key for a position mapping.
     */
    function getKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }
}
