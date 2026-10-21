// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BinMathLib} from "../../contract/libraries/BinMathLib.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";

contract BinMathCaller {
    function price(int24 id, uint16 step) external pure returns (uint256) {
        return BinMathLib.getPriceFromSignedId(id, step);
    }
}

contract BinMathLibTest is Test {
    uint256 constant SCALE = 1 << 128;
    BinMathCaller c = new BinMathCaller();

    function test_binZeroPriceIsOne() public pure {
        for (uint16 s = 1; s <= 200; s += 33) {
            assertEq(BinMathLib.getPriceFromSignedId(0, s), SCALE);
        }
    }

    function test_knownPrices() public pure {
        assertEq(BinMathLib.getPriceFromSignedId(1, 25), SCALE + SCALE * 25 / 10_000);
        // (1.0025)^-1 * (1.0025) ~ 1 within rounding
        uint256 up = BinMathLib.getPriceFromSignedId(1, 25);
        uint256 dn = BinMathLib.getPriceFromSignedId(-1, 25);
        assertApproxEqRel(up * dn / SCALE, SCALE, 1e3);
    }

    function testFuzz_priceMonotoneAndReciprocal(int24 id, uint16 step) public pure {
        step = uint16(bound(step, BinMathLib.MIN_BIN_STEP, BinMathLib.MAX_BIN_STEP));
        int256 lim = int256(BinMathLib.MAX_ID_STEP_PRODUCT / step) - 1;
        id = int24(bound(int256(id), -lim, lim));
        uint256 p = BinMathLib.getPriceFromSignedId(id, step);
        uint256 pn = BinMathLib.getPriceFromSignedId(id + 1, step);
        assertGe(pn, p, "non-decreasing everywhere");
        // Strictly increasing whenever one bin step is representable (p * step / 1e4 >= 1). At the extreme low end
        // (raw price < ~1e-34) adjacent Q128 prices may coincide; such pools are economically meaningless.
        if (p >= 20_000) assertGt(pn, p, "strictly increasing");
        // Reciprocity p(id) * p(-id) ~ 1 holds to 1e-6 while the smaller price keeps >= 64 significant bits
        // (|id| * step <= 440_000 -> e^44 ~ 2^63.5). Near the outer bound Q128 has too few bits (documented).
        if (uint256(int256(id < 0 ? -id : id)) * step <= 440_000) {
            uint256 q = BinMathLib.getPriceFromSignedId(-id, step);
            assertApproxEqRel(FullMathLib.mulDiv(p, q, SCALE), SCALE, 1e12);
        }
    }

    function test_boundEdge() public {
        uint16 step = 200;
        int24 edge = int24(int256(BinMathLib.MAX_ID_STEP_PRODUCT / step));
        assertTrue(BinMathLib.isIdWithinBound(edge, step));
        assertTrue(BinMathLib.isIdWithinBound(-edge, step));
        assertFalse(BinMathLib.isIdWithinBound(edge + 1, step));
        assertFalse(BinMathLib.isIdWithinBound(-edge - 1, step));
        c.price(edge, step);
        c.price(-edge, step);
        vm.expectRevert(abi.encodeWithSelector(BinMathLib.BinIdBeyondPriceRange.selector, edge + 1, step));
        c.price(edge + 1, step);
        vm.expectRevert(abi.encodeWithSelector(BinMathLib.BinIdBeyondPriceRange.selector, -edge - 1, step));
        c.price(-edge - 1, step);
    }

    function test_sqrtConversions() public pure {
        assertEq(BinMathLib.getPriceX128FromSqrtPriceX96(0), 0);
        assertEq(BinMathLib.getPriceX128FromSqrtPriceX96(uint160(1 << 96)), SCALE);
        assertEq(BinMathLib.priceX128ToSqrtPriceX96(SCALE), 1 << 96);
        // high branch (price >= 2^192 in Q128, i.e. raw price >= 2^64)
        uint256 big = SCALE << 70;
        assertEq(BinMathLib.priceX128ToSqrtPriceX96(big), (1 << 96) << 35);
    }

    function testFuzz_sqrtRoundTrip(uint160 sp) public pure {
        sp = uint160(bound(sp, uint256(1) << 64, TickMathLib.MAX_SQRT_RATIO - 1)); // >= 64 bits of price precision
        uint256 p = BinMathLib.getPriceX128FromSqrtPriceX96(sp);
        uint256 back = BinMathLib.priceX128ToSqrtPriceX96(p);
        assertApproxEqRel(back, sp, 1e9); // 1e-9 relative
    }
}

