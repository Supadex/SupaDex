// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";

contract TickMathHarness {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return TickMathLib.getSqrtRatioAtTick(tick);
    }

    function getTickAtSqrtRatio(uint160 sqrtPriceX96) external pure returns (int24) {
        return TickMathLib.getTickAtSqrtRatio(sqrtPriceX96);
    }
}

contract TickMathLibTest is Test {
    TickMathHarness harness;

    function setUp() public {
        harness = new TickMathHarness();
    }

    function test_tickZero() public view {
        uint160 sqrtPriceX96 = harness.getSqrtRatioAtTick(0);
        // sqrt(1) * 2^96 = 2^96 = 79228162514264337593543950336
        assertEq(sqrtPriceX96, 79228162514264337593543950336);

        int24 tick = harness.getTickAtSqrtRatio(sqrtPriceX96);
        assertEq(tick, 0);
    }

    function test_minAndMaxTicks() public view {
        uint160 minSqrtRatio = harness.getSqrtRatioAtTick(TickMathLib.MIN_TICK);
        assertEq(minSqrtRatio, TickMathLib.MIN_SQRT_RATIO);

        uint160 maxSqrtRatio = harness.getSqrtRatioAtTick(TickMathLib.MAX_TICK);
        assertEq(maxSqrtRatio, TickMathLib.MAX_SQRT_RATIO);
    }

    function test_tickOutOfBoundsReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.TickOutOfBounds.selector, int24(887273)));
        harness.getSqrtRatioAtTick(887273);

        vm.expectRevert(abi.encodeWithSelector(PoolErrors.TickOutOfBounds.selector, int24(-887273)));
        harness.getSqrtRatioAtTick(-887273);
    }

    function test_tickRoundTrip() public view {
        int24[7] memory testTicks = [int24(-887272), -50000, -100, 0, 100, 50000, 887272];
        for (uint256 i = 0; i < testTicks.length; i++) {
            int24 originalTick = testTicks[i];
            uint160 sqrtRatio = harness.getSqrtRatioAtTick(originalTick);
            int24 derivedTick = harness.getTickAtSqrtRatio(sqrtRatio);
            assertEq(derivedTick, originalTick);
        }
    }
}
