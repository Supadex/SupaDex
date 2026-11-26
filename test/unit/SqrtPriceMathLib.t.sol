// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqrtPriceMathLib} from "../../contract/libraries/SqrtPriceMathLib.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";
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

    /// I-04: small amounts still take the v3 shift path.
    function test_getNextSqrtPriceFromAmount1_add_smallAmount_usesShiftPath() public pure {
        uint160 sqrtPX96 = 1 << 96;
        uint128 liquidity = 1e18;
        uint256 amount = 1e6; // << type(uint160).max
        uint160 next = SqrtPriceMathLib.getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amount, true);
        assertEq(next, uint160(uint256(sqrtPX96) + (amount << 96) / liquidity));
    }

    /// I-04: the previously-unchecked path. amount = 2**170 > type(uint160).max, so the
    /// old `(amount << 96) / liquidity` truncated to 0 and returned sqrtPX96 unchanged.
    /// v3 parity requires the mulDiv fallback: quotient = 2**170 * 2**96 / 2**127 = 2**139.
    function test_getNextSqrtPriceFromAmount1_add_largeAmount_usesMulDivFallback() public pure {
        uint160 sqrtPX96 = 1 << 96;
        uint128 liquidity = uint128(2 ** 127);
        uint256 amount = 2 ** 170;
        uint160 next = SqrtPriceMathLib.getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amount, true);
        assertEq(next, uint160(uint256(sqrtPX96) + uint256(2 ** 139)), "mulDiv fallback quotient");
        assertTrue(next != sqrtPX96, "old truncated shift path would have returned the price unchanged");
        assertEq(
            next,
            uint160(uint256(sqrtPX96) + FullMathLib.mulDiv(amount, 1 << 96, liquidity)),
            "matches mulDiv reference"
        );
    }

    /// I-04 boundary: exactly type(uint160).max takes the shift path; max + 1 takes mulDiv.
    /// Both must agree with their reference formula and be monotone in amount.
    function test_getNextSqrtPriceFromAmount1_add_boundary_uint160Max() public pure {
        uint160 sqrtPX96 = 1 << 96;
        uint128 liquidity = uint128(2 ** 127);
        uint160 atMax = SqrtPriceMathLib.getNextSqrtPriceFromAmount1RoundingDown(
            sqrtPX96, liquidity, uint256(type(uint160).max), true
        );
        assertEq(
            atMax, uint160(uint256(sqrtPX96) + (uint256(type(uint160).max) << 96) / liquidity), "shift path at max"
        );
        uint160 aboveMax = SqrtPriceMathLib.getNextSqrtPriceFromAmount1RoundingDown(
            sqrtPX96, liquidity, uint256(type(uint160).max) + 1, true
        );
        assertEq(
            aboveMax,
            uint160(uint256(sqrtPX96) + FullMathLib.mulDiv(uint256(type(uint160).max) + 1, 1 << 96, liquidity)),
            "mulDiv path at max + 1"
        );
        assertTrue(aboveMax >= atMax, "price must be non-decreasing in amount");
    }

    /// I-04: the `add == false` branch was already v3-parity (mulDivRoundingUp); pin it.
    function test_getNextSqrtPriceFromAmount1_subBranchUnchanged() public pure {
        uint160 sqrtPX96 = 2 << 96;
        uint128 liquidity = 1e18;
        uint256 amount = 1e6;
        uint160 next = SqrtPriceMathLib.getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amount, false);
        assertEq(next, uint160(uint256(sqrtPX96) - FullMathLib.mulDivRoundingUp(amount, 1 << 96, liquidity)));
    }

    /// I-04 fuzz: for any amount, the add branch must equal the mulDiv reference
    /// (modulo the shared uint160 cast). Bounds keep the test honest without overflow.
    function testFuzz_getNextSqrtPriceFromAmount1_add_matchesMulDiv(uint256 amount, uint128 liquidity) public pure {
        liquidity = uint128(bound(uint256(liquidity), 2 ** 100, 2 ** 127));
        amount = bound(amount, 1, 2 ** 200);
        uint160 sqrtPX96 = 1 << 96;
        uint160 next = SqrtPriceMathLib.getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amount, true);
        assertEq(next, uint160(uint256(sqrtPX96) + FullMathLib.mulDiv(amount, 1 << 96, liquidity)), "mulDiv reference");
    }
}
