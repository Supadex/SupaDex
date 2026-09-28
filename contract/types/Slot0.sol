// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Slot0
 * @notice User-defined value type packing the current pool state in a single 256-bit storage slot.
 * @dev Packing:
 * - sqrtPriceX96: uint160 (bits 0..159)
 * - tick: int24 (bits 160..183)
 * - protocolFee: uint24 (bits 184..207)
 * - dynamicFee: uint24 (bits 208..231)
 * - unlocked/initialized: uint8 (bits 232..239)
 */
type Slot0 is bytes32;

using {
    Slot0Library.sqrtPriceX96,
    Slot0Library.tick,
    Slot0Library.protocolFee,
    Slot0Library.dynamicFee,
    Slot0Library.isInitialized,
    Slot0Library.setSqrtPriceX96,
    Slot0Library.setTick,
    Slot0Library.setProtocolFee,
    Slot0Library.setDynamicFee
} for Slot0 global;

library Slot0Library {
    uint256 internal constant MASK_160 = (1 << 160) - 1;
    uint256 internal constant MASK_24 = (1 << 24) - 1;

    /**
     * @notice Packs initial Slot0 values into bytes32.
     */
    function pack(uint160 _sqrtPriceX96, int24 _tick, uint24 _protocolFee, uint24 _dynamicFee, bool _initialized)
        internal
        pure
        returns (Slot0)
    {
        bytes32 packed;
        assembly {
            let p := and(_sqrtPriceX96, MASK_160)
            let t := shl(160, and(_tick, MASK_24))
            let pf := shl(184, and(_protocolFee, MASK_24))
            let df := shl(208, and(_dynamicFee, MASK_24))
            let init := shl(232, and(_initialized, 1))
            packed := or(p, or(t, or(pf, or(df, init))))
        }
        return Slot0.wrap(packed);
    }

    /**
     * @notice Unpacks sqrtPriceX96.
     */
    function sqrtPriceX96(Slot0 slot0) internal pure returns (uint160 _price) {
        assembly {
            _price := and(slot0, MASK_160)
        }
    }

    /**
     * @notice Unpacks current tick.
     */
    function tick(Slot0 slot0) internal pure returns (int24 _tick) {
        assembly {
            _tick := signextend(2, sar(160, slot0))
        }
    }

    /**
     * @notice Unpacks protocol fee.
     */
    function protocolFee(Slot0 slot0) internal pure returns (uint24 _pf) {
        assembly {
            _pf := and(sar(184, slot0), MASK_24)
        }
    }

    /**
     * @notice Unpacks dynamic fee.
     */
    function dynamicFee(Slot0 slot0) internal pure returns (uint24 _df) {
        assembly {
            _df := and(sar(208, slot0), MASK_24)
        }
    }

    /**
     * @notice Returns true if the pool is initialized.
     */
    function isInitialized(Slot0 slot0) internal pure returns (bool _init) {
        assembly {
            _init := iszero(iszero(and(sar(232, slot0), 1)))
        }
    }

    /**
     * @notice Sets a new sqrtPriceX96.
     */
    function setSqrtPriceX96(Slot0 slot0, uint160 newPrice) internal pure returns (Slot0) {
        bytes32 packed;
        assembly {
            let cleared := and(slot0, not(MASK_160))
            packed := or(cleared, and(newPrice, MASK_160))
        }
        return Slot0.wrap(packed);
    }

    /**
     * @notice Sets a new tick.
     */
    function setTick(Slot0 slot0, int24 newTick) internal pure returns (Slot0) {
        bytes32 packed;
        assembly {
            let cleared := and(slot0, not(shl(160, MASK_24)))
            packed := or(cleared, shl(160, and(newTick, MASK_24)))
        }
        return Slot0.wrap(packed);
    }

    /**
     * @notice Sets a new protocol fee.
     */
    function setProtocolFee(Slot0 slot0, uint24 newFee) internal pure returns (Slot0) {
        bytes32 packed;
        assembly {
            let cleared := and(slot0, not(shl(184, MASK_24)))
            packed := or(cleared, shl(184, and(newFee, MASK_24)))
        }
        return Slot0.wrap(packed);
    }

    /**
     * @notice Sets a new dynamic fee.
     */
    function setDynamicFee(Slot0 slot0, uint24 newFee) internal pure returns (Slot0) {
        bytes32 packed;
        assembly {
            let cleared := and(slot0, not(shl(208, MASK_24)))
            packed := or(cleared, shl(208, and(newFee, MASK_24)))
        }
        return Slot0.wrap(packed);
    }
}
