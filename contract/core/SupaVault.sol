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
import {CircuitBreakerErrors} from "../errors/CircuitBreakerErrors.sol";

/**
 * @title SupaVault
 * @notice Core singleton Vault providing physical token custody, standard ERC-6909 internal claims,
 * and flash accounting transient balance delta management.
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

    /**
     * @dev Modifier ensuring vault is not paused by circuit breaker.
     */
    modifier whenNotPaused() {
        if (address(circuitBreaker) != address(0) && circuitBreaker.isVaultPaused()) {
            revert CircuitBreakerErrors.VaultPaused();
        }
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
    }

    /**
     * @notice Transfers vault ownership to a new governor or timelock.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert VaultErrors.Unauthorized();
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
    }

    /**
     * @inheritdoc IVault
     */
    function unlock(bytes calldata data) external override whenNotPaused returns (bytes memory result) {
        TransientStorageLib.acquireLock();
        TransientStorageLib.setLocker(msg.sender);
        emit LockAcquired(msg.sender);

        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (TransientStorageLib.getNonzeroDeltaCount() != 0) {
            revert VaultErrors.CurrencyNotSettled(Currency.wrap(address(0)), 0);
        }

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
    function settle(Currency currency) external payable override onlyUnlocked whenNotPaused returns (uint256 paid) {
        uint256 balance = currency.balanceOfSelf();
        uint256 reserves = reservesOf[currency];
        if (balance < reserves) {
            revert VaultErrors.InsufficientBalance(currency, reserves, balance);
        }
        paid = balance - reserves;
        if (paid == 0) revert VaultErrors.ZeroAmount();

        reservesOf[currency] = balance;
        TransientStorageLib.applyDelta(msg.sender, currency, SafeCastLib.toInt256(paid));
        emit Settle(currency, msg.sender, paid);
    }

    /**
     * @inheritdoc IVault
     */
    function take(Currency currency, address to, uint256 amount) external override onlyUnlocked whenNotPaused {
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
    function mint(Currency currency, address to, uint256 amount) external override onlyUnlocked whenNotPaused {
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
    function burn(Currency currency, uint256 amount) external override onlyUnlocked whenNotPaused {
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
        if (!isPoolManager[msg.sender] && msg.sender != owner) {
            revert VaultErrors.Unauthorized();
        }
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
