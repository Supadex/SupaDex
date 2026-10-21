// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BitMath} from "./BitMath.sol";

/**
 * @title TreeBitmapLib
 * @notice Three-level (256-ary) bitmap over the full uint24 key space with O(1) "next set key" search.
 * @dev Remediation-2 Issues 1 and 7. Used by CLAMMEngine (initialized compressed ticks) and BinAMMEngine
 * (bins holding liquidity). Every lookup touches at most 3 + 3 storage words regardless of the distance to the
 * next set key, so traversing an empty range no longer costs one SLOAD per 256 ticks.
 *
 *   level0               : 1 word, bit i set  <=> level1[i] != 0           (i = key >> 16)
 *   level1[key >> 16]    : bit j set           <=> level2[(key >> 8)] != 0  (j = (key >> 8) & 0xff)
 *   level2[key >> 8]     : bit k set           <=> key is set               (k = key & 0xff)
 *
 * Signed int24 values are mapped to keys with `toKey(v) = uint24(v + 2^23)` (order preserving).
 */
library TreeBitmapLib {
    struct Tree {
        uint256 level0;
        mapping(uint256 => uint256) level1;
        mapping(uint256 => uint256) level2;
    }

    int256 internal constant OFFSET = 1 << 23;

    function toKey(int24 v) internal pure returns (uint24) {
        return uint24(uint256(int256(v) + OFFSET));
    }

    function fromKey(uint24 k) internal pure returns (int24) {
        return int24(int256(uint256(k)) - OFFSET);
    }

    function contains(Tree storage t, uint24 key) internal view returns (bool) {
        return t.level2[key >> 8] & (uint256(1) << (key & 0xff)) != 0;
    }

    /// @return changed True if the key was not previously set.
    function add(Tree storage t, uint24 key) internal returns (bool changed) {
        uint256 k2 = key >> 8;
        uint256 leaf = t.level2[k2];
        uint256 bit = uint256(1) << (key & 0xff);
        if (leaf & bit != 0) return false;
        t.level2[k2] = leaf | bit;
        if (leaf == 0) {
            uint256 k1 = key >> 16;
            uint256 l1 = t.level1[k1];
            t.level1[k1] = l1 | (uint256(1) << (k2 & 0xff));
            if (l1 == 0) t.level0 |= uint256(1) << k1;
        }
        return true;
    }

    /// @return changed True if the key was previously set.
    function remove(Tree storage t, uint24 key) internal returns (bool changed) {
        uint256 k2 = key >> 8;
        uint256 leaf = t.level2[k2];
        uint256 bit = uint256(1) << (key & 0xff);
        if (leaf & bit == 0) return false;
        leaf &= ~bit;
        t.level2[k2] = leaf;
        if (leaf == 0) {
            uint256 k1 = key >> 16;
            uint256 l1 = t.level1[k1] & ~(uint256(1) << (k2 & 0xff));
            t.level1[k1] = l1;
            if (l1 == 0) t.level0 &= ~(uint256(1) << k1);
        }
        return true;
    }

    /// @dev Bits strictly below position `b` (0..255).
    function _below(uint256 word, uint256 b) private pure returns (uint256) {
        return word & ((uint256(1) << b) - 1);
    }

    /// @dev Bits strictly above position `b` (0..255).
    function _above(uint256 word, uint256 b) private pure returns (uint256) {
        if (b == 255) return 0;
        return word & ~((uint256(1) << (b + 1)) - 1);
    }

    /// @notice Largest set key strictly below `key`.
    function nextBelow(Tree storage t, uint24 key) internal view returns (bool found, uint24 next) {
        uint256 k2 = key >> 8;
        uint256 w = _below(t.level2[k2], key & 0xff);
        if (w != 0) return (true, uint24((k2 << 8) | BitMath.mostSignificantBit(w)));

        uint256 k1 = key >> 16;
        w = _below(t.level1[k1], k2 & 0xff);
        if (w != 0) {
            k2 = (k1 << 8) | BitMath.mostSignificantBit(w);
            return (true, uint24((k2 << 8) | BitMath.mostSignificantBit(t.level2[k2])));
        }

        w = _below(t.level0, k1);
        if (w != 0) {
            k1 = BitMath.mostSignificantBit(w);
            k2 = (k1 << 8) | BitMath.mostSignificantBit(t.level1[k1]);
            return (true, uint24((k2 << 8) | BitMath.mostSignificantBit(t.level2[k2])));
        }
        return (false, 0);
    }

    /// @notice Smallest set key strictly above `key`.
    function nextAbove(Tree storage t, uint24 key) internal view returns (bool found, uint24 next) {
        uint256 k2 = key >> 8;
        uint256 w = _above(t.level2[k2], key & 0xff);
        if (w != 0) return (true, uint24((k2 << 8) | BitMath.leastSignificantBit(w)));

        uint256 k1 = key >> 16;
        w = _above(t.level1[k1], k2 & 0xff);
        if (w != 0) {
            k2 = (k1 << 8) | BitMath.leastSignificantBit(w);
            return (true, uint24((k2 << 8) | BitMath.leastSignificantBit(t.level2[k2])));
        }

        w = _above(t.level0, k1);
        if (w != 0) {
            k1 = BitMath.leastSignificantBit(w);
            k2 = (k1 << 8) | BitMath.leastSignificantBit(t.level1[k1]);
            return (true, uint24((k2 << 8) | BitMath.leastSignificantBit(t.level2[k2])));
        }
        return (false, 0);
    }
}
