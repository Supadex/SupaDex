// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";

contract FullMathLibTest is Test {
    function test_mulDiv() public pure {
        // (10 * 20) / 5 = 40
        assertEq(FullMathLib.mulDiv(10, 20, 5), 40);
    }

    function test_mulDivLargeNumbers() public pure {
        uint256 a = 2 ** 128;
        uint256 b = 2 ** 128;
        uint256 denominator = 2 ** 64;
        // (2^128 * 2^128) / 2^64 = 2^192
        assertEq(FullMathLib.mulDiv(a, b, denominator), 2 ** 192);
    }

    function test_mulDivRoundingUp() public pure {
        // (10 * 20) / 3 = 66.666... => ceil is 67
        assertEq(FullMathLib.mulDivRoundingUp(10, 20, 3), 67);
    }

    function testFuzz_mulDiv(uint128 a, uint128 b, uint128 denominator) public pure {
        vm.assume(denominator > 0);
        uint256 expected = (uint256(a) * uint256(b)) / uint256(denominator);
        assertEq(FullMathLib.mulDiv(a, b, denominator), expected);
    }
}
