// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract BalanceDeltaTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;

    function test_packAndUnpackDeltas() public pure {
        int128 a0 = 1000;
        int128 a1 = -2000;

        BalanceDelta delta = toBalanceDelta(a0, a1);

        assertEq(delta.amount0(), a0);
        assertEq(delta.amount1(), a1);
    }

    function test_addDeltas() public pure {
        BalanceDelta d1 = toBalanceDelta(100, -50);
        BalanceDelta d2 = toBalanceDelta(200, 300);

        BalanceDelta result = d1.add(d2);

        assertEq(result.amount0(), 300);
        assertEq(result.amount1(), 250);
    }

    function test_subDeltas() public pure {
        BalanceDelta d1 = toBalanceDelta(100, -50);
        BalanceDelta d2 = toBalanceDelta(40, 20);

        BalanceDelta result = d1.sub(d2);

        assertEq(result.amount0(), 60);
        assertEq(result.amount1(), -70);
    }

    function testFuzz_packing(int128 a0, int128 a1) public pure {
        BalanceDelta delta = toBalanceDelta(a0, a1);
        assertEq(delta.amount0(), a0);
        assertEq(delta.amount1(), a1);
    }
}
