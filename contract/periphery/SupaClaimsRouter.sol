// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaClaimsRouter} from "../interfaces/ISupaClaimsRouter.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {IPeripheryEvents} from "../events/IPeripheryEvents.sol";
import {PeripheryPayments} from "./base/PeripheryPayments.sol";
import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {PeripheryErrors} from "../errors/PeripheryErrors.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title SupaClaimsRouter
 * @notice User-facing periphery for depositing physical tokens into SupaVault (mint ERC-6909 claims)
 * and redeeming claims back to physical tokens.
 */
contract SupaClaimsRouter is ISupaClaimsRouter, IUnlockCallback, IPeripheryEvents, PeripheryPayments {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for address;

    enum Action {
        DEPOSIT,
        WITHDRAW
    }

    constructor(IVault _vaultContract) PeripheryPayments(_vaultContract) {}

    /**
     * @inheritdoc ISupaClaimsRouter
     */
    function vault() public view override(ISupaClaimsRouter, PeripheryPayments) returns (IVault) {
        return _vault;
    }

    modifier onlyVault() {
        if (msg.sender != address(_vault)) revert VaultErrors.Unauthorized();
        _;
    }

    /**
     * @inheritdoc ISupaClaimsRouter
     */
    function deposit(Currency currency, address to, uint256 amount) external payable override {
        if (amount == 0) revert PeripheryErrors.ZeroAmount();
        if (to == address(0)) revert PeripheryErrors.Unauthorized();

        if (currency.isNative()) {
            if (msg.value < amount) revert PeripheryErrors.InsufficientETH(amount, msg.value);
        } else {
            currency.toAddress().safeTransferFrom(msg.sender, address(_vault), amount);
        }

        _vault.unlock(abi.encode(Action.DEPOSIT, currency, to, amount));
        emit ClaimDeposited(msg.sender, to, currency, amount);

        // Refund dust ETH
        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaClaimsRouter
     */
    function withdraw(Currency currency, address to, uint256 amount) external override {
        if (amount == 0) revert PeripheryErrors.ZeroAmount();
        if (to == address(0)) revert PeripheryErrors.Unauthorized();

        // Pull claims from user into this contract (requires operator or id allowance)
        _vault.transferFrom(msg.sender, address(this), currency.toId(), amount);
        _vault.unlock(abi.encode(Action.WITHDRAW, currency, to, amount));
        emit ClaimWithdrawn(msg.sender, to, currency, amount);
    }

    /**
     * @inheritdoc IUnlockCallback
     */
    function unlockCallback(bytes calldata data) external override onlyVault returns (bytes memory) {
        (Action action, Currency currency, address to, uint256 amount) =
            abi.decode(data, (Action, Currency, address, uint256));

        if (action == Action.DEPOSIT) {
            if (currency.isNative()) {
                _vault.settle{value: amount}(currency);
            } else {
                _vault.settle(currency);
            }
            _vault.mint(currency, to, amount);
        } else if (action == Action.WITHDRAW) {
            _vault.burn(currency, amount);
            _vault.take(currency, to, amount);
        } else {
            revert PeripheryErrors.Unauthorized();
        }

        return "";
    }
}
