// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title Currency
 * @notice User-defined value type representing an ERC-20 token address or native ETH (address(0)).
 */
type Currency is address;

using {
    CurrencyLibrary.isNative,
    CurrencyLibrary.toAddress,
    CurrencyLibrary.toId,
    CurrencyLibrary.transfer,
    CurrencyLibrary.balanceOfSelf,
    CurrencyLibrary.balanceOf,
    CurrencyLibrary.equals,
    CurrencyLibrary.greaterThan,
    CurrencyLibrary.lessThan
} for Currency global;

/**
 * @notice Library implementing optimized currency operations.
 */
library CurrencyLibrary {
    using SafeTransferLib for address;

    /**
     * @dev Native ETH representation constant (address(0)).
     */
    Currency public constant NATIVE = Currency.wrap(address(0));

    /**
     * @notice Check if the currency is native ETH.
     */
    function isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }

    /**
     * @notice Unwraps currency to raw address.
     */
    function toAddress(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }

    /**
     * @notice Converts currency to uint256 token ID for ERC-6909 claims.
     */
    function toId(Currency currency) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(currency)));
    }

    /**
     * @notice Transfers currency to a recipient.
     */
    function transfer(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isNative()) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            currency.toAddress().safeTransfer(to, amount);
        }
    }

    /**
     * @notice Returns the contract's own balance for the currency.
     */
    function balanceOfSelf(Currency currency) internal view returns (uint256) {
        if (currency.isNative()) {
            return address(this).balance;
        } else {
            return currency.toAddress().balanceOf(address(this));
        }
    }

    /**
     * @notice Returns the balance of an account for the currency.
     */
    function balanceOf(Currency currency, address account) internal view returns (uint256) {
        if (currency.isNative()) {
            return account.balance;
        } else {
            return currency.toAddress().balanceOf(account);
        }
    }

    /**
     * @notice Equality comparison between two currencies.
     */
    function equals(Currency a, Currency b) internal pure returns (bool) {
        return Currency.unwrap(a) == Currency.unwrap(b);
    }

    /**
     * @notice Greater-than comparison (useful for sorting token0/token1).
     */
    function greaterThan(Currency a, Currency b) internal pure returns (bool) {
        return Currency.unwrap(a) > Currency.unwrap(b);
    }

    /**
     * @notice Less-than comparison (useful for sorting token0/token1).
     */
    function lessThan(Currency a, Currency b) internal pure returns (bool) {
        return Currency.unwrap(a) < Currency.unwrap(b);
    }
}
