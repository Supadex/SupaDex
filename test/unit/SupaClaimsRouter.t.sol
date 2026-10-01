// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaClaimsRouter} from "../../contract/periphery/SupaClaimsRouter.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {IVault} from "../../contract/interfaces/IVault.sol";
import {PeripheryErrors} from "../../contract/errors/PeripheryErrors.sol";

contract MockERC20Claims {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
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
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SupaClaimsRouterTest is Test {
    using CurrencyLibrary for Currency;

    SupaVault vault;
    SupaClaimsRouter claimsRouter;
    MockERC20Claims token;
    Currency currency;
    address user = address(0xBEEF);

    function setUp() public {
        vault = new SupaVault(address(this));
        claimsRouter = new SupaClaimsRouter(IVault(address(vault)));
        token = new MockERC20Claims();
        currency = Currency.wrap(address(token));

        token.mint(user, 1_000 ether);
        vm.deal(user, 100 ether);
    }

    function test_depositERC20_mintsClaims() public {
        uint256 amount = 10 ether;
        vm.startPrank(user);
        token.approve(address(claimsRouter), amount);
        claimsRouter.deposit(currency, user, amount);
        vm.stopPrank();

        assertEq(vault.balanceOf(user, currency.toId()), amount);
        assertEq(vault.reservesOf(currency), amount);
        assertEq(token.balanceOf(user), 1_000 ether - amount);
    }

    function test_withdrawERC20_redeemsClaims() public {
        uint256 amount = 5 ether;
        vm.startPrank(user);
        token.approve(address(claimsRouter), amount);
        claimsRouter.deposit(currency, user, amount);

        vault.setOperator(address(claimsRouter), true);
        claimsRouter.withdraw(currency, user, amount);
        vm.stopPrank();

        assertEq(vault.balanceOf(user, currency.toId()), 0);
        assertEq(token.balanceOf(user), 1_000 ether);
        assertEq(vault.reservesOf(currency), 0);
    }

    function test_depositNative_mintsClaims() public {
        uint256 amount = 2 ether;
        Currency eth = CurrencyLibrary.NATIVE;

        vm.prank(user);
        claimsRouter.deposit{value: amount}(eth, user, amount);

        assertEq(vault.balanceOf(user, eth.toId()), amount);
        assertEq(vault.reservesOf(eth), amount);
    }

    function test_withdrawNative_redeemsClaims() public {
        uint256 amount = 1 ether;
        Currency eth = CurrencyLibrary.NATIVE;

        vm.startPrank(user);
        claimsRouter.deposit{value: amount}(eth, user, amount);
        vault.setOperator(address(claimsRouter), true);

        uint256 beforeBal = user.balance;
        claimsRouter.withdraw(eth, user, amount);
        vm.stopPrank();

        assertEq(vault.balanceOf(user, eth.toId()), 0);
        assertEq(user.balance, beforeBal + amount);
    }

    function test_deposit_revertsZeroAmount() public {
        vm.expectRevert(PeripheryErrors.ZeroAmount.selector);
        vm.prank(user);
        claimsRouter.deposit(currency, user, 0);
    }
}
