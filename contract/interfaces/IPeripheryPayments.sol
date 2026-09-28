// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";

/**
 * @title IPeripheryPayments
 * @notice Interface for payment settlement, native ETH handling, and ERC-6909 claim claims in periphery.
 */
interface IPeripheryPayments {
    /**
     * @notice Unwraps WETH / transfers any excess native ETH balance to recipient.
     */
    function refundETH() external payable;

    /**
     * @notice Sweeps entire balance of an ERC-20 token or native ETH held in the periphery contract to recipient.
     * @param currency The currency to sweep.
     * @param amountMinimum Minimum expected amount to sweep (reverts if balance is less).
     * @param recipient Address to receive the swept funds.
     */
    function sweepToken(Currency currency, uint256 amountMinimum, address recipient) external payable;
}
