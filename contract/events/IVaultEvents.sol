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
}
