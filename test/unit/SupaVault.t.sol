// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {IVault} from "../../contract/interfaces/IVault.sol";
import {IERC6909Claims} from "../../contract/interfaces/IERC6909Claims.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";

contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultUnlocker is IUnlockCallback {
    SupaVault public vault;

    enum Action {
        NONE,
        SETTLE_AND_TAKE,
        MINT_CLAIM,
        BURN_CLAIM,
        LEAVE_UNSETTLED,
        REENTER
    }

    constructor(SupaVault _vault) {
        vault = _vault;
    }

    receive() external payable {}

    function executeUnlock(bytes calldata data) external returns (bytes memory) {
        return vault.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (Action action, Currency currency, uint256 amount) = abi.decode(data, (Action, Currency, uint256));

        if (action == Action.SETTLE_AND_TAKE) {
            // Settle tokens deposited then take back
            vault.settle(currency);
            vault.take(currency, address(this), amount);
        } else if (action == Action.MINT_CLAIM) {
            // Settle tokens then mint claim
            vault.settle(currency);
            vault.mint(currency, address(this), amount);
        } else if (action == Action.BURN_CLAIM) {
            // Burn claim then take physical tokens
            vault.burn(currency, amount);
            vault.take(currency, address(this), amount);
        } else if (action == Action.LEAVE_UNSETTLED) {
            // Take without settling -> leaves delta negative
            vault.take(currency, address(this), amount);
        } else if (action == Action.REENTER) {
            // Attempt recursive unlock
            vault.unlock(data);
        }

        return abi.encode(true);
    }
}

contract SupaVaultTest is Test {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    VaultUnlocker public unlocker;
    MockERC20 public token;
    Currency public tokenCurrency;
    Currency public ethCurrency;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    function setUp() public {
        vault = new SupaVault(address(this));
        unlocker = new VaultUnlocker(vault);
        token = new MockERC20();
        tokenCurrency = Currency.wrap(address(token));
        ethCurrency = CurrencyLibrary.NATIVE;

        vm.deal(address(unlocker), 100 ether);
        token.mint(address(unlocker), 1000 ether);
    }

    function test_settleAndTakeERC20() public {
        uint256 amount = 50 ether;
        // Transfer token to vault first
        vm.prank(address(unlocker));
        token.transfer(address(vault), amount);

        bytes memory data = abi.encode(VaultUnlocker.Action.SETTLE_AND_TAKE, tokenCurrency, amount);
        unlocker.executeUnlock(data);

        assertEq(token.balanceOf(address(unlocker)), 1000 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_settleAndTakeETH() public {
        uint256 amount = 10 ether;
        // Send ETH to vault first
        vm.prank(address(unlocker));
        payable(address(vault)).transfer(amount);

        bytes memory data = abi.encode(VaultUnlocker.Action.SETTLE_AND_TAKE, ethCurrency, amount);
        unlocker.executeUnlock(data);

        assertEq(address(unlocker).balance, 100 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_mintAndBurnClaims() public {
        uint256 amount = 25 ether;
        uint256 tokenId = tokenCurrency.toId();

        // 1. Settle tokens and mint claim
        vm.prank(address(unlocker));
        token.transfer(address(vault), amount);

        bytes memory mintData = abi.encode(VaultUnlocker.Action.MINT_CLAIM, tokenCurrency, amount);
        unlocker.executeUnlock(mintData);

        assertEq(vault.balanceOf(address(unlocker), tokenId), amount);
        assertEq(token.balanceOf(address(vault)), amount);

        // 2. Burn claim and take physical tokens
        bytes memory burnData = abi.encode(VaultUnlocker.Action.BURN_CLAIM, tokenCurrency, amount);
        unlocker.executeUnlock(burnData);

        assertEq(vault.balanceOf(address(unlocker), tokenId), 0);
        assertEq(token.balanceOf(address(unlocker)), 1000 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_unsettledDeltaReverts() public {
        uint256 amount = 10 ether;
        token.mint(address(vault), 100 ether); // seed vault physical balance

        bytes memory data = abi.encode(VaultUnlocker.Action.LEAVE_UNSETTLED, tokenCurrency, amount);
        vm.expectRevert();
        unlocker.executeUnlock(data);
    }

    function test_reentrantUnlockReverts() public {
        bytes memory data = abi.encode(VaultUnlocker.Action.REENTER, tokenCurrency, 0);
        vm.expectRevert();
        unlocker.executeUnlock(data);
    }

    function test_erc6909TransferAndApprovals() public {
        uint256 amount = 100 ether;
        uint256 tokenId = tokenCurrency.toId();

        // Settle & mint claim to unlocker
        vm.prank(address(unlocker));
        token.transfer(address(vault), amount);
        unlocker.executeUnlock(abi.encode(VaultUnlocker.Action.MINT_CLAIM, tokenCurrency, amount));

        // Transfer claims from unlocker to alice
        vm.prank(address(unlocker));
        vault.transfer(alice, tokenId, 40 ether);

        assertEq(vault.balanceOf(address(unlocker), tokenId), 60 ether);
        assertEq(vault.balanceOf(alice, tokenId), 40 ether);

        // Alice approves Bob for 10 ether
        vm.prank(alice);
        vault.approve(bob, tokenId, 10 ether);
        assertEq(vault.allowance(alice, bob, tokenId), 10 ether);

        // Bob transfers 10 ether from Alice to Bob
        vm.prank(bob);
        vault.transferFrom(alice, bob, tokenId, 10 ether);
        assertEq(vault.balanceOf(bob, tokenId), 10 ether);
        assertEq(vault.balanceOf(alice, tokenId), 30 ether);
        assertEq(vault.allowance(alice, bob, tokenId), 0);

        // Operator approval
        vm.prank(alice);
        vault.setOperator(bob, true);
        assertTrue(vault.isOperator(alice, bob));

        // Bob transfers using operator permission
        vm.prank(bob);
        vault.transferFrom(alice, bob, tokenId, 30 ether);
        assertEq(vault.balanceOf(bob, tokenId), 40 ether);
        assertEq(vault.balanceOf(alice, tokenId), 0);
    }

    function test_poolManagerAuthorization() public {
        address manager = address(0x1234);
        assertFalse(vault.isPoolManager(manager));

        vault.setPoolManager(manager, true);
        assertTrue(vault.isPoolManager(manager));

        vault.setPoolManager(manager, false);
        assertFalse(vault.isPoolManager(manager));
    }
}
