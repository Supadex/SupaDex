// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";
import {IVault} from "./IVault.sol";

/**
 * @title ISupaClaimsRouter
 * @notice User-facing periphery for minting and redeeming ERC-6909 vault claims.
 */
interface ISupaClaimsRouter {
    /**
     * @notice Returns the SupaVault instance.
     */
    function vault() external view returns (IVault);

    /**
     * @notice Deposit physical tokens into the vault and mint 1:1 ERC-6909 claims.
     * @param currency Token or native ETH (address(0)).
     * @param to Recipient of minted claims.
     * @param amount Amount to deposit and mint.
     */
    function deposit(Currency currency, address to, uint256 amount) external payable;

    /**
     * @notice Burn ERC-6909 claims and withdraw physical tokens.
     * @dev Caller must `setOperator(claimsRouter, true)` or approve this contract for the currency id.
     * @param currency Token or native ETH (address(0)).
     * @param to Recipient of physical tokens.
     * @param amount Amount of claims to redeem.
     */
    function withdraw(Currency currency, address to, uint256 amount) external;
}
