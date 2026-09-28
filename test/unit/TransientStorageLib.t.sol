// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TransientStorageLib} from "../../contract/libraries/TransientStorageLib.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";

contract TransientStorageHarness {
    function testLockCycle() external returns (bool initiallyUnlocked, bool lockedState, bool finalState) {
        initiallyUnlocked = TransientStorageLib.isUnlocked();
        TransientStorageLib.acquireLock();
        lockedState = TransientStorageLib.isUnlocked();
        TransientStorageLib.releaseLock();
        finalState = TransientStorageLib.isUnlocked();
    }

    function testDeltaCycle(address user, Currency currency) external returns (int256 d1, int256 d2, int256 d3) {
        d1 = TransientStorageLib.applyDelta(user, currency, 500);
        d2 = TransientStorageLib.applyDelta(user, currency, -200);
        TransientStorageLib.clearDelta(user, currency);
        d3 = TransientStorageLib.getDelta(user, currency);
    }
}

contract TransientStorageLibTest is Test {
    TransientStorageHarness harness;
    Currency testCurrency;

    function setUp() public {
        harness = new TransientStorageHarness();
        testCurrency = Currency.wrap(address(0x1234));
    }

    function test_lockAndUnlock() public {
        (bool init, bool locked, bool finalS) = harness.testLockCycle();
        assertFalse(init);
        assertTrue(locked);
        assertFalse(finalS);
    }

    function test_applyAndGetDelta() public {
        address user = address(0xABCD);
        (int256 d1, int256 d2, int256 d3) = harness.testDeltaCycle(user, testCurrency);
        assertEq(d1, 500);
        assertEq(d2, 300);
        assertEq(d3, 0);
    }
}
