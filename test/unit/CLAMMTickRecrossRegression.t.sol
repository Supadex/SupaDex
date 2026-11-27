// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Regression tests for the CLAMM tick re-cross bug found by the KupiaSec
// hackwatch alert (25 Nov 2026) and fixed as an audit fix under the freeze
// rule (PR: fix/clamm-tick-recompute).
//
// Root cause: _applyStep recomputed state.currentTick from the price
// unconditionally, so a zero-movement step after a downward tick cross undid
// the cross (tick set to nextTick - 1), and _nextInitializedTick then found
// the same tick again, applying its liquidityNet a second time. Repeated
// 1-unit swaps inflated recorded pool liquidity with no position behind it
// (1,000,000 -> 7,000,000 in the PoC) and overpaid a later swap 2.76x.
//
// Fix (Uniswap v3 rule): the tick is set in exactly one place per step
// outcome in _swapStep — reached tick: cross and set as before; price moved
// but tick not reached: recompute from the new price; price unmoved: leave
// the tick unchanged.
// The test contract acts as the PoolManager (engine is onlyPoolManager-gated).

import {Test} from "forge-std/Test.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";

contract CLAMMTickRecrossRegression is Test {
    using Slot0Library for Slot0;

    CLAMMEngine public engine;
    PoolKey public key;
    PoolId public poolId;

    function setUp() public {
        engine = new CLAMMEngine(address(this));
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        poolId = key.toId();
    }

    function _mod(int24 lo, int24 hi, int128 l) internal {
        engine.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: l, salt: 0}),
            address(this)
        );
    }

    function _dustSwap() internal returns (BalanceDelta d) {
        (d,) = engine.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: TickMathLib.MIN_SQRT_RATIO + 1
            }),
            key.fee,
            0
        );
    }

    /// Sum of the liquidities of the positions that are in range at `tick`,
    /// for the two positions set up by the tests below:
    /// A [-120, 120] L=3,000,000 and B [120, 240] L=1,000,000.
    function _inRangeLiquidity(int24 tick) internal pure returns (uint128) {
        uint128 total;
        if (tick >= -120 && tick < 120) total += 3_000_000;
        if (tick >= 120 && tick < 240) total += 1_000_000;
        return total;
    }

    function _assertLiquidityInvariant() internal view {
        int24 tick = engine.getSlot0(poolId).tick();
        assertEq(
            engine.getLiquidity(poolId),
            _inRangeLiquidity(tick),
            "pool liquidity must equal sum of in-range position liquidities"
        );
    }

    /// A 1-unit zeroForOne swap at an initialized tick must cross the tick
    /// exactly once. Setup: price exactly at tick 120 (upper tick of A,
    /// lower tick of B). Tick 120 net = -3e6 (A upper) + 1e6 (B lower) =
    /// -2e6, so one downward crossing ADDS 2e6 to pool liquidity.
    function test_repeatedDustSwapDoesNotInflateLiquidity() public {
        engine.initialize(key, TickMathLib.getSqrtRatioAtTick(120), "");
        _mod(-120, 120, 3_000_000); // A: upper tick 120
        _mod(120, 240, 1_000_000); // B: lower tick 120
        // At tick 120 only B is in range.
        assertEq(engine.getLiquidity(poolId), 1_000_000, "pre: only B in range");

        for (uint256 i = 0; i < 3; i++) {
            _dustSwap();
            _assertLiquidityInvariant();
        }

        // Correct behaviour: ONE crossing of tick 120 (first swap) ->
        // L = 3,000,000, tick 119. The pre-fix bug crossed tick 120 three
        // times -> L = 7,000,000, tick stuck at 120.
        assertEq(engine.getLiquidity(poolId), 3_000_000, "liquidity after repeated dust swaps");
        assertEq(engine.getSlot0(poolId).tick(), 119, "stored tick after repeated dust swaps");
    }

    /// The same large swap must pay out the same amount from a dust-swapped
    /// pool as from an identical pool that was never dust-swapped.
    function test_dustSwappedPoolDoesNotOverpay() public {
        engine.initialize(key, TickMathLib.getSqrtRatioAtTick(120), "");
        _mod(-120, 120, 3_000_000);
        _mod(120, 240, 1_000_000);
        _dustSwap();
        _dustSwap();

        (BalanceDelta inflatedDelta,) = engine.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 100_000, sqrtPriceLimitX96: TickMathLib.MIN_SQRT_RATIO + 1
            }),
            key.fee,
            0
        );

        // Control pool: identical setup, no dust swaps.
        CLAMMEngine control = new CLAMMEngine(address(this));
        control.initialize(key, TickMathLib.getSqrtRatioAtTick(120), "");
        control.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 3_000_000, salt: 0}),
            address(this)
        );
        control.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: 120, tickUpper: 240, liquidityDelta: 1_000_000, salt: 0}),
            address(this)
        );
        (BalanceDelta controlDelta,) = control.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 100_000, sqrtPriceLimitX96: TickMathLib.MIN_SQRT_RATIO + 1
            }),
            key.fee,
            0
        );

        // Pre-fix, the dust-swapped pool paid 99,450 token1 vs 35,998 here.
        assertEq(-inflatedDelta.amount1(), -controlDelta.amount1(), "dust-swapped pool must not overpay");
    }

    /// Mirror-image direction: crossing a LOWER tick must happen once and
    /// must not brick the pool. Setup: price exactly at tick -120 (lower
    /// tick of A). Positions A [-120, 120] L=1,000,000 and B [-240, 120]
    /// L=1,000,000 — at tick -120 both are in range, L = 2,000,000.
    function test_lowerTickRecrossDoesNotRevert() public {
        engine.initialize(key, TickMathLib.getSqrtRatioAtTick(-120), "");
        _mod(-120, 120, 1_000_000); // A: lower tick -120
        _mod(-240, 120, 1_000_000); // B: lower tick -240
        assertEq(engine.getLiquidity(poolId), 2_000_000, "pre: A+B in range");

        _dustSwap(); // crosses -120 once: L = 1,000,000, tick -121
        assertEq(engine.getLiquidity(poolId), 1_000_000, "after 1st dust swap");
        assertEq(engine.getSlot0(poolId).tick(), -121, "tick after 1st dust swap");

        // Pre-fix, this second dust swap re-crossed -120 (L -> 0) and then
        // underflowed at -240, reverting the swap. Post-fix it is a
        // zero-movement step that leaves state unchanged.
        _dustSwap();
        assertEq(engine.getLiquidity(poolId), 1_000_000, "after 2nd dust swap");
        assertEq(engine.getSlot0(poolId).tick(), -121, "tick after 2nd dust swap");
    }

    /// Downward dust cross, then a oneForZero swap back across the same tick.
    /// The tick must be crossed once in each direction (liquidity 1e6 -> 3e6 -> 1e6),
    /// and a following downward dust swap must cross it once more rather than re-applying it.
    function test_boundaryReversalAfterDownwardDustCross() public {
        engine.initialize(key, TickMathLib.getSqrtRatioAtTick(120), "");
        _mod(-120, 120, 3_000_000);
        _mod(120, 240, 1_000_000);
        assertEq(engine.getLiquidity(poolId), 1_000_000, "pre: only B in range");

        _dustSwap();
        _assertLiquidityInvariant();
        assertEq(engine.getLiquidity(poolId), 3_000_000, "after downward cross");
        assertEq(engine.getSlot0(poolId).tick(), 119, "tick parked just below the boundary");

        (BalanceDelta back,) = engine.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: 1, sqrtPriceLimitX96: TickMathLib.MAX_SQRT_RATIO - 1
            }),
            key.fee,
            0
        );
        back;
        _assertLiquidityInvariant();
        assertEq(engine.getLiquidity(poolId), 1_000_000, "upward cross restores B-only liquidity");
        assertGe(engine.getSlot0(poolId).tick(), 120, "price is back on or above the boundary");

        // Stop inside A's range so the swap crosses tick 120 once and does not exit A at -120.
        (BalanceDelta down,) = engine.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 100_000, sqrtPriceLimitX96: TickMathLib.getSqrtRatioAtTick(0)
            }),
            key.fee,
            0
        );
        down;
        _assertLiquidityInvariant();
        assertEq(engine.getLiquidity(poolId), 3_000_000, "return cross applies tick 120 once");
        assertLt(engine.getSlot0(poolId).tick(), 120, "price is back below the boundary");
    }
}
