// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";
import {IERC6909Claims} from "./IERC6909Claims.sol";
import {IVaultEvents} from "../events/IVaultEvents.sol";

/**
 * @title IVault
 * @notice Interface for the SupaDex Singleton Vault managing transient deltas and physical token balances.
 */
interface IVault is IERC6909Claims, IVaultEvents {
    /**
     * @notice Initiates a flash accounting session.
     * @param data Data passed to `IUnlockCallback(msg.sender).unlockCallback(data)`.
     * @return result The return data from the callback.
     */
    function unlock(bytes calldata data) external returns (bytes memory result);

    /**
     * @notice Returns the current transient delta for an account and currency.
     */
    function getCurrencyDelta(address account, Currency currency) external view returns (int256);

    /**
     * @notice Settles tokens into the Vault, increasing the caller's transient delta towards zero.
     * @param currency The currency being settled.
     * @return paid The amount of tokens paid to settle.
     */
    function settle(Currency currency) external payable returns (uint256 paid);

    /**
     * @notice Takes tokens from the Vault to a recipient, decreasing the caller's transient delta.
     * @param currency The currency being taken.
     * @param to The recipient of the tokens.
     * @param amount The amount of tokens taken.
     */
    function take(Currency currency, address to, uint256 amount) external;

    /**
     * @notice Mints ERC-6909 claims, consuming positive transient delta.
     * @param currency The currency claim being minted.
     * @param to The recipient of the claim tokens.
     * @param amount The amount of claim tokens to mint.
     */
    function mint(Currency currency, address to, uint256 amount) external;

    /**
     * @notice Burns ERC-6909 claims, creating positive transient delta to offset debts.
     * @param currency The currency claim being burned.
     * @param amount The amount of claim tokens to burn.
     */
    function burn(Currency currency, uint256 amount) external;

    /**
     * @notice Applies a transient delta to an account (callable by authorized PoolManager).
     * @param account The account whose delta is modified.
     * @param currency The currency being modified.
     * @param delta The delta change to apply.
     */
    function accountDelta(address account, Currency currency, int256 delta) external;

    /**
     * @notice Returns the recorded physical reserves for a currency.
     * @param currency The currency to query.
     */
    function reservesOf(Currency currency) external view returns (uint256);

    /**
     * @notice Returns whether the vault is currently in an active unlock session.
     */
    function isUnlocked() external view returns (bool);
}
