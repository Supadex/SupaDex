// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    constructor() {
        balanceOf[msg.sender] = 1000 ether;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CurrencyTest is Test {
    using CurrencyLibrary for Currency;

    Currency ethCurrency;
    Currency tokenCurrency;
    MockERC20 token;

    function setUp() public {
        ethCurrency = CurrencyLibrary.NATIVE;
        token = new MockERC20();
        tokenCurrency = Currency.wrap(address(token));
    }

    function test_isNative() public view {
        assertTrue(ethCurrency.isNative());
        assertFalse(tokenCurrency.isNative());
    }

    function test_toAddress() public view {
        assertEq(ethCurrency.toAddress(), address(0));
        assertEq(tokenCurrency.toAddress(), address(token));
    }

    function test_orderingAndEquals() public view {
        assertTrue(ethCurrency.lessThan(tokenCurrency));
        assertTrue(tokenCurrency.greaterThan(ethCurrency));
        assertTrue(ethCurrency.equals(CurrencyLibrary.NATIVE));
    }

    function test_balanceOfSelf() public {
        vm.deal(address(this), 10 ether);
        assertEq(ethCurrency.balanceOfSelf(), 10 ether);

        assertEq(tokenCurrency.balanceOfSelf(), 1000 ether);
    }
}
