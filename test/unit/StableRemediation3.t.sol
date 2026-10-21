// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";

contract R3DecToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

contract R3Guardians {
    mapping(address => bool) public isGuardian;

    function set(address g) external {
        isGuardian[g] = true;
    }
}

/// TEST-ONLY: lets a test place the pool at an arbitrary (e.g. already-out-of-bound) reserve state, which in
/// production is only reachable through proportional-remove rounding at the boundary.
contract StableReserveHarness is StableAMMEngine {
    constructor(address pm) StableAMMEngine(pm) {}

    function setReserves(PoolKey memory key, uint256 r0, uint256 r1) external {
        pools[key.toId()].reserve0 = r0;
        pools[key.toId()].reserve1 = r1;
    }
}

/// @notice Remediation-3 (Edith review 2026-10-21): conditions 1 (exact-out overflow), 5 (creator-chosen A,
///         ADR-0007 rev. 2), 6 (stopRampA only while ramping), 7 (imbalance-reducing swaps past the bound).
///         The test contract is the engine's PoolManager (owner() / circuitBreaker()).
contract StableRemediation3Test is Test {
    StableReserveHarness internal engine;
    R3Guardians public circuitBreaker;
    address public owner = address(this);
    address internal constant GUARDIAN = address(0x6A);
    uint160 internal constant SQRT_1_1 = uint160(1 << 96);

    function setUp() public {
        vm.warp(1_700_000_000);
        circuitBreaker = new R3Guardians();
        circuitBreaker.set(GUARDIAN);
        engine = new StableReserveHarness(address(this));
    }

    function _key(uint8 d0, uint8 d1) internal returns (PoolKey memory k) {
        address t0 = address(new R3DecToken(d0));
        address t1 = address(new R3DecToken(d1));
        if (t0 > t1) (t0, t1) = (t1, t0);
        k = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 400, 1, address(0), CurveType.STABLE_AMM);
    }

    /// Initialises at the peg in raw units: raw price = 10^(dec1 - dec0) (decimals 6 or 18 only).
    function _init(PoolKey memory k, uint256 a) internal {
        uint8 d0 = R3DecToken(Currency.unwrap(k.currency0)).decimals();
        uint8 d1 = R3DecToken(Currency.unwrap(k.currency1)).decimals();
        uint160 sqrtP = SQRT_1_1;
        if (d1 > d0) sqrtP = uint160(uint256(1e6) << 96);
        else if (d0 > d1) sqrtP = uint160((uint256(1) << 96) / 1e6);
        engine.initialize(k, sqrtP, abi.encode(a));
    }

    function _add(PoolKey memory k, int256 shares) internal returns (BalanceDelta d) {
        (d,) = engine.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, shares, bytes32(0)), address(this));
    }

    function extSwap(PoolKey memory k, bool z, int256 amt) external returns (BalanceDelta d) {
        (d,) = engine.swap(k, IPoolManager.SwapParams(z, amt, 0), k.fee, 0);
    }

    function _wide() internal {
        engine.setAmplificationRange(1, 10_000);
    }

    // ================================================================== condition 1 / Edith G-1, 8-A

    /// Deterministic regression for Edith's counterexample (fuzz seed 0x27b4e2a0…ecdf9, run 1):
    /// testFuzz_015_noSolverFreeze(aSeed=5879, amtSeed=999999999999999999999999, zeroForOne=false, exactIn=false)
    /// panicked with 0x11. It must now revert with the classified bound error, never a panic.
    function test_r3_edithCounterexample_exactOutNearFullReserve() public {
        _wide();
        PoolKey memory k = _key(18, 18);
        uint256 a = bound(uint256(5879), 1, 10_000);
        _init(k, a);
        _add(k, 1_000_000 ether);
        uint256 amt = bound(uint256(999999999999999999999999), 1e6, 50_000_000 ether);
        assertEq(amt, 999999999999999999999999, "bound() leaves the counterexample unchanged");
        (uint256 r0, uint256 r1) = engine.getReserves(k.toId());
        // zeroForOne = false, exact-out: take ~all token0, leaving 1e24 - amt = 1 wei.
        uint256 outAfter = r0 - amt;
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableImbalanceExceeded.selector, r1, outAfter, 10_000));
        this.extSwap(k, false, -int256(amt));
    }

    /// Exact output of the whole reserve or more, and absurd int256 magnitudes, are classified (no panic).
    function test_r3_extremeAmountsClassified() public {
        PoolKey memory k = _key(6, 18);
        _init(k, 100);
        _add(k, 1_000_000 ether);
        (uint256 r0, uint256 r1) = engine.getReserves(k.toId());
        vm.expectRevert(PoolErrors.InsufficientLiquidity.selector);
        this.extSwap(k, true, -int256(r1));
        vm.expectRevert(PoolErrors.InsufficientLiquidity.selector);
        this.extSwap(k, false, -int256(r0));
        vm.expectRevert(PoolErrors.InsufficientLiquidity.selector);
        this.extSwap(k, true, -type(int256).max);
        // exact-in larger than the per-side cap: rejected before amount * rate can overflow
        bytes memory err;
        try this.extSwap(k, true, type(int256).max) {
            revert("must revert");
        } catch (bytes memory e) {
            err = e;
        }
        assertEq(bytes4(err), PoolErrors.StableImbalanceExceeded.selector);
        try this.extSwap(k, false, type(int256).max) {
            revert("must revert");
        } catch (bytes memory e) {
            err = e;
        }
        assertEq(bytes4(err), PoolErrors.StableImbalanceExceeded.selector);
    }

    /// computeY far outside the supported domain reverts with the classified error (was: overflow panic).
    function test_r3_solverDomainGuard() public view {
        uint256 d = engine.computeD(1e24, 1e24, 1);
        // newX = 1 wei with D ~ 2e24: far beyond SOLVER_DOMAIN_RATIO
        try engine.computeY(1, 1e24, 1e24, 1) {
            revert("must revert");
        } catch (bytes memory e) {
            assertEq(bytes4(e), PoolErrors.StableImbalanceExceeded.selector);
        }
        assertGt(d, 0);
        // inside the domain it still solves
        assertGt(engine.computeY(1e20, 1e24, 1e24, 1), 0);
    }

    /// Edith 8-C: widened convergence fuzz. A in [1, 10_000] (optionally mid-ramp), normalised reserves up to 1e34,
    /// ratio up to the bound, both decimal mixes, both directions, exact in / out. Every outcome is success with a
    /// non-decreasing invariant or one of the documented errors — never a panic, never StableMathNotConverged.
    struct FuzzCase {
        PoolKey k;
        uint256 r0;
        uint256 r1;
        uint256 vpBefore;
    }

    /// flags: bit0 zeroForOne, bit1 exactIn, bit2 mixed 6/18 decimals, bit3 token0 is the high side, bit4 ramp
    function testFuzz_r3_015_widenedNoSolverFreeze(
        uint32 aSeeds,
        uint256 sizeSeed,
        uint16 ratioSeed,
        uint256 amtSeed,
        uint8 flags
    ) public {
        FuzzCase memory c = _placeFuzzPool(aSeeds, sizeSeed, ratioSeed, flags);
        if (c.r0 == 0) return; // degenerate placement (classified by the view) - nothing to swap
        bool zeroForOne = flags & 1 != 0;
        bool exactIn = flags & 2 != 0;
        uint256 base = zeroForOne == exactIn ? (zeroForOne ? c.r0 : c.r1) : (zeroForOne ? c.r1 : c.r0);
        uint256 amt = bound(amtSeed, 1, base * 2 + 1);
        int256 spec = exactIn ? int256(amt) : -int256(amt);
        try this.extSwap(c.k, zeroForOne, spec) {
            assertGe(engine.getVirtualPrice(c.k.toId()) + 1, c.vpBefore, "virtual price never drops");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == PoolErrors.StableImbalanceExceeded.selector || sel == PoolErrors.InsufficientLiquidity.selector
                    || sel == PoolErrors.ZeroSwapAmount.selector,
                "unexpected revert"
            );
        }
    }

    function _placeFuzzPool(uint32 aSeeds, uint256 sizeSeed, uint16 ratioSeed, uint8 flags)
        internal
        returns (FuzzCase memory c)
    {
        _wide();
        c.k = flags & 4 != 0 ? _key(6, 18) : _key(18, 18);
        uint256 a = bound(aSeeds & 0xffff, 1, 10_000);
        _init(c.k, a);
        _add(c.k, 1_000_000 ether);
        _setFuzzReserves(c, sizeSeed, ratioSeed, flags & 8 != 0);
        if (c.r0 == 0) return c;
        if (flags & 16 != 0) _fuzzRamp(c.k, a, aSeeds);
        try engine.getVirtualPrice(c.k.toId()) returns (uint256 vp) {
            c.vpBefore = vp;
        } catch (bytes memory e) {
            // even a hand-placed state at the edge must classify, not panic
            assertEq(bytes4(e), PoolErrors.StableImbalanceExceeded.selector, "views classify");
            c.r0 = 0;
        }
    }

    function _setFuzzReserves(FuzzCase memory c, uint256 sizeSeed, uint16 ratioSeed, bool zeroHigh) internal {
        (uint256 rate0, uint256 rate1) = engine.getRates(c.k.toId());
        uint256 hi = bound(sizeSeed, 1e21, 1e34);
        uint256 lo = hi / bound(ratioSeed, 1, 10_000);
        c.r0 = (zeroHigh ? hi : lo) / rate0;
        c.r1 = (zeroHigh ? lo : hi) / rate1;
        if (c.r0 == 0 || c.r1 == 0) {
            c.r0 = 0;
            return;
        }
        engine.setReserves(c.k, c.r0, c.r1);
    }

    function _fuzzRamp(PoolKey memory k, uint256 a, uint32 aSeeds) internal {
        uint256 target = bound(aSeeds >> 16, a > 10 ? a / 10 + 1 : 1, a * 10 > 10_000 ? 10_000 : a * 10);
        uint256 t = vm.getBlockTimestamp() + 1 days;
        vm.warp(t);
        engine.rampA(k, target, t + 10 days);
        vm.warp(t + (10 days * (uint256(aSeeds >> 24) % 100)) / 100);
    }

    // ================================================================== condition 7 / Edith 8-B

    function _pastBound(PoolKey memory k) internal {
        _init(k, 100);
        _add(k, 1_000_000 ether);
        // token0 abundant beyond the bound: 12,000 : 1 (normalised, 18/18)
        engine.setReserves(k, 12_000e18, 1e18);
    }

    function test_r3_pastBound_reducingSwapAllowed() public {
        PoolKey memory k = _key(18, 18);
        _pastBound(k);
        // Add the scarce token1, take the abundant token0: strictly reduces imbalance (still > 10,000:1 after).
        BalanceDelta d = this.extSwap(k, false, int256(0.05e18));
        assertLt(d.amount0(), 0, "trader receives token0");
        (uint256 r0, uint256 r1) = engine.getReserves(k.toId());
        assertGt(r0 / r1, 10_000, "still outside the bound - allowed because it reduced the imbalance");
        assertLt(r0 * 1e18, 12_000e18 * r1, "ratio strictly reduced");
        // exact-out in the reducing direction also works
        this.extSwap(k, false, -int256(1e18));
    }

    function test_r3_pastBound_increasingSwapRejected() public {
        PoolKey memory k = _key(18, 18);
        _pastBound(k);
        bytes memory err;
        try this.extSwap(k, true, int256(1e18)) {
            revert("must revert");
        } catch (bytes memory e) {
            err = e;
        }
        assertEq(bytes4(err), PoolErrors.StableImbalanceExceeded.selector, "increasing an existing breach: rejected");
        try this.extSwap(k, true, -int256(0.01e18)) {
            revert("must revert");
        } catch (bytes memory e) {
            err = e;
        }
        assertEq(bytes4(err), PoolErrors.StableImbalanceExceeded.selector);
    }

    /// Inside the bound the rule is unchanged: a swap may not take the pool beyond 10,000:1.
    function test_r3_insideBound_cannotCrossBound() public {
        PoolKey memory k = _key(18, 18);
        _init(k, 100);
        _add(k, 1_000_000 ether);
        engine.setReserves(k, 9_990e18, 1e18);
        bytes memory err;
        try this.extSwap(k, true, int256(100e18)) {
            revert("must revert");
        } catch (bytes memory e) {
            err = e;
        }
        assertEq(bytes4(err), PoolErrors.StableImbalanceExceeded.selector);
        assertEq(engine.MAX_IMBALANCE_RATIO(), 10_000, "fixed, ungoverned constant");
    }

    // ================================================================== condition 6 / Edith 7-B

    function test_r3_stopRampA_onlyWhileRampActive() public {
        PoolKey memory k = _key(18, 18);
        _init(k, 100);
        _add(k, 1_000_000 ether);
        // no ramp yet: neither guardian nor governance can "stop" (which would reset initialATime)
        (,,,, uint256 futureTime) = engine.getAmplification(k.toId());
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableNoActiveRamp.selector, futureTime));
        engine.stopRampA(k);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableNoActiveRamp.selector, futureTime));
        engine.stopRampA(k);
        // governance ramps; guardian can stop while active
        uint256 t0 = vm.getBlockTimestamp() + 1 days;
        vm.warp(t0);
        engine.rampA(k, 200, t0 + 2 days);
        vm.warp(t0 + 1 days);
        vm.prank(GUARDIAN);
        engine.stopRampA(k);
        assertEq(engine.getA(k.toId()), 150);
        // after the stop there is no active ramp again
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableNoActiveRamp.selector, t0 + 1 days));
        engine.stopRampA(k);
        // a completed ramp is also not stoppable
        vm.warp(t0 + 2 days);
        engine.rampA(k, 300, t0 + 4 days);
        vm.warp(t0 + 4 days);
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableNoActiveRamp.selector, t0 + 4 days));
        engine.stopRampA(k);
    }

    /// The guardian griefing scenario Edith described can no longer block governance: daily stop attempts revert
    /// and governance's next ramp goes through.
    function test_r3_guardianCannotBlockGovernanceRamps() public {
        PoolKey memory k = _key(18, 18);
        _init(k, 100);
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i; i < 3; i++) {
            t += 1 days;
            vm.warp(t);
            vm.prank(GUARDIAN);
            vm.expectRevert();
            engine.stopRampA(k);
        }
        engine.rampA(k, 500, t + 1 days);
        assertEq(engine.getA(k.toId()), 100);
    }

    // ================================================================== condition 5 / ADR-0007 rev. 2

    function test_r3_initialA_defaultsAndRange() public {
        assertEq(engine.minA(), 10);
        assertEq(engine.maxA(), 5_000);
        assertEq(engine.DEFAULT_A(), 100);
        PoolKey memory k = _key(18, 18);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidAmplification.selector, 9));
        engine.initialize(k, SQRT_1_1, abi.encode(uint256(9)));
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidAmplification.selector, 5_001));
        engine.initialize(k, SQRT_1_1, abi.encode(uint256(5_001)));
        vm.expectEmit(true, false, false, true, address(engine));
        emit StableAMMEngine.StableAInitialized(k.toId(), 10 * 100);
        engine.initialize(k, SQRT_1_1, abi.encode(uint256(10)));
        (uint256 cur, uint256 ini, uint256 futA,,) = engine.getAmplification(k.toId());
        assertEq(cur, 1_000);
        assertEq(ini, 1_000);
        assertEq(futA, 1_000);
        PoolKey memory k2 = _key(18, 18);
        _init(k2, 5_000);
        assertEq(engine.getA(k2.toId()), 5_000);
    }

    function test_r3_initParamsAndSpacingValidation() public {
        PoolKey memory k = _key(18, 18);
        k.tickSpacing = 100;
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.InvalidTickSpacing.selector, int24(100)));
        engine.initialize(k, SQRT_1_1, abi.encode(uint256(100)));
        k.tickSpacing = 1;
        vm.expectRevert(PoolErrors.InvalidInitParams.selector);
        engine.initialize(k, SQRT_1_1, "");
        vm.expectRevert(PoolErrors.InvalidInitParams.selector);
        engine.initialize(k, SQRT_1_1, abi.encode(uint256(100), uint256(1)));
        _init(k, 100);
    }

    function test_r3_setAmplificationRange_governanceOnlyAndBounded() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PoolErrors.NotGovernance.selector);
        engine.setAmplificationRange(1, 10_000);
        vm.prank(GUARDIAN);
        vm.expectRevert(PoolErrors.NotGovernance.selector);
        engine.setAmplificationRange(1, 10_000);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidARange.selector, 0, 100));
        engine.setAmplificationRange(0, 100);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidARange.selector, 1, 10_001));
        engine.setAmplificationRange(1, 10_001);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidARange.selector, 200, 100));
        engine.setAmplificationRange(200, 100);
        vm.expectEmit(false, false, false, true, address(engine));
        emit StableAMMEngine.AmplificationRangeSet(50, 500);
        engine.setAmplificationRange(50, 500);
        // existing pools are unaffected; new pools obey the new range
        PoolKey memory k = _key(18, 18);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableInvalidAmplification.selector, 49));
        engine.initialize(k, SQRT_1_1, abi.encode(uint256(49)));
        _init(k, 50);
    }

    /// Same pair + fee + plugin => exactly one STABLE pool (A no longer fragments pool identity).
    function test_r3_onePoolPerPairFeePlugin() public {
        PoolKey memory k = _key(18, 18);
        _init(k, 100);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PoolAlreadyInitialized.selector, k.toId()));
        engine.initialize(k, SQRT_1_1, abi.encode(uint256(200)));
    }

    // ------------------------------------------------------------------ exact root bracket for computeD

    /// @dev h(D) = 4xy(4A(x+y) - (4A-1)D) - D^3 is strictly decreasing near the root and h(root) = 0 (Curve n=2).
    function _h(uint256 x, uint256 y, uint256 A, uint256 D) internal pure returns (int256) {
        return int256(4 * x * y) * (int256(4 * A * (x + y)) - int256(4 * A - 1) * int256(D)) - int256(D) ** 3;
    }

    /// @notice Stronger than the Jexi residual check: D is never below floor(root) and at most 2 wei above it
    ///         (trader-adverse: a larger D yields a larger post-swap y). Python reference over 200k cases:
    ///         D = floor(root) 98.3%, +1 1.7%, +2 0.001%.
    function testFuzz_computeD_isFloorOfRoot(uint256 x, uint256 y, uint256 A) public view {
        x = bound(x, 1e6, 1e23);
        y = bound(y, x / 1000 + 1, x * 1000 > 1e23 ? 1e23 : x * 1000);
        A = bound(A, 1, 10_000);
        uint256 D;
        try engine.computeD(x, y, A) returns (uint256 d_) {
            D = d_;
        } catch {
            return; // non-convergence is a named revert (covered by the liveness tests)
        }
        assertLt(_h(x, y, A, D + 1), 0, "D >= floor(root)");
        assertGe(_h(x, y, A, D - 2), 0, "D <= floor(root) + 2");
    }

    function test_computeD_seedCounterexample_isExactFloor() public view {
        uint256 D = engine.computeD(1e6, 1004, 1);
        assertEq(D, 236_515, "floor of the true root 236515.563");
        assertGe(_h(1e6, 1004, 1, D), 0);
        assertLt(_h(1e6, 1004, 1, D + 1), 0);
    }
}
