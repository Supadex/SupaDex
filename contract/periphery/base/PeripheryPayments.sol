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
            // v4-style: snapshot the vault balance, transfer, then settle exactly what arrived (ADR-0002).
            _vault.sync(currency);
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
     * @dev Refunds all native ETH held by this periphery contract to `to`.
     * @notice I-08: this is the internal helper used by user-facing flows. The
     *      public `refundETH()` below is a different, permissionless path — see its
     *      NatSpec. Never send ETH directly to a periphery contract expecting it
     *      to be held for you; use the router flows, which settle through the vault.
     */
    function _refundETH(address to) internal {
        uint256 balance = address(this).balance;
        if (balance > 0 && to != address(0)) {
            SafeTransferLib.safeTransferETH(to, balance);
        }
    }

    /**
     * @inheritdoc IPeripheryPayments
     * @dev Permissionless sweep of stranded ETH to the caller. User-facing flows must use `_refundETH`.
     * @notice I-08 (internal pre-audit 2026-11-26) — PUBLIC / PERMISSIONLESS, BY DESIGN (Uniswap v3
     *      periphery pattern: "periphery holds no funds"). ANYONE can call this and receive ALL native
     *      ETH currently held by this contract — there is no allowlist, no per-user balance and no
     *      "only my ETH" check, because the contract tracks no per-user ETH balances. The same
     *      applies to `sweepToken` below for ERC-20s. This is safe only because user-facing flows
     *      never leave funds sitting in a periphery contract: swaps and liquidity ops settle
     *      atomically through the vault inside one transaction. Users must NEVER send tokens or ETH
     *      directly to a router / position manager / claims router address — a direct transfer is
     *      stranded balance that the next caller of `sweepToken` / `refundETH` can claim. Frontends
     *      must warn before any direct transfer; see `docs/users/USER_GUIDE.md` §5 and
     *      `docs/TOKEN-POLICY.md`. No behaviour change is made here: restricting these functions
     *      would break the standard periphery pattern (e.g. multicall flows that legitimately
     *      sweep dust) and the audit recommendation is documentation + UI warning only.
     */
    function refundETH() external payable override {
        _refundETH(msg.sender);
    }

    /**
     * @inheritdoc IPeripheryPayments
     * @notice I-08 — PUBLIC / PERMISSIONLESS sweep, by design (see `refundETH` above). Anyone can
     *      withdraw the contract's ENTIRE balance of `currency` (native ETH included) to any
     *      `recipient`, provided the balance is at least `amountMinimum`. There is no per-user
     *      accounting here: tokens accidentally sent directly to this contract are claimable by
     *      anyone. Frontends must warn users never to transfer tokens directly to periphery
     *      contract addresses; see `docs/users/USER_GUIDE.md` §5.
     */
    function sweepToken(Currency currency, uint256 amountMinimum, address recipient) external payable override {
        uint256 balance = currency.balanceOfSelf();
        if (balance < amountMinimum) revert PeripheryErrors.SlippageExceeded(amountMinimum, balance);
        if (balance > 0) {
            currency.transfer(recipient, balance);
        }
    }
}
