// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TransientStorageLib} from "../../contract/libraries/TransientStorageLib.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";

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

    /// Both adds run in one call. Transient storage does not survive separate test-contract calls.
    function applyTwice(address user, Currency currency, int256 first, int256 second) external returns (int256) {
        TransientStorageLib.applyDelta(user, currency, first);
        return TransientStorageLib.applyDelta(user, currency, second);
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

    /// C-01: -int256.max added twice is -2^256+2, which unchecked `add` stores as +2.
    /// Checked addition must revert instead of wrapping the delta back toward zero.
    function test_applyDeltaRevertsOnSignedOverflow() public {
        address user = address(0xABCD);
        vm.expectRevert(VaultErrors.DeltaOverflow.selector);
        harness.applyTwice(user, testCurrency, -type(int256).max, -type(int256).max);
    }

    function testFuzz_applyDeltaNeverWraps(int128 a, int128 b) public {
        address user = address(0xABCD);
        int256 sum = harness.applyTwice(user, testCurrency, int256(a), int256(b));
        assertEq(sum, int256(a) + int256(b));
    }
}
