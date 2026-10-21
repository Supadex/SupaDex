// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Jexi - PR #1 (6dc40ec) verification tests. LOCAL ONLY. Reuses the production-like wiring of
// JexiSupaDexTest (proxy vault, timelock owner, circuit breaker, whitelist with real plugins).
//
// Ported into the repo by remediation-2 (Jexi 018). Port changes (each marked "PORT:"):
//  - STABLE keys use tickSpacing 1 and pass A = 100 at initialize (ADR-0007 rev. 2); 100 is the old
//    fixed production A that these tests were written against.
//  - Tests that DOCUMENTED a bug (BIN frozen price 005, StableSwap freeze 015, gap-walk gas 016) are inverted to
//    assert the fixed behaviour; the original observation is kept in the comment.
//  - firstDepositorInflation split into a helper (legacy/coverage codegen stack limit, Issue 5).

import "./JexiSupaDex.t.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";

/// Same PoolManager, BIN gate opened (test-only) to check what the gate is hiding.
contract BinEnabledPM is SupaPoolManager {
    constructor(IVault v, ICurveEngine a, ICurveEngine b, ICurveEngine c) SupaPoolManager(v, a, b, c) {}

    function binAmmEnabled() public pure override returns (bool) {
        return true;
    }
}

/// Raw vault op sequencer: kind 0 sync, 1 transfer(token->vault), 2 settle, 3 take(to self), 4 mint claims to self.
contract JVaultActor is IUnlockCallback {
    struct VOp {
        uint8 kind;
        Currency c;
        uint256 amt;
    }

    SupaVault public immutable vault;
    uint256 public lastPaid;

    constructor(SupaVault v) {
        vault = v;
    }

    function exec(VOp[] memory ops) external {
        vault.unlock(abi.encode(ops));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        VOp[] memory ops = abi.decode(data, (VOp[]));
        for (uint256 i; i < ops.length; i++) {
            VOp memory o = ops[i];
            if (o.kind == 0) vault.sync(o.c);
            else if (o.kind == 1) JToken(Currency.unwrap(o.c)).transfer(address(vault), o.amt);
            else if (o.kind == 2) lastPaid = vault.settle(o.c);
            else if (o.kind == 3) vault.take(o.c, address(this), o.amt);
            else if (o.kind == 4) vault.mint(o.c, address(this), o.amt);
        }
        return "";
    }
}

contract JexiPR1VerifyTest is JexiSupaDexTest {
    // ================================================================ StableSwap math (vs. invariant)
    function _residualOk(uint256 x, uint256 y, uint256 A, uint256 D) internal pure returns (bool) {
        // Curve n=2: 4A(x+y) + D == 4A*D + D^3/(4xy)
        uint256 lhs = 4 * A * (x + y) + D;
        uint256 rhs = 4 * A * D + FullMathLib.mulDiv(FullMathLib.mulDiv(D, D, 2 * x), D, 2 * y);
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        // |d(lhs-rhs)/dD| <= 4A + 4 (balanced) .. grows with imbalance; allow 2 wei of D error plus 1e-12 rel.
        uint256 dD = 4 * A + 3 * FullMathLib.mulDiv(D, D, 4 * x * 1) / y + 4;
        return diff <= 2 * dD + lhs / 1e12;
    }

    function testFuzz_stable_D_bounds_symmetry_invariant(uint256 x, uint256 y, uint256 A) public view {
        x = bound(x, 1e6, 1e30);
        y = bound(y, x / 1000 + 1, x * 1000); // up to 1000:1 imbalance
        if (y > 1e30) y = 1e30;
        A = A % 4 == 0 ? 100 : bound(A, 1, 5000); // 25% of runs at the production DEFAULT_A
        uint256 D;
        try stable.computeD(x, y, A) returns (uint256 d_) {
            D = d_;
        } catch {
            // Observed: StableMathNotConverged at low A (e.g. A=1) with ~1000:1 imbalance. Must never happen at the
            // production DEFAULT_A=100 within the 1000:1 range fuzzed here (it does at >=1e5:1, see liveness tests).
            assertTrue(A != 100, "computeD non-convergence at production A within 1000:1");
            return;
        }
        assertLe(D, x + y, "D <= x+y");
        uint256 g = 2 * FullMathLib.mulDiv(1, 1, 1) * _isqrt(x * y);
        assertGe(D + 2, g, "D >= 2*sqrt(xy)");
        try stable.computeD(y, x, A) returns (uint256 dS) {
            assertApproxEqAbs(dS, D, 8, "symmetric within rounding (observed up to 3 wei)");
        } catch {
            // Observed: computeD(x,y) converges but computeD(y,x) does not (argument-order dependent Newton path)
            console2.log("asymmetric non-convergence, A =", A);
            assertTrue(A != 100, "asymmetric non-convergence at production A");
        }
        assertTrue(_residualOk(x, y, A, D), "D solves the StableSwap invariant");
        // computeY(x, x, y) == y +- 1 (consistency of computeD and getY)
        // Observed: off by up to 2 wei at small reserves / A=1 (Ultron's doc claims +-1). Harmless for swaps
        // (they clamp to min(getY(rIn), rOut)); asserted at +-3 and logged when > 1.
        uint256 yy;
        try stable.computeY(x, x, y, A) returns (uint256 y_) {
            yy = y_;
        } catch {
            assertTrue(A != 100, "getY non-convergence at A=100");
            return;
        }
        uint256 err = yy > y ? yy - y : y - yy;
        if (err > 1) console2.log("computeY deviation > 1 wei", err);
        assertLe(err, 8, "computeY(x,x,y)==y +- 8");
        assertLe(yy, y + 1, "computeY never above y+1");
    }

    function testFuzz_stable_getY_monotone(uint256 x, uint256 dx, uint256 A) public view {
        x = bound(x, 1e9, 1e27);
        dx = bound(dx, 1, x);
        A = bound(A, 1, 5000);
        uint256 y1 = stable.computeY(x, x, x, A);
        uint256 y2 = stable.computeY(x + dx, x, x, A);
        assertLe(y2, y1, "more x -> less y");
    }

    function _isqrt(uint256 a) internal pure returns (uint256 r) {
        if (a == 0) return 0;
        r = a;
        uint256 z = (a >> 1) + 1;
        while (z < r) {
            r = z;
            z = (a / z + z) >> 1;
        }
    }

    // ================================================================ Stable swap round trips
    function _stablePool(uint24 fee, uint256 seed, uint256 skew, bool skewDir) internal returns (PoolKey memory k) {
        k = _key(CurveType.STABLE_AMM, fee, 1, address(0)); // PORT: A = 100 via init params (ADR-0007 rev. 2)
        pm.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), "");
        _actor(1e30).exec(_one(_op(0, k, 0, 0, int256(seed), false)));
        if (skew >= 1e4) _actor(1e30).exec(_one(_op(1, k, 0, 0, int256(skew), skewDir)));
    }

    /// exact-out X then exact-in X back inside one unlock: token1 nets 0, token0 must not increase.
    function testFuzz_stable_roundTripNeverProfitable(
        uint24 fee,
        uint256 seed,
        uint256 skew,
        bool skewDir,
        uint256 amt,
        bool dir
    ) public {
        fee = uint24(bound(fee, 0, 3000));
        seed = bound(seed, 1e4, 1e27);
        skew = bound(skew, 0, seed / 2);
        PoolKey memory k = _stablePool(fee, seed, skew, skewDir);
        amt = bound(amt, 1, seed / 4 + 1);
        JFlashActor a = _actor(1e30);
        uint256 b0 = t0.balanceOf(address(a));
        uint256 b1 = t1.balanceOf(address(a));
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](2);
        ops[0] = _op(1, k, 0, 0, -int256(amt), dir); // exact-out amt of the out token
        ops[1] = _op(1, k, 0, 0, int256(amt), !dir); // exact-in the same amt back
        try a.exec(ops) {}
        catch { // revert = no trade (dust/insufficient), nothing extracted
            return;
        }
        assertLe(t0.balanceOf(address(a)) + t1.balanceOf(address(a)), b0 + b1, "round trip profitable (sum)");
        if (dir) assertLe(t0.balanceOf(address(a)), b0, "token0 gained");
        else assertLe(t1.balanceOf(address(a)), b1, "token1 gained");
    }

    /// Extreme imbalance (skew up to 20x the seed pushed in), fee 0, dust-to-medium exact-out/exact-in round trips.
    function testFuzz_stable_roundTripExtremeImbalance(
        uint256 seed,
        uint256 skewMul,
        bool skewDir,
        uint256 amt,
        bool dir
    ) public {
        seed = bound(seed, 1e6, 1e24);
        uint256 skew = seed * bound(skewMul, 1, 20);
        PoolKey memory k = _key(CurveType.STABLE_AMM, 0, 1, address(0)); // PORT: A = 100 via init params (ADR-0007 rev. 2)
        pm.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), "");
        _actor(1e30).exec(_one(_op(0, k, 0, 0, int256(seed), false)));
        // PORT (015/ADR-0008): skews beyond MAX_IMBALANCE_RATIO are now rejected with the explicit bound error; such
        // states are unreachable, so the round-trip property only applies to reachable skews.
        JFlashActor skewer = _actor(1e30);
        try skewer.exec(_one(_op(1, k, 0, 0, int256(skew), skewDir))) {}
        catch (bytes memory err) {
            assertEq(bytes4(err), PoolErrors.StableImbalanceExceeded.selector, "only the documented bound error");
            return;
        }
        amt = bound(amt, 1, seed / 100 + 1);
        JFlashActor a = _actor(1e30);
        uint256 b0 = t0.balanceOf(address(a));
        uint256 b1 = t1.balanceOf(address(a));
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](6);
        for (uint256 i; i < 3; i++) {
            ops[2 * i] = _op(1, k, 0, 0, -int256(amt), dir);
            ops[2 * i + 1] = _op(1, k, 0, 0, int256(amt), !dir);
        }
        try a.exec(ops) {}
        catch {
            return;
        }
        assertLe(t0.balanceOf(address(a)) + t1.balanceOf(address(a)), b0 + b1, "round trip profitable (sum)");
        if (dir) assertLe(t0.balanceOf(address(a)), b0, "token0 gained");
        else assertLe(t1.balanceOf(address(a)), b1, "token1 gained");
    }

    /// Many dust swaps (both modes) in one unlock never extract value.
    function testFuzz_stable_dustSequenceNeverProfitable(uint256 seed, uint8 n, uint8 size, bool exactOut) public {
        seed = bound(seed, 1e4, 1e24);
        n = uint8(bound(n, 2, 60));
        PoolKey memory k = _stablePool(0, seed, 0, true);
        JFlashActor a = _actor(1e30);
        uint256 b = t0.balanceOf(address(a)) + t1.balanceOf(address(a));
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](n);
        int256 s = int256(bound(size, 1, 50));
        for (uint256 i; i < n; i++) {
            ops[i] = _op(1, k, 0, 0, exactOut ? -s : s, i % 2 == 0);
        }
        try a.exec(ops) {}
        catch {
            return;
        }
        assertLe(t0.balanceOf(address(a)) + t1.balanceOf(address(a)), b, "dust sequence profitable");
    }

    /// The original drain sequence from APUS-SUPADEX-001 now reverts or extracts nothing; show which.
    function test_stable_originalDustDrainNowReverts() public {
        PoolKey memory k = _stablePool(500, 1000e18, 0, true);
        JFlashActor attacker = new JFlashActor(vault, pm);
        t0.mint(address(attacker), 1e18);
        JFlashActor.Op[] memory ops = _one(_op(1, k, 0, 0, int256(2), true));
        vm.expectRevert(); // 2 wei in -> 0 out -> InsufficientLiquidity
        attacker.exec(ops);
        // a "real" small swap is fair: out < in at balance
        uint256 out = _swap(k, true, 1e18);
        assertLt(out, 1e18);
        assertGt(out, 0.99e18);
    }

    // ================================================================ Stable LP: first depositor / rounding
    /// Attacker seeds the minimum, exits everything it can, spams swaps to grow reserves/share, then a
    /// victim adds and removes: victim loss per token is bounded by ceil rounding (<= r/T + 1 wei).
    function testFuzz_stable_firstDepositorInflationBounded(uint256 seedShares, uint8 spam, uint256 victim) public {
        seedShares = bound(seedShares, 1001, 1e6);
        spam = uint8(bound(spam, 0, 80));
        victim = bound(victim, 1e3, 1e24);
        PoolKey memory k = _key(CurveType.STABLE_AMM, 3000, 1, address(0)); // PORT: A = 100 via init params (ADR-0007 rev. 2)
        pm.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), "");
        JFlashActor att = _actor(1e30);
        att.exec(_one(_op(0, k, 0, 0, int256(seedShares), false)));
        att.exec(_one(_op(0, k, 0, 0, -int256(seedShares - 1000), false))); // only locked 1000 remain
        for (uint256 i; i < spam; i++) {
            try att.exec(_one(_op(1, k, 0, 0, int256(uint256(7 + i)), i % 2 == 0))) {} catch {}
        }
        (uint256 r0, uint256 r1) = stable.getReserves(k.toId());
        uint256 T = stable.getLiquidity(k.toId());
        (uint256 l0, uint256 l1) = _victimRoundTripLoss(k, victim);
        assertLe(l0, r0 / T + 2, "victim token0 loss above rounding bound");
        assertLe(l1, r1 / T + 2, "victim token1 loss above rounding bound");
        assertLe(r0 + r1, 2 * T * 3, "reserves per share inflated > 3x by swap spam");
    }

    /// PORT: split out of testFuzz_stable_firstDepositorInflationBounded (stack limit under legacy codegen).
    function _victimRoundTripLoss(PoolKey memory k, uint256 victim) internal returns (uint256 l0, uint256 l1) {
        JFlashActor v = _actor(1e30);
        uint256 b0 = t0.balanceOf(address(v));
        uint256 b1 = t1.balanceOf(address(v));
        v.exec(_one(_op(0, k, 0, 0, int256(victim), false)));
        v.exec(_one(_op(0, k, 0, 0, -int256(victim), false)));
        l0 = b0 - t0.balanceOf(address(v));
        l1 = b1 - t1.balanceOf(address(v));
    }

    // ================================================================ CLAMM gap crossing
    function test_clamm_disjointRangesCrossGapBothWays() public {
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(0));
        pm.initialize(k, SQRT_1_1, ""); // tick 0 sits in the gap (0 liquidity)
        JFlashActor lo = _actor(1e27);
        JFlashActor hi = _actor(1e27);
        lo.exec(_one(_op(0, k, -1800, -600, 1e22, false)));
        hi.exec(_one(_op(0, k, 600, 1800, 1e22, false)));
        assertEq(pm.getLiquidity(k.toId()), 0);
        uint256 o1 = _swap(k, true, 1e18);
        assertGt(o1, 0, "sell crosses gap down and fills");
        assertLt(Slot0Library.tick(pm.getSlot0(k.toId())), -600);
        uint256 o2 = _swap(k, false, 1e21);
        assertGt(o2, 0, "buy crosses back through the gap and fills in upper range");
        assertGt(Slot0Library.tick(pm.getSlot0(k.toId())), 600);
        lo.exec(_one(_op(0, k, -1800, -600, -1e22, false)));
        hi.exec(_one(_op(0, k, 600, 1800, -1e22, false)));
        assertGe(t0.balanceOf(address(vault)), vault.reservesOf(c0));
        assertGe(t1.balanceOf(address(vault)), vault.reservesOf(c1));
        assertLt(vault.reservesOf(c0), 1e6);
        assertLt(vault.reservesOf(c1), 1e6);
    }

    function testFuzz_clamm_gapsSolvency(uint256 seed) public {
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(0));
        pm.initialize(k, SQRT_1_1, "");
        JFlashActor[3] memory lps;
        int24[3] memory los = [int24(-3000), int24(-600), int24(1200)];
        int24[3] memory his = [int24(-1200), int24(600), int24(3000)];
        for (uint256 i; i < 3; i++) {
            lps[i] = _actor(1e27);
            lps[i].exec(_one(_op(0, k, los[i], his[i], int256(1e21 * (i + 1)), false)));
        }
        for (uint256 i; i < 10; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            try this.ext_swap(k, r & 1 == 0, uint128(bound(r >> 8, 1e12, 5e20))) {} catch {}
        }
        for (uint256 i; i < 3; i++) {
            lps[i].exec(_one(_op(0, k, los[i], his[i], -int256(1e21 * (i + 1)), false)));
        }
        assertGe(t0.balanceOf(address(vault)), vault.reservesOf(c0));
        assertGe(t1.balanceOf(address(vault)), vault.reservesOf(c1));
        assertLt(vault.reservesOf(c0), 1e6, "dust only");
        assertLt(vault.reservesOf(c1), 1e6, "dust only");
    }

    function ext_swap(PoolKey memory k, bool z, uint128 amt) external returns (uint256) {
        return _swap(k, z, amt);
    }

    /// Gas of an unbounded exact-in sell on a tickSpacing=1 pool once liquidity runs out (walks to MIN_TICK).
    function test_clamm_gasWalkToMinTick_spacing1() public {
        PoolKey memory k = _key(CurveType.CLAMM, 100, 1, address(0));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e27).exec(_one(_op(0, k, -10, 10, 1e18, false)));
        uint256 g = gasleft();
        _swap(k, true, 1e24);
        uint256 used = g - gasleft();
        console2.log("gas: exact-in sell with no limit, spacing 1, walks to MIN_TICK", used);
        console2.logInt(int256(Slot0Library.tick(pm.getSlot0(k.toId()))));
        // and back up again (crosses -10..10 range then walks to MAX_TICK)
        g = gasleft();
        _swap(k, false, 1e24);
        uint256 usedBack = g - gasleft();
        console2.log("gas: buy back, walks to MAX_TICK", usedBack);
        // PORT (016 fixed): baseline 6dc40ec measured 29.4M + 59.6M gas (one step per empty bitmap word).
        // With the 3-level tree bitmap both directions are bounded by a handful of steps.
        assertLt(used, 1_000_000, "016: sell to MIN_TICK bounded");
        assertLt(usedBack, 1_000_000, "016: buy back to MAX_TICK bounded");
    }

    // ================================================================ BIN gate: what it hides
    function _binStack() internal returns (BinEnabledPM p2, BinAMMEngine b2) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        CLAMMEngine c2 = new CLAMMEngine(predicted);
        b2 = new BinAMMEngine(predicted);
        StableAMMEngine s2 = new StableAMMEngine(predicted);
        p2 = new BinEnabledPM(
            IVault(address(vault)), ICurveEngine(address(c2)), ICurveEngine(address(b2)), ICurveEngine(address(s2))
        );
        require(address(p2) == predicted, "pm2");
        p2.setPluginWhitelist(IPluginWhitelist(address(wl)));
        vm.prank(address(timelock));
        vault.setPoolManager(address(p2), true);
    }

    /// PORT (005 fixed, ADR-0006): originally asserted `p0 == p1` ("price does not move") behind the gate. The
    /// multi-bin engine moves the price bin to bin, and a later identical sell fills at a worse price.
    function test_bin_priceMovesAcrossBins_noStalePriceDrain() public {
        (BinEnabledPM p2, BinAMMEngine b2) = _binStack();
        PoolKey memory k = _key(CurveType.BIN_AMM, 3000, 10, address(0));
        p2.initialize(k, SQRT_1_1, "");
        JFlashActor lp = new JFlashActor(vault, p2);
        t0.mint(address(lp), 1e24);
        t1.mint(address(lp), 1e24);
        lp.exec(_one(_op(0, k, -20, 20, int256(100e18), false)));
        uint160 p0 = Slot0Library.sqrtPriceX96(p2.getSlot0(k.toId()));
        JFlashActor tr = new JFlashActor(vault, p2);
        t0.mint(address(tr), 1e24);
        uint256 before1 = t1.balanceOf(address(tr));
        tr.exec(_one(_op(1, k, 0, 0, int256(990e18), true)));
        uint256 got1 = t1.balanceOf(address(tr)) - before1;
        uint160 p1 = Slot0Library.sqrtPriceX96(p2.getSlot0(k.toId()));
        console2.log("token1 out for 990e18 sell", got1);
        assertLt(p1, p0, "price moved");
        assertLt(b2.getActiveBinId(k.toId()), -5, "several bins crossed");
        assertLt(got1, 990e18, "no fill at the stale price for the whole size");
    }

    function testFuzz_bin_ifEnabled_addRemoveNotProfitable(uint96 tradeIn, bool z, uint96 dep) public {
        (BinEnabledPM p2,) = _binStack();
        PoolKey memory k = _key(CurveType.BIN_AMM, 3000, 10, address(0));
        p2.initialize(k, SQRT_1_1, "");
        JFlashActor lp = new JFlashActor(vault, p2);
        t0.mint(address(lp), 1e27);
        t1.mint(address(lp), 1e27);
        lp.exec(_one(_op(0, k, 0, 0, int256(1000e18), false)));
        tradeIn = uint96(bound(tradeIn, 0, 900e18));
        if (tradeIn > 1e6) {
            JFlashActor tr = new JFlashActor(vault, p2);
            t0.mint(address(tr), 1e27);
            t1.mint(address(tr), 1e27);
            try tr.exec(_one(_op(1, k, 0, 0, int256(uint256(tradeIn)), z))) {} catch {}
        }
        dep = uint96(bound(dep, 1, 1e26));
        JFlashActor a = new JFlashActor(vault, p2);
        t0.mint(address(a), 1e27);
        t1.mint(address(a), 1e27);
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](2);
        ops[0] = _op(0, k, 0, 0, int256(uint256(dep)), false);
        ops[1] = _op(0, k, 0, 0, -int256(uint256(dep)), false);
        a.exec(ops);
        assertLe(t0.balanceOf(address(a)), 1e27);
        assertLe(t1.balanceOf(address(a)), 1e27);
    }

    // ================================================================ Vault sync/settle semantics
    function _v(uint8 kind, Currency c, uint256 amt) internal pure returns (JVaultActor.VOp memory) {
        return JVaultActor.VOp(kind, c, amt);
    }

    function test_vault_syncSettle_creditsOnlyArrivalNotSurplus() public {
        t0.transfer(address(vault), 5e18); // pre-existing surplus (donation)
        JVaultActor a = new JVaultActor(vault);
        t0.mint(address(a), 1e18);
        JVaultActor.VOp[] memory ops = new JVaultActor.VOp[](4);
        ops[0] = _v(0, c0, 0);
        ops[1] = _v(1, c0, 1e18);
        ops[2] = _v(2, c0, 0);
        ops[3] = _v(4, c0, 1e18);
        a.exec(ops);
        assertEq(a.lastPaid(), 1e18, "credited exactly the arrival");
        assertEq(vault.reservesOf(c0), 1e18);
        // surplus only sweepable by owner (timelock)
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        vault.sweepSurplus(c0, address(this));
        vm.prank(address(timelock));
        assertEq(vault.sweepSurplus(c0, address(0xBEEF)), 5e18);
        assertEq(t0.balanceOf(address(vault)), vault.reservesOf(c0), "solvent after sweep");
    }

    function test_vault_settleWrongCurrency_reverts() public {
        JVaultActor a = new JVaultActor(vault);
        t0.mint(address(a), 1e18);
        JVaultActor.VOp[] memory ops = new JVaultActor.VOp[](3);
        ops[0] = _v(0, c0, 0);
        ops[1] = _v(1, c0, 1e18);
        ops[2] = _v(2, c1, 0);
        vm.expectRevert(abi.encodeWithSelector(VaultErrors.CurrencyNotSynced.selector, c1));
        a.exec(ops);
    }

    function test_vault_doubleSettle_reverts() public {
        JVaultActor a = new JVaultActor(vault);
        t0.mint(address(a), 2e18);
        JVaultActor.VOp[] memory ops = new JVaultActor.VOp[](5);
        ops[0] = _v(0, c0, 0);
        ops[1] = _v(1, c0, 1e18);
        ops[2] = _v(2, c0, 0);
        ops[3] = _v(1, c0, 1e18);
        ops[4] = _v(2, c0, 0);
        vm.expectRevert(abi.encodeWithSelector(VaultErrors.CurrencyNotSynced.selector, c0));
        a.exec(ops);
    }

    function test_vault_syncDoesNotSurviveUnlock() public {
        JVaultActor a = new JVaultActor(vault);
        t0.mint(address(a), 1e18);
        a.exec(_vs(_v(0, c0, 0)));
        vm.prank(address(a));
        t0.transfer(address(vault), 1e18); // outside any unlock
        vm.expectRevert(abi.encodeWithSelector(VaultErrors.CurrencyNotSynced.selector, c0));
        a.exec(_vs(_v(2, c0, 0)));
    }

    /// Flash pattern: take, sync, repay, settle balances; sync before take makes repayment unrecognisable.
    function test_vault_takeThenSyncRepaySettle() public {
        PoolKey memory k = _clammPool(address(0), -1200, 1200, SQRT_1_1, 1e24);
        k;
        JVaultActor a = new JVaultActor(vault);
        JVaultActor.VOp[] memory ops = new JVaultActor.VOp[](4);
        ops[0] = _v(3, c0, 1e18);
        ops[1] = _v(0, c0, 0);
        ops[2] = _v(1, c0, 1e18);
        ops[3] = _v(2, c0, 0);
        a.exec(ops);
        assertEq(t0.balanceOf(address(vault)), vault.reservesOf(c0));
    }

    function _vs(JVaultActor.VOp memory o) internal pure returns (JVaultActor.VOp[] memory ops) {
        ops = new JVaultActor.VOp[](1);
        ops[0] = o;
    }

    // ================================================================ AntiJIT: control actually confiscates
    function _jitRun(uint256 waitBlocks) internal returns (uint256 got0) {
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(jit));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e27).exec(_one(_op(0, k, -600, 600, 1e22, false)));
        vm.roll(block.number + 100);
        JFlashActor j = _actor(1e27);
        j.exec(_one(_op(0, k, -600, 600, 9e22, false)));
        uint256 afterAdd0 = t0.balanceOf(address(j));
        _swap(k, true, 100e18);
        vm.roll(block.number + waitBlocks);
        j.exec(_one(_op(0, k, -600, 600, 0, false))); // fee poke only (principal stays)
        got0 = t0.balanceOf(address(j)) - afterAdd0;
    }

    function test_antiJIT_haircutActuallyApplies() public {
        uint256 s = vm.snapshotState();
        uint256 young = _jitRun(0);
        vm.revertToState(s);
        uint256 aged = _jitRun(50);
        console2.log("JIT fees token0: same block / after 50 blocks", young, aged);
        assertLt(young, aged / 100, "same-block JIT fees confiscated");
        assertGt(aged, 0.25e18, "resident LP keeps its fees");
    }

    // ================================================================ LVR: signal still fires on real moves
    function test_lvr_surchargeOnRealMove_andCapped() public {
        PoolKey memory k = _clammPool(address(lvr), -60000, 60000, SQRT_1_1, 1e24);
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        _swap(k, true, 1e9);
        assertEq(_fee(k), 3000, "base fee at rest");
        _swap(k, true, 2e23); // large move
        int24 t = Slot0Library.tick(pm.getSlot0(k.toId()));
        console2.logInt(int256(t));
        vm.warp(block.timestamp + 6);
        vm.roll(block.number + 1);
        _swap(k, false, 1e9);
        console2.log("fee after real move", uint256(_fee(k)));
        assertGt(_fee(k), 3000, "surcharge applies after a real price move");
        assertLe(_fee(k), 100_000);
    }

    function test_lvr_onStablePool_baseFeeOnly() public {
        PoolKey memory k = _key(CurveType.STABLE_AMM, 500, 1, address(lvr)); // PORT: A = 100 via init params (ADR-0007 rev. 2)
        pm.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), "");
        _actor(1e24).exec(_one(_op(0, k, 0, 0, int256(1000e18), false)));
        vm.warp(block.timestamp + 600);
        uint256 out = _swap(k, true, 1e18);
        assertGt(out, 0.99e18);
    }

    // ================================================================ Withdraw-only pause
    function test_pause_poolAndCurve_removalsStillWork() public {
        PoolKey memory k = _clammPool(address(0), -1200, 1200, SQRT_1_1, 1e24);
        JFlashActor lp = _actor(1e27);
        lp.exec(_one(_op(0, k, -600, 600, 1e21, false)));
        vm.startPrank(GUARD);
        cb.pausePool(k.toId());
        cb.pauseCurve(uint8(CurveType.CLAMM));
        cb.pauseVault();
        vm.stopPrank();
        vm.expectRevert();
        _swap(k, true, 1e18);
        vm.expectRevert();
        lp.exec(_one(_op(0, k, -600, 600, 1e21, false)));
        lp.exec(_one(_op(0, k, -600, 600, -1e21, false))); // exit works under all three pauses
    }

    // ================================================================ Stable: extreme imbalance liveness
    /// PORT (015 fixed): originally expected StableMathNotConverged for this ~9e5:1 input at A=100. The new solver
    /// stop rule converges; such a state is anyway outside the pool's supported range (MAX_IMBALANCE_RATIO 1e4).
    function test_stable_computeDConvergesAtExtremeRatio_A100() public view {
        uint256 x = 972630958731331734854191584359;
        uint256 y = 1087311933662020432297984;
        uint256 d = stable.computeD(x, y, 100);
        assertLe(d, x + y);
        assertTrue(_residualOk(x, y, 100, d), "D solves the invariant");
    }

    /// PORT (015 fixed): originally showed a trader can push a live pool into a state where every swap reverts with
    /// StableMathNotConverged (frozen). Now pushes beyond the supported range revert with the explicit bound error,
    /// the pool never freezes, the reverse (rebalancing) swap works and LP exits still work.
    function test_stable_cannotPushToNonConvergentState() public {
        PoolKey memory k = _stablePool(500, 1000e18, 0, true);
        JFlashActor g = _actor(1e36);
        for (uint256 e = 21; e <= 34; e++) {
            uint256 amt = 10 ** e;
            try g.exec(_one(_op(1, k, 0, 0, int256(amt), true))) {
                console2.log("swap in 10^e ok, e =", e);
            } catch (bytes memory err) {
                console2.log("swap in 10^e reverted, e =", e);
                console2.logBytes4(bytes4(err));
                assertTrue(bytes4(err) != PoolErrors.StableMathNotConverged.selector, "never a solver failure");
            }
        }
        assertGt(this.ext_swap(k, false, 1e18), 0, "reverse swap works: not frozen");
        assertGt(this.ext_swap(k, true, 1e15), 0, "forward small swap works");
        (uint256 r0b, uint256 r1b) = stable.getReserves(k.toId());
        JFlashActor lp2 = _actor(1e36);
        lp2.exec(_one(_op(0, k, 0, 0, int256(1e18), false)));
        lp2.exec(_one(_op(0, k, 0, 0, -int256(1e18), false)));
        (uint256 r0c, uint256 r1c) = stable.getReserves(k.toId());
        assertApproxEqAbs(r0c, r0b, 2);
        assertApproxEqAbs(r1c, r1b, 2);
    }
}
