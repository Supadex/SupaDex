// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IERC6909Claims} from "../interfaces/IERC6909Claims.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";
import {TransientStorageLib} from "../libraries/TransientStorageLib.sol";
import {SafeCastLib} from "../libraries/SafeCastLib.sol";

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {ICircuitBreaker} from "../interfaces/ICircuitBreaker.sol";

/**
 * @title SupaVault
 * @notice Core singleton Vault providing physical token custody, standard ERC-6909 internal claims,
 * and flash accounting transient balance delta management.
 * @dev Storage layout (UUPS; MUST stay append-only, verified against the 2026-10 testnet implementation):
 *   slot 0 owner | 1 circuitBreaker | 2 isPoolManager | 3 reservesOf | 4 balanceOf | 5 allowance |
 *   6 isOperator | 7..49 __gap (43 slots reserved for future variables).
 * Settlement (ADR-0002): ERC-20 payments must be bracketed by `sync(currency)` → transfer → `settle`.
 * Tokens that reach the vault outside that bracket (donations, positive rebases) are unaccounted surplus:
 * they never affect any caller's delta and can only be swept by the owner (timelock) via `sweepSurplus`.
 * Pause semantics (SDX-008): the vault itself is never paused, so users can always exit. The circuit
 * breaker is enforced by the PoolManager (swaps, donations and liquidity additions are blocked;
 * liquidity removals, fee collection and claim withdrawals keep working).
 */
contract SupaVault is IVault, UUPSUpgradeable {
    using CurrencyLibrary for Currency;

    /**
     * @notice Contract owner / governance address.
     */
    address public owner;

    /**
     * @notice Multi-tier emergency circuit breaker contract.
     */
    ICircuitBreaker public circuitBreaker;

    /**
     * @notice Mapping of authorized pool managers permitted to modify caller deltas.
     */
    mapping(address => bool) public isPoolManager;

    /**
     * @notice Physical reserves recorded for each currency.
     */
    mapping(Currency => uint256) public override reservesOf;

    /**
     * @notice ERC-6909 claim balance mapping: owner => id => balance.
     */
    mapping(address => mapping(uint256 => uint256)) public override balanceOf;

    /**
     * @notice ERC-6909 allowance mapping: owner => spender => id => amount.
     */
    mapping(address => mapping(address => mapping(uint256 => uint256))) public override allowance;

    /**
     * @notice ERC-6909 operator approval mapping: owner => operator => approved.
     */
    mapping(address => mapping(address => bool)) public override isOperator;

    /**
     * @dev Reserved storage for future upgrades (SDX-014). Shrink when appending new variables.
     */
    uint256[43] private __gap;

    /**
     * @dev Modifier ensuring caller is owner.
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert VaultErrors.Unauthorized();
        _;
    }

    /**
     * @dev Modifier ensuring vault is unlocked.
     */
    modifier onlyUnlocked() {
        if (!TransientStorageLib.isUnlocked()) revert VaultErrors.VaultNotUnlocked();
        _;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert VaultErrors.Unauthorized();
        owner = _owner;
    }

    /**
     * @notice Initializes the Vault proxy instance with an initial owner.
     */
    function initialize(address _owner) external {
        if (owner != address(0)) revert VaultErrors.Unauthorized();
        if (_owner == address(0)) revert VaultErrors.Unauthorized();
        owner = _owner;
    }

    /**
     * @notice Fallback function to accept native ETH deposits.
     */
    receive() external payable {}

    /**
     * @notice Configures the emergency circuit breaker instance.
     */
    function setCircuitBreaker(ICircuitBreaker _circuitBreaker) external onlyOwner {
        circuitBreaker = _circuitBreaker;
        emit CircuitBreakerSet(address(_circuitBreaker));
    }

    /**
     * @notice Transfers vault ownership to a new governor or timelock.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert VaultErrors.Unauthorized();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @dev UUPS upgrade authorization hook restricted to vault owner (governance timelock).
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Grants or revokes pool manager authorization.
     * @param manager Address of the pool manager contract.
     * @param approved Authorization status.
     */
    function setPoolManager(address manager, bool approved) external onlyOwner {
        isPoolManager[manager] = approved;
        emit PoolManagerSet(manager, approved);
    }

    /**
     * @notice Sweeps unaccounted surplus (balance above recorded reserves) of `currency` to `to`.
     * @dev Only callable outside an unlock so in-flight settlements can never be swept.
     * Surplus policy (ADR-0002): donations / positive rebases belong to the protocol (timelock).
     */
    function sweepSurplus(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        if (TransientStorageLib.isUnlocked()) revert VaultErrors.Unauthorized();
        if (to == address(0)) revert VaultErrors.Unauthorized();
        uint256 balance = currency.balanceOfSelf();
        uint256 reserves = reservesOf[currency];
        if (balance <= reserves) revert VaultErrors.ZeroAmount();
        amount = balance - reserves;
        currency.transfer(to, amount);
        emit SurplusSwept(currency, to, amount);
    }

    /**
     * @inheritdoc IVault
     */
    function unlock(bytes calldata data) external override returns (bytes memory result) {
        TransientStorageLib.acquireLock();
        TransientStorageLib.setLocker(msg.sender);
        emit LockAcquired(msg.sender);

        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (TransientStorageLib.getNonzeroDeltaCount() != 0) {
            (Currency unsettled, int256 unsettledDelta) = TransientStorageLib.getLastUnsettled();
            revert VaultErrors.CurrencyNotSettled(unsettled, unsettledDelta);
        }

        TransientStorageLib.clearSynced();
        TransientStorageLib.releaseLock();
        TransientStorageLib.setLocker(address(0));
        emit LockReleased(msg.sender);
    }

    /**
     * @inheritdoc IVault
     */
    function getCurrencyDelta(address account, Currency currency) external view override returns (int256) {
        return TransientStorageLib.getDelta(account, currency);
    }

    /**
     * @inheritdoc IVault
     */
    function isUnlocked() external view override returns (bool) {
        return TransientStorageLib.isUnlocked();
    }

    /**
     * @inheritdoc IVault
     */
    function sync(Currency currency) external override onlyUnlocked {
        if (currency.isNative()) {
            // Native ETH is settled by msg.value; nothing to snapshot.
            TransientStorageLib.clearSynced();
            return;
        }
        uint256 balance = currency.balanceOfSelf();
        TransientStorageLib.setSynced(currency, balance);
        emit Sync(currency, balance);
    }

    /**
     * @inheritdoc IVault
     */
    function settle(Currency currency) external payable override onlyUnlocked returns (uint256 paid) {
        if (currency.isNative()) {
            paid = msg.value;
        } else {
            if (msg.value != 0) revert VaultErrors.NonZeroNativeValue();
            (bool isSynced, Currency synced, uint256 syncedBalance) = TransientStorageLib.getSynced();
            if (!isSynced || Currency.unwrap(synced) != Currency.unwrap(currency)) {
                revert VaultErrors.CurrencyNotSynced(currency);
            }
            // Credit exactly what arrived since `sync`; donations made outside the bracket are surplus.
            paid = currency.balanceOfSelf() - syncedBalance;
            TransientStorageLib.clearSynced();
        }
        if (paid == 0) revert VaultErrors.ZeroAmount();

        reservesOf[currency] += paid;
        TransientStorageLib.applyDelta(msg.sender, currency, SafeCastLib.toInt256(paid));
        emit Settle(currency, msg.sender, paid);
    }

    /**
     * @inheritdoc IVault
     */
    function take(Currency currency, address to, uint256 amount) external override onlyUnlocked {
        if (amount == 0) revert VaultErrors.ZeroAmount();
        uint256 reserves = reservesOf[currency];
        if (reserves < amount) {
            revert VaultErrors.InsufficientBalance(currency, amount, reserves);
        }

        reservesOf[currency] = reserves - amount;
        TransientStorageLib.applyDelta(msg.sender, currency, -SafeCastLib.toInt256(amount));
        currency.transfer(to, amount);
        emit Take(currency, to, amount);
    }

    /**
     * @inheritdoc IVault
     */
    function mint(Currency currency, address to, uint256 amount) external override onlyUnlocked {
        if (amount == 0) revert VaultErrors.ZeroAmount();
        TransientStorageLib.applyDelta(msg.sender, currency, -SafeCastLib.toInt256(amount));

        uint256 id = currency.toId();
        balanceOf[to][id] += amount;
        emit ClaimMinted(currency, to, amount);
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    /**
     * @inheritdoc IVault
     */
    function burn(Currency currency, uint256 amount) external override onlyUnlocked {
        if (amount == 0) revert VaultErrors.ZeroAmount();
        uint256 id = currency.toId();
        uint256 currentBal = balanceOf[msg.sender][id];
        if (currentBal < amount) {
            revert VaultErrors.InsufficientBalance(currency, amount, currentBal);
        }

        balanceOf[msg.sender][id] = currentBal - amount;
        TransientStorageLib.applyDelta(msg.sender, currency, SafeCastLib.toInt256(amount));
        emit ClaimBurned(currency, msg.sender, amount);
        emit Transfer(msg.sender, msg.sender, address(0), id, amount);
    }

    /**
     * @inheritdoc IVault
     */
    function accountDelta(address account, Currency currency, int256 delta) external override onlyUnlocked {
        // ADR-0005: only authorized pool managers may move deltas (no owner self-credit path).
        if (!isPoolManager[msg.sender]) revert VaultErrors.Unauthorized();
        TransientStorageLib.applyDelta(account, currency, delta);
    }

    // =========================================================================
    //                            ERC-6909 CLAIMS
    // =========================================================================

    /**
     * @inheritdoc IERC6909Claims
     */
    function transfer(address receiver, uint256 id, uint256 amount) external override returns (bool) {
        uint256 senderBalance = balanceOf[msg.sender][id];
        if (senderBalance < amount) {
            revert VaultErrors.InsufficientBalance(Currency.wrap(address(uint160(id))), amount, senderBalance);
        }
        balanceOf[msg.sender][id] = senderBalance - amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    /**
     * @inheritdoc IERC6909Claims
     */
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        override
        returns (bool)
    {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) {
                if (allowed < amount) revert VaultErrors.Unauthorized();
                allowance[sender][msg.sender][id] = allowed - amount;
            }
        }

        uint256 senderBalance = balanceOf[sender][id];
        if (senderBalance < amount) {
            revert VaultErrors.InsufficientBalance(Currency.wrap(address(uint160(id))), amount, senderBalance);
        }

        balanceOf[sender][id] = senderBalance - amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    /**
     * @inheritdoc IERC6909Claims
     */
    function approve(address spender, uint256 id, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    /**
     * @inheritdoc IERC6909Claims
     */
    function setOperator(address operator, bool approved) external override returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }
}
