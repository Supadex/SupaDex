// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";

contract SafeCastHarness {
    function toUint128(uint256 x) external pure returns (uint128) {
        return SafeCastLib.toUint128(x);
    }

    function toInt128(int256 x) external pure returns (int128) {
        return SafeCastLib.toInt128(x);
    }
}

contract SafeCastLibTest is Test {
    SafeCastHarness harness;

    function setUp() public {
        harness = new SafeCastHarness();
    }

    function test_toUint128() public view {
        uint256 x = 123456;
        assertEq(harness.toUint128(x), 123456);
    }

    function test_toUint128RevertsOnOverflow() public {
        uint256 x = uint256(type(uint128).max) + 1;
        vm.expectRevert(SafeCastLib.SafeCastOverflow.selector);
        harness.toUint128(x);
    }

    function test_toInt128() public view {
        int256 x = -500;
        assertEq(harness.toInt128(x), -500);
    }

    function test_toInt128RevertsOnOverflow() public {
        int256 x = int256(type(int128).max) + 1;
        vm.expectRevert(SafeCastLib.SafeCastOverflow.selector);
        harness.toInt128(x);
    }

    function test_toInt128RevertsOnUnderflow() public {
        int256 x = int256(type(int128).min) - 1;
        vm.expectRevert(SafeCastLib.SafeCastOverflow.selector);
        harness.toInt128(x);
    }
}
