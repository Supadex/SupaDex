// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqrtPriceMathLib} from "../../contract/libraries/SqrtPriceMathLib.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";

contract SqrtPriceMathLibTest is Test {
    function test_getAmount0Delta() public pure {
        uint160 sqrtRatioA = TickMathLib.getSqrtRatioAtTick(0);
        uint160 sqrtRatioB = TickMathLib.getSqrtRatioAtTick(100);
        uint128 liquidity = 1e18;

        uint256 amount0 = SqrtPriceMathLib.getAmount0Delta(sqrtRatioA, sqrtRatioB, liquidity, false);
        assertTrue(amount0 > 0);
    }

    function test_getAmount1Delta() public pure {
        uint160 sqrtRatioA = TickMathLib.getSqrtRatioAtTick(0);
        uint160 sqrtRatioB = TickMathLib.getSqrtRatioAtTick(100);
        uint128 liquidity = 1e18;

        uint256 amount1 = SqrtPriceMathLib.getAmount1Delta(sqrtRatioA, sqrtRatioB, liquidity, false);
        assertTrue(amount1 > 0);
    }

    function test_zeroLiquidityReturnsZero() public pure {
        uint160 sqrtRatioA = TickMathLib.getSqrtRatioAtTick(0);
        uint160 sqrtRatioB = TickMathLib.getSqrtRatioAtTick(100);

        uint256 amount0 = SqrtPriceMathLib.getAmount0Delta(sqrtRatioA, sqrtRatioB, 0, false);
        uint256 amount1 = SqrtPriceMathLib.getAmount1Delta(sqrtRatioA, sqrtRatioB, 0, false);

        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }
}
