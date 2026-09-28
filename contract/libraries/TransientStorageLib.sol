// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";

/**
 * @title TransientStorageLib
 * @notice Low-level assembly library managing EIP-1153 transient storage (`TSTORE` / `TLOAD`)
 * with zero-gas storage cleanup for reentrancy locks and currency balance deltas.
 */
library TransientStorageLib {
    /**
     * @dev Slot offset constant for vault reentrancy lock: keccak256("supadex.vault.lock.slot")
     */
    bytes32 internal constant LOCK_SLOT = 0xd5f187902d33458bf59c3e4a9058b8f36c5df5eb8c74fb90b62140a33c2a66e6;

    /**
     * @dev Slot offset constant for currency delta map prefix: keccak256("supadex.vault.delta.prefix")
     */
    bytes32 internal constant DELTA_PREFIX = 0xb24d08ceee77d853e4b7bfe3da4821ef9a2c342fb835567c2e3dd740c0378ce1;

    /**
     * @dev Slot offset constant for vault locker: keccak256("supadex.vault.locker.slot")
     */
    bytes32 internal constant LOCKER_SLOT = 0x6e8ff5f340be1e7fce95d85ee229d479cb20aa54b03692d9d95f8846be09db17;

    /**
     * @dev Slot offset constant for nonzero delta count: keccak256("supadex.vault.nonzero.delta.count")
     */
    bytes32 internal constant NONZERO_DELTA_COUNT_SLOT = 0x3d386d34b46c6fc3aa478672224da1c7fe68eb7810ecba14aa0fe77209353982;

    /**
     * @notice Acquires transient reentrancy lock. Reverts if already locked.
     */
    function acquireLock() internal {
        bytes32 lockSlot = LOCK_SLOT;
        assembly {
            if tload(lockSlot) {
                // Revert with VaultErrors.VaultAlreadyLocked selector (0x5462fc74)
                mstore(0x00, 0x5462fc7400000000000000000000000000000000000000000000000000000000)
                revert(0x00, 0x04)
            }
            tstore(lockSlot, 1)
        }
    }

    /**
     * @notice Releases transient reentrancy lock.
     */
    function releaseLock() internal {
        bytes32 lockSlot = LOCK_SLOT;
        assembly {
            tstore(lockSlot, 0)
        }
    }

    /**
     * @notice Checks if the vault is currently in an unlocked execution context.
     */
    function isUnlocked() internal view returns (bool unlocked) {
        bytes32 lockSlot = LOCK_SLOT;
        assembly {
            unlocked := tload(lockSlot)
        }
    }

    /**
     * @notice Sets the active locker address in transient storage.
     */
    function setLocker(address locker) internal {
        bytes32 slot = LOCKER_SLOT;
        assembly {
            tstore(slot, locker)
        }
    }

    /**
     * @notice Gets the active locker address from transient storage.
     */
    function getLocker() internal view returns (address locker) {
        bytes32 slot = LOCKER_SLOT;
        assembly {
            locker := tload(slot)
        }
    }

    /**
     * @notice Gets the current number of non-zero currency deltas across active accounts.
     */
    function getNonzeroDeltaCount() internal view returns (uint256 count) {
        bytes32 slot = NONZERO_DELTA_COUNT_SLOT;
        assembly {
            count := tload(slot)
        }
    }

    /**
     * @notice Computes transient storage slot for (account, currency) delta.
     */
    function computeDeltaSlot(address account, Currency currency) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, Currency.unwrap(currency), DELTA_PREFIX));
    }

    /**
     * @notice Gets transient delta balance for an account and currency.
     */
    function getDelta(address account, Currency currency) internal view returns (int256 delta) {
        bytes32 slot = computeDeltaSlot(account, currency);
        assembly {
            delta := tload(slot)
        }
    }

    /**
     * @notice Applies a delta change to (account, currency) and updates nonzero delta count.
     */
    function applyDelta(address account, Currency currency, int256 deltaChange) internal returns (int256 newDelta) {
        if (deltaChange == 0) return getDelta(account, currency);
        bytes32 deltaSlot = computeDeltaSlot(account, currency);
        bytes32 countSlot = NONZERO_DELTA_COUNT_SLOT;
        assembly {
            let current := tload(deltaSlot)
            newDelta := add(current, deltaChange)
            tstore(deltaSlot, newDelta)

            let count := tload(countSlot)
            // If previous was 0 and new is non-zero, increment count
            if and(iszero(current), iszero(iszero(newDelta))) {
                tstore(countSlot, add(count, 1))
            }
            // If previous was non-zero and new is 0, decrement count
            if and(iszero(iszero(current)), iszero(newDelta)) {
                tstore(countSlot, sub(count, 1))
            }
        }
    }

    /**
     * @notice Clears transient delta for (account, currency).
     */
    function clearDelta(address account, Currency currency) internal {
        bytes32 deltaSlot = computeDeltaSlot(account, currency);
        bytes32 countSlot = NONZERO_DELTA_COUNT_SLOT;
        assembly {
            let current := tload(deltaSlot)
            if iszero(iszero(current)) {
                tstore(deltaSlot, 0)
                let count := tload(countSlot)
                if gt(count, 0) {
                    tstore(countSlot, sub(count, 1))
                }
            }
        }
    }
}
