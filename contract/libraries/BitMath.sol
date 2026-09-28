// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LibBit} from "solady/utils/LibBit.sol";

/**
 * @title BitMath
 * @notice Assembly-optimized bit manipulation library leveraging Solady's LibBit.
 */
library BitMath {
    /**
     * @notice Returns the index of the most significant bit of the number (0-255).
     */
    function mostSignificantBit(uint256 x) internal pure returns (uint8) {
        require(x > 0);
        return uint8(LibBit.fls(x));
    }

    /**
     * @notice Returns the index of the least significant bit of the number (0-255).
     */
    function leastSignificantBit(uint256 x) internal pure returns (uint8) {
        require(x > 0);
        return uint8(LibBit.ffs(x));
    }
}
