// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";

/**
 * @title IVaultEvents
 * @notice Interface containing all event declarations for the SupaDex Vault.
 */
interface IVaultEvents {
    /**
     * @notice Emitted when an unlock session is initiated.
     */
    event LockAcquired(address indexed locker);

    /**
     * @notice Emitted when an unlock session completes with zero outstanding deltas.
     */
    event LockReleased(address indexed locker);

    /**
     * @notice Emitted when an account settles tokens into the Vault.
     */
    event Settle(Currency indexed currency, address indexed payer, uint256 amount);

    /**
     * @notice Emitted when tokens are transferred out of the Vault.
     */
    event Take(Currency indexed currency, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when ERC-6909 claim tokens are minted.
     */
    event ClaimMinted(Currency indexed currency, address indexed account, uint256 amount);

    /**
     * @notice Emitted when ERC-6909 claim tokens are burned.
     */
    event ClaimBurned(Currency indexed currency, address indexed account, uint256 amount);

    /**
     * @notice Emitted when a currency balance is snapshotted ahead of a settle.
     */
    event Sync(Currency indexed currency, uint256 balance);

    /**
     * @notice Emitted when unaccounted surplus (donations, positive rebases) is swept by the owner.
     */
    event SurplusSwept(Currency indexed currency, address indexed to, uint256 amount);

    /**
     * @notice Emitted when vault ownership changes.
     */
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @notice Emitted when a pool manager is (de)authorized.
     */
    event PoolManagerSet(address indexed manager, bool approved);

    /**
     * @notice Emitted when the circuit breaker reference changes.
     */
    event CircuitBreakerSet(address indexed circuitBreaker);
}
