// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";

/**
 * @title VaultErrors
 * @notice Library containing custom errors for the SupaDex Vault and Flash Accounting Ledger.
 */
library VaultErrors {
    /**
     * @dev Thrown when an unlock callback leaves non-zero currency deltas unsettled.
     */
    error CurrencyNotSettled(Currency currency, int256 delta);

    /**
     * @dev Thrown when an account attempts to reenter an already locked/unlocked context.
     */
    error VaultAlreadyLocked();

    /**
     * @dev Thrown when attempting an operation that requires an active unlock lock session.
     */
    error VaultNotUnlocked();

    /**
     * @dev Thrown when a zero-amount transfer or mint is attempted where disallowed.
     */
    error ZeroAmount();

    /**
     * @dev Thrown when attempting to burn or take more tokens than available balance.
     */
    error InsufficientBalance(Currency currency, uint256 requested, uint256 available);

    /**
     * @dev Thrown when an unauthorized caller attempts a restricted vault operation.
     */
    error Unauthorized();

    /**
     * @dev Thrown when native ETH transfer fails.
     */
    error ETHTransferFailed();
}
