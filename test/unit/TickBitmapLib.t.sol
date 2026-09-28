// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickBitmapLib} from "../../contract/libraries/TickBitmapLib.sol";

contract TickBitmapHarness {
    using TickBitmapLib for mapping(int16 => uint256);
    mapping(int16 => uint256) public bitmap;

    function flipTick(int24 tick, int24 tickSpacing) external {
        bitmap.flipTick(tick, tickSpacing);
    }

    function nextInitializedTickWithinOneWord(int24 tick, int24 tickSpacing, bool lte)
        external
        view
        returns (int24 next, bool initialized)
    {
        return bitmap.nextInitializedTickWithinOneWord(tick, tickSpacing, lte);
    }
}

contract TickBitmapLibTest is Test {
    TickBitmapHarness harness;

    function setUp() public {
        harness = new TickBitmapHarness();
    }

    function test_flipAndFindTick() public {
        int24 tickSpacing = 60;
        int24 tick = 120;

        harness.flipTick(tick, tickSpacing);

        (int24 nextLte, bool initLte) = harness.nextInitializedTickWithinOneWord(120, tickSpacing, true);
        assertTrue(initLte);
        assertEq(nextLte, 120);

        (int24 nextGte, bool initGte) = harness.nextInitializedTickWithinOneWord(0, tickSpacing, false);
        assertTrue(initGte);
        assertEq(nextGte, 120);
    }

    function test_uninitializedWordReturnsBoundary() public view {
        int24 tickSpacing = 60;
        (int24 next, bool initialized) = harness.nextInitializedTickWithinOneWord(0, tickSpacing, true);
        assertFalse(initialized);
        assertEq(next, 0);
    }
}
