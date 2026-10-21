// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";
import {BinMathLib} from "../../contract/libraries/BinMathLib.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";

/// @notice Remediation-2 Issue 1 (ADR-0006): real multi-bin engine — price moves bin to bin.
contract BinAMMEngineTest is Test {
    using Slot0Library for Slot0;

    BinAMMEngine public engine;
    PoolKey public key;
    PoolId internal pid;
    uint160 internal constant SQRT_1_1 = uint160(1 << 96);

    function setUp() public {
        engine = new BinAMMEngine(address(this));
        key = _key(10);
        pid = key.toId();
    }

    function _key(int24 step) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: step,
            plugin: address(0),
            curveType: CurveType.BIN_AMM
        });
    }

    function _modify(int24 lo, int24 hi, int256 shares, bytes32 salt)
        internal
        returns (BalanceDelta d, BalanceDelta fees)
    {
        (d, fees) = engine.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: shares, salt: salt}),
            address(this)
        );
    }

    function _swap(bool zeroForOne, int256 amount, uint160 limit) internal returns (BalanceDelta d) {
        (d,) = engine.swap(
            key, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}), key.fee, 0
        );
    }

    function extSwap(bool zeroForOne, int256 amount, uint160 limit) external returns (BalanceDelta) {
        return _swap(zeroForOne, amount, limit);
    }

    // ------------------------------------------------------------------ pricing

    function test_initializeAtPriceOne() public {
        engine.initialize(key, SQRT_1_1);
        assertEq(engine.getActiveBinId(pid), 0);
        assertEq(engine.getSlot0(pid).tick(), 0);
        assertEq(engine.getSlot0(pid).sqrtPriceX96(), SQRT_1_1);
    }

    function testFuzz_priceStepIsBinStep(int24 idSeed, uint8 stepSeed) public view {
        uint16 step = uint16(bound(stepSeed, 1, 200));
        int256 maxId = int256(860_000 / uint256(step));
        int24 id = int24(bound(int256(idSeed), -maxId, maxId));
        uint256 p0 = engine.getPriceFromId(id, step);
        uint256 p1 = engine.getPriceFromId(id + 1, step);
        // p1 / p0 == 1 + step/1e4. Q128 rounding is relative (~1e-12) for normal prices and absolute (a few units
        // of 2^-128) for prices near the bottom of the range.
        assertApproxEqAbs(FullMathLib.mulDiv(p1, 10_000, 10_000 + uint256(step)), p0, p0 / 1e9 + 4);
    }

    function testFuzz_idFromPriceInverse(int24 idSeed, uint8 stepSeed) public view {
        uint16 step = uint16(bound(stepSeed, 1, 200));
        int24 id = int24(bound(int256(idSeed), -50_000 / int256(uint256(step)), 50_000 / int256(uint256(step))));
        uint256 p = engine.getPriceFromId(id, step);
        assertEq(engine.getIdFromPrice(p, step), id);
        if (p > 1) assertEq(engine.getIdFromPrice(p - 1, step), id - 1);
    }

    function test_invalidBinStepRejected() public {
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.InvalidBinStep.selector, int24(0)));
        engine.initialize(_key(0), SQRT_1_1);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.InvalidBinStep.selector, int24(201)));
        engine.initialize(_key(201), SQRT_1_1);
    }

    // ------------------------------------------------------------------ liquidity distribution

    function test_seedingComposition() public {
        engine.initialize(key, SQRT_1_1);
        (BalanceDelta d,) = _modify(-5, 5, 1000 ether, 0);
        assertGt(d.amount0(), 0);
        assertGt(d.amount1(), 0);
        for (int24 b = -5; b <= 5; b++) {
            (uint128 r0, uint128 r1) = engine.getBinReserves(pid, b);
            if (b > 0) assertTrue(r0 > 0 && r1 == 0, "above active: token0 only");
            if (b < 0) assertTrue(r0 == 0 && r1 == 1000 ether, "below active: token1 only");
            if (b == 0) assertTrue(r0 > 0 && r1 > 0, "active: both");
        }
        (uint256 q0, uint256 q1) = engine.quoteAddLiquidity(pid, -5, 5, 1000 ether);
        assertEq(q0, uint256(int256(d.amount0())), "quote == second add (same proportions)");
        assertEq(q1, uint256(int256(d.amount1())));
    }

    function test_rangeGuards() public {
        engine.initialize(key, SQRT_1_1);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.TicksMisordered.selector, int24(5), int24(-5)));
        _modify(5, -5, 1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.BinRangeTooWide.selector, int24(0), int24(64), uint256(64)));
        _modify(0, 64, 1 ether, 0);
        _modify(0, 63, 1 ether, 0); // exactly 64 bins is allowed
    }

    // ------------------------------------------------------------------ Issue 1: price moves across bins

    function test_swapMovesPriceAcrossBins() public {
        engine.initialize(key, SQRT_1_1);
        _modify(-10, 10, 100 ether, 0);
        uint160 p0 = engine.getSlot0(pid).sqrtPriceX96();
        // sell ~5 bins' worth of token1 liquidity
        BalanceDelta d = _swap(true, 500 ether, 0);
        int24 active = engine.getActiveBinId(pid);
        assertLe(active, -4, "price moved down several bins");
        assertLt(engine.getSlot0(pid).sqrtPriceX96(), p0, "slot0 price moved");
        assertEq(engine.getSlot0(pid).tick(), active);
        // Output < input at price <= 1 (worse price each bin + fee)
        assertLt(uint256(uint128(-d.amount1())), 500 ether);
        // buy back: price moves up again
        _swap(false, 600 ether, 0);
        assertGt(engine.getActiveBinId(pid), active);
    }

    function test_exactOutputAcrossBins() public {
        engine.initialize(key, SQRT_1_1);
        _modify(-10, 10, 100 ether, 0);
        BalanceDelta d = _swap(true, -int256(350 ether), 0);
        assertEq(-d.amount1(), int128(int256(350 ether)), "exact output delivered");
        assertGt(d.amount0(), int128(int256(350 ether)), "paid more than 1:1 (worse bins + fee)");
    }

    function test_priceLimitStopsTraversal() public {
        engine.initialize(key, SQRT_1_1);
        _modify(-10, 10, 100 ether, 0);
        uint160 limit = uint160(BinMathLib.priceX128ToSqrtPriceX96(engine.getPriceFromId(-3, 10)));
        BalanceDelta d = _swap(true, 10_000 ether, limit);
        assertGe(engine.getActiveBinId(pid), -3, "never beyond the limit bin");
        assertGe(engine.getSlot0(pid).sqrtPriceX96(), limit);
        assertLt(d.amount0(), int128(int256(10_000 ether)), "partial fill");
        // a limit on the wrong side reverts
        uint160 cur = engine.getSlot0(pid).sqrtPriceX96();
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PriceLimitAlreadyExceeded.selector, cur, cur + 1));
        _swap(true, 1 ether, cur + 1);
    }

    /// Issue 7 analogue for bins: crossing a wide empty gap is O(1) (tree bitmap), not O(gap).
    function test_gapTraversalIsConstantGas() public {
        engine.initialize(key, SQRT_1_1);
        _modify(0, 0, 1 ether, 0);
        _modify(-1, -1, 1 ether, bytes32(uint256(1))); // adjacent
        uint256 g0 = gasleft();
        _swap(true, 1.5 ether, 0);
        uint256 nearGas = g0 - gasleft();

        BinAMMEngine e2 = new BinAMMEngine(address(this));
        PoolKey memory k2 = _key(1);
        e2.initialize(k2, SQRT_1_1);
        e2.modifyLiquidity(k2, IPoolManager.ModifyLiquidityParams(0, 0, 1 ether, 0), address(this));
        e2.modifyLiquidity(k2, IPoolManager.ModifyLiquidityParams(-200_000, -200_000, 1 ether, 0), address(this));
        g0 = gasleft();
        e2.swap(k2, IPoolManager.SwapParams(true, 1.5 ether, 0), k2.fee, 0);
        uint256 farGas = g0 - gasleft();
        assertEq(e2.getActiveBinId(k2.toId()), -200_000, "crossed a 200k-bin gap");
        emit log_named_uint("bin swap, adjacent bins gas", nearGas);
        emit log_named_uint("bin swap, 200k-bin gap gas", farGas);
        assertLt(farGas, nearGas + 60_000, "gap crossing cost independent of gap width");
    }

    function test_noLiquidityPartialFill() public {
        engine.initialize(key, SQRT_1_1);
        _modify(-2, 2, 1 ether, 0);
        BalanceDelta d = _swap(true, 1000 ether, 0);
        assertLt(d.amount0(), int128(int256(1000 ether)), "only the available liquidity is filled");
        (uint128 r0, uint128 r1) = engine.getBinReserves(pid, -2);
        assertEq(r1, 0);
        assertGt(r0, 0);
    }

    // ------------------------------------------------------------------ fees

    function test_feesAccrueOnlyToTradedBins() public {
        engine.initialize(key, SQRT_1_1);
        _modify(-3, 3, 100 ether, bytes32(uint256(1))); // spans traded bins
        _modify(20, 25, 100 ether, bytes32(uint256(2))); // far above: never traded by a sell
        _swap(true, 150 ether, 0);
        (, BalanceDelta feesA) = _modify(-3, 3, 0, bytes32(uint256(1)));
        (, BalanceDelta feesB) = _modify(20, 25, 0, bytes32(uint256(2)));
        assertGt(feesA.amount0(), 0, "traded range earns token0 fees");
        assertEq(feesB.amount0(), 0);
        assertEq(feesB.amount1(), 0);
        // fees are not double-paid
        (, BalanceDelta again) = _modify(-3, 3, 0, bytes32(uint256(1)));
        assertEq(again.amount0(), 0);
        // fee ~= 0.3% of input (single LP in the traded bins)
        assertApproxEqRel(uint256(int256(feesA.amount0())), 150 ether * 3 / 1000, 0.01e18);
    }

    // ------------------------------------------------------------------ accounting safety

    function testFuzz_addRemoveNeverProfits(uint96 shares, int16 lo, uint8 width, bool trade, uint96 amt) public {
        engine.initialize(key, SQRT_1_1);
        _modify(-20, 20, 10 ether, bytes32(uint256(9))); // background liquidity
        int24 l = int24(bound(int256(lo), -30, 30));
        int24 h = l + int24(uint24(bound(width, 0, 20)));
        uint256 s = bound(shares, 1, 1e30);
        (BalanceDelta inD,) = _modify(l, h, int256(s), 0);
        if (trade) {
            try this.extSwap(true, int256(bound(amt, 1e3, 50 ether)), 0) {} catch {}
            try this.extSwap(false, int256(bound(amt, 1e3, 50 ether)), 0) {} catch {}
        }
        (BalanceDelta outD, BalanceDelta fees) = _modify(l, h, -int256(s), 0);
        if (!trade) {
            assertLe(uint256(int256(-outD.amount0())), uint256(int256(inD.amount0())));
            assertLe(uint256(int256(-outD.amount1())), uint256(int256(inD.amount1())));
            assertEq(fees.amount0(), 0);
            assertEq(fees.amount1(), 0);
        }
    }

    function testFuzz_roundTripSwapNoProfit(uint96 amt) public {
        engine.initialize(key, SQRT_1_1);
        _modify(-30, 30, 100 ether, 0);
        uint256 a = bound(amt, 1e6, 2000 ether);
        BalanceDelta d1 = _swap(true, int256(a), 0);
        uint256 got = uint256(uint128(-d1.amount1()));
        if (got == 0) return;
        BalanceDelta d2 = _swap(false, int256(got), 0);
        assertLe(uint256(uint128(-d2.amount0())), uint256(int256(d1.amount0())), "no free lunch");
    }

    function test_removeMoreThanOwnedReverts() public {
        engine.initialize(key, SQRT_1_1);
        _modify(-1, 1, 1 ether, 0);
        vm.expectRevert(PoolErrors.LiquidityOverflow.selector);
        _modify(-1, 1, -int256(2 ether), 0);
    }

    /// ETH(18)/USDT(6)-style: ~3000 USDT per ETH → raw price ≈ 3e-9
    function test_binAMMUnequalDecimalsPricing() public {
        uint160 sqrtPriceX96 = uint160((_sqrt(3e9) << 96) / 1e9);
        PoolKey memory k = _key(25);
        engine.initialize(k, sqrtPriceX96);
        int24 activeId = engine.getActiveBinId(k.toId());
        assertLt(activeId, 0, "active bin below 0 for price << 1");
        uint256 p = engine.getPriceFromId(activeId, 25);
        // bin price within one step below the requested price
        uint256 target = BinMathLib.getPriceX128FromSqrtPriceX96(sqrtPriceX96);
        assertLe(p, target);
        assertGt(p * 10_025 / 10_000, target);

        engine.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(activeId - 5, activeId + 5, 1e10, 0), address(this));
        (BalanceDelta swapDelta,) =
            engine.swap(k, IPoolManager.SwapParams(false, int256(20e6), 0), k.fee, 0);
        uint256 ethOut = uint256(int256(-swapDelta.amount0()));
        assertGt(ethOut, 1e15, "20 USDT buys > 0.001 ETH at ~3000");
        assertLt(ethOut, 5e16);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
