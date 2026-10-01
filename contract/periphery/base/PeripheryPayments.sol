// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVault} from "../../interfaces/IVault.sol";
import {IPeripheryPayments} from "../../interfaces/IPeripheryPayments.sol";
import {Currency, CurrencyLibrary} from "../../types/Currency.sol";
import {PeripheryErrors} from "../../errors/PeripheryErrors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title PeripheryPayments
 * @notice Abstract contract handling token transfers, native ETH custody, and Vault flash-accounting settlements.
 */
abstract contract PeripheryPayments is IPeripheryPayments {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for address;

    /**
     * @dev Internal reference to the core Vault instance.
     */
    IVault internal immutable _vault;

    constructor(IVault vault_) {
        _vault = vault_;
    }

    /**
     * @notice Returns the core Vault instance.
     */
    function vault() public view virtual returns (IVault) {
        return _vault;
    }

    /**
     * @dev Modifier enforcing execution deadline.
     */
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert PeripheryErrors.DeadlinePassed(deadline, block.timestamp);
        _;
    }

    /**
     * @dev Allows contract to receive native ETH from Vault takes and unwraps.
     */
    receive() external payable virtual {}

    /**
     * @notice Settles a debt with the Vault for the given currency and amount.
     * @param currency Token or native ETH.
     * @param payer Account providing the payment.
     * @param amount Quantity of tokens to settle.
     * @param payWithClaims If true, pulls payer's ERC-6909 claims then burns them.
     */
    function _pay(Currency currency, address payer, uint256 amount, bool payWithClaims) internal {
        if (amount == 0) return;

        if (payWithClaims) {
            // Pull user claims onto this periphery locker, then burn to offset vault debt.
            _vault.transferFrom(payer, address(this), currency.toId(), amount);
            _vault.burn(currency, amount);
        } else if (currency.isNative()) {
            if (address(this).balance < amount) {
                revert PeripheryErrors.InsufficientETH(amount, address(this).balance);
            }
            _vault.settle{value: amount}(currency);
        } else {
            currency.toAddress().safeTransferFrom(payer, address(_vault), amount);
            _vault.settle(currency);
        }
    }

    /**
     * @notice Takes credit from the Vault for the given currency and delivers it to recipient.
     * @param currency Token or native ETH.
     * @param recipient Destination address.
     * @param amount Quantity of tokens to take.
     * @param receiveAsClaims If true, mints ERC-6909 claims instead of transferring physical tokens.
     */
    function _take(Currency currency, address recipient, uint256 amount, bool receiveAsClaims) internal {
        if (amount == 0) return;

        if (receiveAsClaims) {
            _vault.mint(currency, recipient, amount);
        } else if (currency.isNative()) {
            _vault.take(currency, address(this), amount);
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            _vault.take(currency, recipient, amount);
        }
    }

    /**
     * @inheritdoc IPeripheryPayments
     */
    function refundETH() external payable override {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, balance);
        }
    }

    /**
     * @inheritdoc IPeripheryPayments
     */
    function sweepToken(Currency currency, uint256 amountMinimum, address recipient) external payable override {
        uint256 balance = currency.balanceOfSelf();
        if (balance < amountMinimum) revert PeripheryErrors.SlippageExceeded(amountMinimum, balance);
        if (balance > 0) {
            currency.transfer(recipient, balance);
        }
    }
}
