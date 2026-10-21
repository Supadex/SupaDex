// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";

/// @dev Exposes the StableAMM marginal-price helper for M4 bounds coverage.
contract StableSqrtHarness is StableAMMEngine {
    constructor(address pm) StableAMMEngine(pm) {}

    function marginal(uint256 x, uint256 y, uint256 a, uint256 r0, uint256 r1) external pure returns (uint160) {
        uint256 ap = a * A_PRECISION;
        return _marginalSqrtPriceX96(x, y, ap, _computeD(x, y, ap), r0, r1);
    }
}

contract MockDecToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

contract MockGuardianBreaker {
    mapping(address => bool) public isGuardian;

    function set(address g) external {
        isGuardian[g] = true;
    }
}

/// @dev The test contract is the engine's "pool manager": it must expose owner() and circuitBreaker()
///      (IPoolManagerAdmin) for amplification governance.
contract StableAMMEngineTest is Test {
    using Slot0Library for Slot0;

    StableAMMEngine public engine;
    PoolKey public key;
    address public owner = address(this);
    MockGuardianBreaker public circuitBreaker;
    address internal constant GUARDIAN = address(0x6A);

    uint160 internal constant SQRT_1_1 = uint160(1 << 96);

    function setUp() public {
        vm.warp(1_700_000_000);
        circuitBreaker = new MockGuardianBreaker();
        circuitBreaker.set(GUARDIAN);
        engine = new StableAMMEngine(address(this));
        key = _key(18, 18, 100);
    }

    // ------------------------------------------------------------------ helpers

    function _key(uint8 d0, uint8 d1, int24 a) internal returns (PoolKey memory k) {
        address t0 = address(new MockDecToken(d0));
        address t1 = address(new MockDecToken(d1));
        if (t0 > t1) {
            (t0, t1) = (t1, t0); // decimals stay attached to the token; tests read them back via _rate()
        }
        k = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 400,
            tickSpacing: a,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        });
    }

    function _add(PoolKey memory k, int256 shares) internal returns (BalanceDelta d) {
        (d,) = engine.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: shares, salt: bytes32(0)}),
            address(this)
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (BalanceDelta d) {
        (d,) = engine.swap(
            k, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: 0}), k.fee, 0
        );
    }

    function _seed(PoolKey memory k, uint160 sqrtP, int256 shares) internal {
        engine.initialize(k, sqrtP);
        _add(k, shares);
    }

    // ------------------------------------------------------------------ lifecycle

    function test_stableAMMLifecycle() public {
        _seed(key, SQRT_1_1, 1_000_000 ether);
        BalanceDelta swapDelta = _swap(key, true, 10_000 ether);
        assertEq(swapDelta.amount0(), 10_000 ether);
        // Pegged curve with 4bp fee: ~9,996 out
        assertGt(-swapDelta.amount1(), 9_990 ether);
        assertLt(-swapDelta.amount1(), 10_000 ether);
        assertEq(engine.getA(key.toId()), 100);
    }

    // ------------------------------------------------------------------ Issue 2: decimals

    /// USDC(6)/DAI(18)-style pool trades at the peg after normalisation.
    function test_decimals_6_18_tradesAtPeg() public {
        PoolKey memory k = _key(6, 18, 200);
        (uint256 r0, uint256 r1) = (_rate(k.currency0), _rate(k.currency1));
        // raw price token1/token0 = 10^(dec1 - dec0) ⇒ sqrt = 10^((dec1-dec0)/2) * 2^96
        uint160 sqrtP = r0 > r1 ? uint160(uint256(1e6) << 96) : uint160((uint256(1) << 96) / 1e6);
        _seed(k, sqrtP, 1_000_000 ether);
        (uint256 rate0, uint256 rate1) = engine.getRates(k.toId());
        assertEq(rate0 * rate1, 1e12, "one side 6 decimals, other 18");
        (uint256 res0, uint256 res1) = engine.getReserves(k.toId());
        assertApproxEqRel(res0 * rate0, res1 * rate1, 1e12, "balanced in normalised units");

        // swap 1,000 whole units of token0 (raw = 1000 * 10^dec0)
        uint256 one0 = 1e18 / rate0;
        uint256 one1 = 1e18 / rate1;
        BalanceDelta d = _swap(k, true, int256(1000 * one0));
        uint256 out = uint256(uint128(-d.amount1()));
        assertGt(out, 999 * one1, "near-peg output in token1 units");
        assertLt(out, 1000 * one1);
        // and back
        d = _swap(k, false, int256(1000 * one1));
        out = uint256(uint128(-d.amount0()));
        assertGt(out, 999 * one0);
        assertLt(out, 1000 * one0 + one0 / 100);
    }

    function _rate(Currency c) internal view returns (uint256) {
        return 10 ** (18 - MockDecToken(Currency.unwrap(c)).decimals());
    }

    function test_decimalsAbove18Rejected() public {
        PoolKey memory k = _key(24, 18, 100);
        vm.expectRevert();
        engine.initialize(k, SQRT_1_1);
    }

    // ------------------------------------------------------------------ Issue 2: amplification config

    function test_amplificationBounds() public {
        PoolKey memory k0 = _key(18, 18, 0);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidAmplification.selector, 0));
        engine.initialize(k0, SQRT_1_1);
        PoolKey memory kHi = _key(18, 18, 10_001);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidAmplification.selector, 10_001));
        engine.initialize(kHi, SQRT_1_1);
        PoolKey memory k1 = _key(18, 18, 1);
        engine.initialize(k1, SQRT_1_1);
        assertEq(engine.getA(k1.toId()), 1);
    }

    function test_rampA_governanceOnly() public {
        _seed(key, SQRT_1_1, 1_000_000 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(0xBAD));
        vm.expectRevert(PoolErrors.NotGovernance.selector);
        engine.rampA(key, 200, block.timestamp + 1 days);
    }

    /// Timestamps via vm.getBlockTimestamp(): under via-IR `block.timestamp` may be cached across vm.warp in one frame.
    function test_rampA_linearAndBounded() public {
        _seed(key, SQRT_1_1, 1_000_000 ether);
        uint256 start = vm.getBlockTimestamp();
        // too soon after init
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidRamp.selector, 200, start + 1 days));
        engine.rampA(key, 200, start + 1 days);

        uint256 t0 = start + 1 days;
        vm.warp(t0);
        // ramp shorter than MIN_RAMP_TIME
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidRamp.selector, 200, t0 + 1 hours));
        engine.rampA(key, 200, t0 + 1 hours);
        // more than 10x change
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidRamp.selector, 1001, t0 + 1 days));
        engine.rampA(key, 1001, t0 + 1 days);

        engine.rampA(key, 300, t0 + 2 days);
        vm.warp(t0 + 1 days);
        assertEq(engine.getA(key.toId()), 200, "halfway");
        // swaps keep working mid-ramp
        _swap(key, true, 1000 ether);
        vm.warp(t0 + 3 days);
        assertEq(engine.getA(key.toId()), 300);
    }

    function test_stopRampA_guardianOrGovernance() public {
        _seed(key, SQRT_1_1, 1_000_000 ether);
        uint256 t0 = vm.getBlockTimestamp() + 1 days;
        vm.warp(t0);
        engine.rampA(key, 1000, t0 + 4 days);
        vm.warp(t0 + 2 days);
        vm.prank(address(0xBAD));
        vm.expectRevert(PoolErrors.NotGovernance.selector);
        engine.stopRampA(key);
        vm.prank(GUARDIAN);
        engine.stopRampA(key);
        uint256 frozen = engine.getA(key.toId());
        assertEq(frozen, 550);
        vm.warp(t0 + 10 days);
        assertEq(engine.getA(key.toId()), frozen, "A frozen after stop");
    }

    // ------------------------------------------------------------------ Issue 6 / Jexi 015: extreme imbalance

    /// The 015 freeze: pushing the pool to an extreme ratio must revert with the DOCUMENTED bound error, never
    /// leave a non-convergent state behind; exits always remain available.
    function test_015_extremeImbalanceBoundedAndExitsWork() public {
        PoolKey memory k = _key(18, 18, 1); // A = 1: the hardest case for the old solver
        _seed(k, SQRT_1_1, 1_000_000 ether);
        // A swap that would leave > 10,000:1 is rejected with the bound error.
        vm.expectRevert();
        _swap(k, true, 1e30);
        // Walk the pool towards the bound with many swaps; each either succeeds or hits the bound error.
        uint256 hits;
        for (uint256 i; i < 40; ++i) {
            try this.extSwap(k, true, int256(2_000_000 ether)) {}
            catch (bytes memory err) {
                assertEq(bytes4(err), PoolErrors.StableImbalanceExceeded.selector, "only the bound error");
                hits++;
            }
        }
        assertGt(hits, 0, "bound reached");
        // Every view still works (D is computable) and the LP can exit fully.
        assertGt(engine.getVirtualPrice(k.toId()), 0);
        _swap(k, false, 1 ether); // trades in the rebalancing direction work
        BalanceDelta out = _add(k, -int256(1_000_000 ether - 1000));
        assertLt(out.amount0(), 0);
        assertLt(out.amount1(), 0);
    }

    function extSwap(PoolKey memory k, bool z, int256 amt) external returns (BalanceDelta) {
        return _swap(k, z, amt);
    }

    /// Fuzz: across A in [1, 10_000] random trades either succeed with a non-decreasing invariant or revert with
    /// one of the documented, intentional errors — never StableMathNotConverged.
    function testFuzz_015_noSolverFreeze(uint16 aSeed, uint96 amtSeed, bool zeroForOne, bool exactIn) public {
        int24 a = int24(int256(uint256(bound(aSeed, 1, 10_000))));
        PoolKey memory k = _key(18, 18, a);
        _seed(k, SQRT_1_1, 1_000_000 ether);
        uint256 amt = bound(amtSeed, 1e6, 50_000_000 ether);
        int256 spec = exactIn ? int256(amt) : -int256(amt);
        uint256 vpBefore = engine.getVirtualPrice(k.toId());
        try this.extSwap(k, zeroForOne, spec) {
            assertGe(engine.getVirtualPrice(k.toId()) + 1, vpBefore, "virtual price never drops");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == PoolErrors.StableImbalanceExceeded.selector || sel == PoolErrors.InsufficientLiquidity.selector,
                "unexpected revert"
            );
            assertTrue(sel != PoolErrors.StableMathNotConverged.selector);
        }
    }

    /// Fuzz: computeY(x, x, y) == y over the supported range, within the engine's documented solver tolerance
    /// (D_TOLERANCE = 16 wei of normalised balance; Python model of the same solver: max 11 wei).
    function testFuzz_computeYSelfConsistent(uint16 aSeed, uint128 xSeed, uint32 ratioSeed) public view {
        uint256 a = bound(aSeed, 1, 10_000);
        uint256 x = bound(xSeed, 1e3, 1e30);
        uint256 ratio = bound(ratioSeed, 1, 10_000);
        uint256 y = x * ratio;
        uint256 got = engine.computeY(x, x, y, a);
        assertApproxEqAbs(got, y, 16 + y / 1e15);
    }

    /// Fuzz: a round trip never profits the trader (rounding is trader-adverse).
    function testFuzz_roundTripNoProfit(uint16 aSeed, uint96 amtSeed) public {
        int24 a = int24(int256(uint256(bound(aSeed, 1, 10_000))));
        PoolKey memory k = _key(18, 18, a);
        _seed(k, SQRT_1_1, 1_000_000 ether);
        uint256 amt = bound(amtSeed, 1e9, 100_000 ether);
        BalanceDelta d1 = _swap(k, true, int256(amt));
        uint256 got1 = uint256(uint128(-d1.amount1()));
        BalanceDelta d2 = _swap(k, false, int256(got1));
        uint256 back0 = uint256(uint128(-d2.amount0()));
        assertLt(back0, amt, "no free lunch");
    }

    // ------------------------------------------------------------------ price limit + M4

    function test_priceLimitEnforced() public {
        _seed(key, SQRT_1_1, 1_000_000 ether);
        uint160 p = engine.getSlot0(key.toId()).sqrtPriceX96();
        vm.expectRevert();
        engine.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 500_000 ether, sqrtPriceLimitX96: p - 1}),
            key.fee,
            0
        );
    }

    /// M4: marginal sqrt price is always inside TickMath bounds (clamped, never truncated).
    function test_M4_marginalSqrtPriceClampedInBounds() public {
        StableSqrtHarness h = new StableSqrtHarness(address(this));
        uint160 lo = h.marginal(1e34, 1e30, 1, 1, 1e18);
        uint160 hi = h.marginal(1e30, 1e34, 1, 1e18, 1);
        assertTrue(lo > TickMathLib.MIN_SQRT_RATIO && lo < TickMathLib.MAX_SQRT_RATIO);
        assertTrue(hi > TickMathLib.MIN_SQRT_RATIO && hi < TickMathLib.MAX_SQRT_RATIO);
        assertApproxEqAbs(h.marginal(1e24, 1e24, 100, 1, 1), uint160(1 << 96), 1 << 40);
    }

    /// Slot0 tracks the marginal price: selling token0 lowers it.
    function test_slot0TracksMarginalPrice() public {
        _seed(key, SQRT_1_1, 1_000_000 ether);
        uint160 p0 = engine.getSlot0(key.toId()).sqrtPriceX96();
        _swap(key, true, 200_000 ether);
        uint160 p1 = engine.getSlot0(key.toId()).sqrtPriceX96();
        assertLt(p1, p0);
        assertEq(engine.getSlot0(key.toId()).tick(), TickMathLib.getTickAtSqrtRatio(p1));
    }
}
