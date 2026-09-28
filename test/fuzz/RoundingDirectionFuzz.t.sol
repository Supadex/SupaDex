// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";
import {SqrtPriceMathLib} from "../../contract/libraries/SqrtPriceMathLib.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";

contract RoundingDirectionFuzzTest is Test {
    /// @notice Invariant: mulDivRoundingUp must always be >= mulDiv and diff <= 1.
    function testFuzz_fullMathRoundingCeilFloorDifference(uint128 a, uint128 b, uint128 d) public pure {
        vm.assume(d > 0);
        uint256 floorVal = FullMathLib.mulDiv(a, b, d);
        uint256 ceilVal = FullMathLib.mulDivRoundingUp(a, b, d);

        assertTrue(ceilVal >= floorVal);
        assertTrue(ceilVal - floorVal <= 1);
    }

    /// @notice Invariant: SqrtPriceMathLib getAmount0Delta with roundUp=true must always be >= roundUp=false.
    function testFuzz_amount0DeltaRoundingDirection(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        public
        pure
    {
        sqrtPriceAX96 = uint160(bound(sqrtPriceAX96, TickMathLib.MIN_SQRT_RATIO, TickMathLib.MAX_SQRT_RATIO));
        sqrtPriceBX96 = uint160(bound(sqrtPriceBX96, TickMathLib.MIN_SQRT_RATIO, TickMathLib.MAX_SQRT_RATIO));
        liquidity = uint128(bound(liquidity, 1, type(uint128).max / 4));

        uint256 amountDown = SqrtPriceMathLib.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        uint256 amountUp = SqrtPriceMathLib.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true);

        assertTrue(amountUp >= amountDown);
        if (sqrtPriceAX96 != sqrtPriceBX96) {
            assertTrue(amountUp - amountDown <= 1);
        }
    }

    /// @notice Invariant: SqrtPriceMathLib getAmount1Delta with roundUp=true must always be >= roundUp=false.
    function testFuzz_amount1DeltaRoundingDirection(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        public
        pure
    {
        sqrtPriceAX96 = uint160(bound(sqrtPriceAX96, TickMathLib.MIN_SQRT_RATIO, TickMathLib.MAX_SQRT_RATIO));
        sqrtPriceBX96 = uint160(bound(sqrtPriceBX96, TickMathLib.MIN_SQRT_RATIO, TickMathLib.MAX_SQRT_RATIO));
        liquidity = uint128(bound(liquidity, 1, type(uint128).max / 4));

        uint256 amountDown = SqrtPriceMathLib.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        uint256 amountUp = SqrtPriceMathLib.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true);

        assertTrue(amountUp >= amountDown);
        if (sqrtPriceAX96 != sqrtPriceBX96) {
            assertTrue(amountUp - amountDown <= 1);
        }
    }
}
