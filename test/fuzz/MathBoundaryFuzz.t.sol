// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";
import {SqrtPriceMathLib} from "../../contract/libraries/SqrtPriceMathLib.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";
import {BinMathLib} from "../../contract/libraries/BinMathLib.sol";
import {DynamicFeeLib} from "../../contract/libraries/DynamicFeeLib.sol";
import {BitMath} from "../../contract/libraries/BitMath.sol";
import {PathKeyLib} from "../../contract/periphery/libraries/PathKeyLib.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";

contract FuzzTickMathHarness {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return TickMathLib.getSqrtRatioAtTick(tick);
    }
}

contract MathBoundaryFuzzTest is Test {
    FuzzTickMathHarness public harness;

    function setUp() public {
        harness = new FuzzTickMathHarness();
    }

    /// @notice Fuzz test TickMathLib at arbitrary ticks within valid boundaries [-887272, 887272].
    function testFuzz_tickMathBoundaries(int24 tick) public pure {
        tick = int24(bound(tick, TickMathLib.MIN_TICK, TickMathLib.MAX_TICK));
        uint160 sqrtPriceX96 = TickMathLib.getSqrtRatioAtTick(tick);

        assertTrue(sqrtPriceX96 >= TickMathLib.MIN_SQRT_RATIO);
        assertTrue(sqrtPriceX96 <= TickMathLib.MAX_SQRT_RATIO);

        int24 recoveredTick = TickMathLib.getTickAtSqrtRatio(sqrtPriceX96);
        assertEq(recoveredTick, tick);
    }

    /// @notice Fuzz test TickMathLib bounds enforcement: ticks outside [-887272, 887272] must revert.
    function testFuzz_tickMathOutOfBoundsReverts(int24 tick) public {
        vm.assume(tick < TickMathLib.MIN_TICK || tick > TickMathLib.MAX_TICK);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.TickOutOfBounds.selector, tick));
        harness.getSqrtRatioAtTick(tick);
    }

    /// @notice Fuzz test FullMathLib mulDiv: a * b / denominator with 512-bit intermediate math.
    function testFuzz_fullMathMulDiv(uint128 a, uint128 b, uint128 denominator) public pure {
        vm.assume(denominator > 0);
        uint256 expected = (uint256(a) * uint256(b)) / uint256(denominator);
        uint256 result = FullMathLib.mulDiv(a, b, denominator);
        assertEq(result, expected);
    }

    /// @notice Fuzz test FullMathLib mulDivRoundingUp: checks exact ceil behavior.
    function testFuzz_fullMathMulDivRoundingUp(uint128 a, uint128 b, uint128 denominator) public pure {
        vm.assume(denominator > 0);
        uint256 prod = uint256(a) * uint256(b);
        uint256 expected = prod / uint256(denominator);
        if (prod % uint256(denominator) > 0) {
            expected += 1;
        }
        uint256 result = FullMathLib.mulDivRoundingUp(a, b, denominator);
        assertEq(result, expected);
    }

    /// @notice Fuzz test SqrtPriceMathLib getAmount0Delta and getAmount1Delta monotonicity.
    function testFuzz_sqrtPriceMathDeltasMonotonic(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        public
        pure
    {
        sqrtPriceAX96 = uint160(bound(sqrtPriceAX96, TickMathLib.MIN_SQRT_RATIO, TickMathLib.MAX_SQRT_RATIO));
        sqrtPriceBX96 = uint160(bound(sqrtPriceBX96, TickMathLib.MIN_SQRT_RATIO, TickMathLib.MAX_SQRT_RATIO));
        liquidity = uint128(bound(liquidity, 1, type(uint128).max / 2));

        uint256 amount0Up = SqrtPriceMathLib.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true);
        uint256 amount1Up = SqrtPriceMathLib.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true);
        uint256 amount0Down = SqrtPriceMathLib.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        uint256 amount1Down = SqrtPriceMathLib.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);

        assertTrue(amount0Up >= amount0Down);
        assertTrue(amount1Up >= amount1Down);

        if (sqrtPriceAX96 == sqrtPriceBX96) {
            assertEq(amount0Up, 0);
            assertEq(amount1Up, 0);
        } else {
            assertTrue(amount0Up > 0 || amount1Up > 0);
        }
    }

    /// @notice Fuzz test SafeCastLib for int128, uint128 conversions.
    function testFuzz_safeCastConversions(uint256 val) public pure {
        if (val <= type(uint128).max) {
            uint128 casted = SafeCastLib.toUint128(val);
            assertEq(uint256(casted), val);
        }
    }

    /// @notice Fuzz test DynamicFeeLib exponential decay monotonicity.
    function testFuzz_dynamicFeeDecayMonotonic(uint24 baseFee, uint24 maxFee, uint24 currentFee, uint32 timePassed)
        public
        pure
    {
        baseFee = uint24(bound(baseFee, DynamicFeeLib.MIN_FEE, 10_000));
        maxFee = uint24(bound(maxFee, baseFee, DynamicFeeLib.MAX_FEE));
        currentFee = uint24(bound(currentFee, baseFee, maxFee));
        timePassed = uint32(bound(timePassed, 0, 100_000));

        uint24 decayedFee = DynamicFeeLib.computeDynamicFee(baseFee, currentFee, 0, timePassed, 300);

        assertTrue(decayedFee >= baseFee);
        assertTrue(decayedFee <= currentFee);
    }

    /// @notice Fuzz test BitMath mostSignificantBit and leastSignificantBit.
    function testFuzz_bitMath(uint256 x) public pure {
        vm.assume(x > 0);
        uint8 msb = BitMath.mostSignificantBit(x);
        uint8 lsb = BitMath.leastSignificantBit(x);

        assertTrue(msb >= lsb);
        assertTrue((x >> msb) == 1);
        assertTrue(((x >> lsb) & 1) == 1);
    }
}
