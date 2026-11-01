// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// APUS-SUPADEX-039 (SDX-073) and APUS-SUPADEX-040 (SDX-072) regressions.
// Ported from Jexi's PoCs (security-findings/supadex/tests/cov-7bf1ee9/JexiCov7bf1ee9.t.sol) and inverted: each test
// asserts the FIXED behaviour, so it fails if the bug comes back.

import {RouterQuoterFixture, RQToken} from "../../helpers/RouterQuoterFixture.sol";
import {ISupaRouter} from "../../../contract/interfaces/ISupaRouter.sol";
import {ISupaQuoter} from "../../../contract/interfaces/ISupaQuoter.sol";
import {IPoolManager} from "../../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../../contract/interfaces/IUnlockCallback.sol";
import {SupaVault} from "../../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../../contract/core/SupaPoolManager.sol";
import {PoolKey, CurveType} from "../../../contract/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../../contract/types/Currency.sol";
import {VaultErrors} from "../../../contract/errors/VaultErrors.sol";
import {PeripheryErrors} from "../../../contract/errors/PeripheryErrors.sol";
import {PoolErrors} from "../../../contract/errors/PoolErrors.sol";
import {TickMathLib} from "../../../contract/libraries/TickMathLib.sol";

/// @dev LP that can add AND remove a ranged position (settles what it owes, takes what it is owed).
contract ShortfallLP is IUnlockCallback {
    SupaVault public immutable vault;
    SupaPoolManager public immutable manager;
    address public immutable owner;

    constructor(SupaVault v, SupaPoolManager m, address o) {
        vault = v;
        manager = m;
        owner = o;
    }

    function modify(PoolKey memory key, int24 lo, int24 hi, int256 liq) external {
        vault.unlock(abi.encode(key, IPoolManager.ModifyLiquidityParams(lo, hi, liq, bytes32(0))));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault));
        (PoolKey memory key, IPoolManager.ModifyLiquidityParams memory p) =
            abi.decode(data, (PoolKey, IPoolManager.ModifyLiquidityParams));
        manager.modifyLiquidity(key, p, "");
        _s(key.currency0, vault.getCurrencyDelta(address(this), key.currency0));
        _s(key.currency1, vault.getCurrencyDelta(address(this), key.currency1));
        return "";
    }

    function _s(Currency c, int256 d) internal {
        if (d < 0) {
            vault.sync(c);
            RQToken(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, owner, uint256(d));
        }
    }
}

/// @dev Calls vault.unlock from inside its own unlock callback (no router involved).
contract ShortfallNestedUnlocker is IUnlockCallback {
    SupaVault public immutable vault;
    bytes public innerRet;
    bool public innerOk;

    constructor(SupaVault v) {
        vault = v;
    }

    function go() external {
        vault.unlock("outer");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (keccak256(data) == keccak256("outer")) {
            (innerOk, innerRet) = address(vault).call(abi.encodeCall(vault.unlock, (bytes("inner"))));
        }
        return "";
    }
}

/// @dev Toy integrator that trusts exact-output semantics: buys `amt` B for a user, then forwards `amt` B.
contract ShortfallNaiveForwarder {
    ISupaRouter public immutable router;

    constructor(ISupaRouter r) {
        router = r;
    }

    function buyFor(address user, PoolKey calldata key, uint128 amt, uint128 maxIn, RQToken a, RQToken b) external {
        a.transferFrom(user, address(this), maxIn);
        a.approve(address(router), type(uint256).max);
        uint256 spent = router.exactOutputSingle(
            ISupaRouter.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: true,
                recipient: address(this),
                amountOut: amt,
                amountInMaximum: maxIn,
                sqrtPriceLimitX96: 0,
                hookData: "",
                payWithClaims: false,
                receiveAsClaims: false,
                deadline: block.timestamp
            })
        );
        a.transfer(user, maxIn - spent);
        b.transfer(user, amt);
    }
}

contract ExactOutputShortfallTest is RouterQuoterFixture {
    using CurrencyLibrary for Currency;

    address internal attacker = makeAddr("attacker");

    // ------------------------------------------------------------------ SDX-072 / APUS-SUPADEX-040

    function test_040_nestedUnlock_revertsWithVaultAlreadyLocked() public {
        ShortfallNestedUnlocker n = new ShortfallNestedUnlocker(vault);
        n.go();
        assertFalse(n.innerOk(), "nested unlock blocked");
        assertEq(VaultErrors.VaultAlreadyLocked.selector, bytes4(0xa6c62fd0));
        assertEq(n.innerRet(), abi.encodeWithSelector(VaultErrors.VaultAlreadyLocked.selector), "VaultAlreadyLocked()");
    }

    // ------------------------------------------------------------------ SDX-073 / APUS-SUPADEX-039 helpers

    /// @dev Thin CLAMM pool: fee 1%, tick spacing 200, liquidity only in [-200, 200].
    function _thinClamm() internal returns (PoolKey memory k) {
        k = _key(tokenA, tokenB, 10000, 200, CurveType.CLAMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidityRange(k, -200, 200, 1_000 ether);
    }

    function _decodeShortfall(bytes memory err) internal pure returns (uint256 requested, uint256 delivered) {
        require(bytes4(err) == PeripheryErrors.InsufficientOutputAmount.selector, "not InsufficientOutputAmount");
        bytes memory a = new bytes(err.length - 4);
        for (uint256 i = 0; i < a.length; i++) {
            a[i] = err[i + 4];
        }
        (requested, delivered) = abi.decode(a, (uint256, uint256));
    }

    // ------------------------------------------------------------------ router, single hop

    /// Jexi baseline PoC inverted: the 1,000 B request on a pool that can deliver ~9.95 B now reverts, the payer is
    /// not charged and nothing is delivered (pre-fix: 9.95 B delivered for 10.15 A, no revert).
    function test_039_clammShortfall_reverts_noChargeNoDelivery() public {
        PoolKey memory k = _thinClamm();
        uint128 requested = 1_000 ether;
        uint256 aBefore = rawA.balanceOf(alice);
        uint256 bBefore = rawB.balanceOf(bob);
        vm.prank(alice);
        try router.exactOutputSingle(_outSingle(k, true, bob, requested, 50 ether)) {
            fail("shortfall must revert");
        } catch (bytes memory err) {
            (uint256 req, uint256 delivered) = _decodeShortfall(err);
            assertEq(req, requested);
            assertGt(delivered, 0);
            assertLt(delivered, requested / 50);
        }
        assertEq(rawA.balanceOf(alice), aBefore, "not charged");
        assertEq(rawB.balanceOf(bob), bBefore, "nothing delivered");
        _assertClean();
    }

    /// BIN was affected too (pre-fix: 500 B delivered of 100,000 requested).
    function test_039_binShortfall_reverts() public {
        PoolKey memory k = _key(tokenA, tokenB, 2000, 10, CurveType.BIN_AMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidity(k, 1_000 ether);
        uint256 bBefore = rawB.balanceOf(bob);
        vm.prank(alice);
        try router.exactOutputSingle(_outSingle(k, true, bob, 100_000 ether, type(uint128).max)) {
            fail("BIN shortfall must revert");
        } catch (bytes memory err) {
            (uint256 req, uint256 delivered) = _decodeShortfall(err);
            assertEq(req, 100_000 ether);
            assertLt(delivered, 100_000 ether);
        }
        assertEq(rawB.balanceOf(bob), bBefore);
        _assertClean();
    }

    /// STABLE already failed closed in the engine; unchanged by the fix.
    function test_039_stableShortfall_stillRevertsInEngine() public {
        PoolKey memory k = _key(tokenA, tokenB, 500, 1, CurveType.STABLE_AMM);
        manager.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), "");
        lp.addLiquidity(k, 1_000 ether);
        vm.prank(alice);
        vm.expectRevert(PoolErrors.InsufficientLiquidity.selector);
        router.exactOutputSingle(_outSingle(k, true, bob, 100_000 ether, type(uint128).max));
        _assertClean();
    }

    /// Property: on the thin pool, an exact-output swap either delivers exactly `amountOut` or reverts with
    /// InsufficientOutputAmount. It never under-delivers.
    function testFuzz_039_exactOrRevert(uint128 amountOut) public {
        PoolKey memory k = _thinClamm();
        amountOut = uint128(bound(amountOut, 1, 50 ether));
        uint256 bBefore = rawB.balanceOf(bob);
        vm.prank(alice);
        try router.exactOutputSingle(_outSingle(k, true, bob, amountOut, type(uint128).max)) returns (uint256 paid) {
            assertEq(rawB.balanceOf(bob) - bBefore, amountOut, "exact output delivered");
            assertGt(paid, 0);
        } catch (bytes memory err) {
            (uint256 req, uint256 delivered) = _decodeShortfall(err);
            assertEq(req, amountOut);
            assertLt(delivered, amountOut);
            assertEq(rawB.balanceOf(bob), bBefore);
        }
        _assertClean();
    }

    /// Deep pool: the fix must not affect a normal exact-output fill.
    function testFuzz_039_deepPool_deliversExactly(uint128 amountOut) public {
        amountOut = uint128(bound(amountOut, 1, 1_000 ether));
        uint256 bBefore = rawB.balanceOf(bob);
        (uint256 quoted,,) = quoter.quoteExactOutputSingle(_qOut(clammAB, true, amountOut));
        vm.prank(alice);
        uint256 paid = router.exactOutputSingle(_outSingle(clammAB, true, bob, amountOut, type(uint128).max));
        assertEq(rawB.balanceOf(bob) - bBefore, amountOut);
        assertEq(paid, quoted, "quote == execution");
        _assertClean();
    }

    // ------------------------------------------------------------------ price-limited partial fills (v3 semantics)

    /// With an explicit price limit a partial fill is allowed, provided the per-unit price stays within
    /// amountInMaximum / amountOut. Here the cap is 2 A/B and the fill costs ~1.02 A/B, so it goes through.
    function test_039_priceLimitedPartialFill_withinPerUnitBound_succeeds() public {
        PoolKey memory k = _thinClamm();
        uint128 requested = 1_000 ether;
        uint128 maxIn = 2_000 ether;
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, requested, maxIn);
        p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(-200);
        ISupaQuoter.QuoteExactOutputSingleParams memory q = _qOut(k, true, requested);
        q.sqrtPriceLimitX96 = p.sqrtPriceLimitX96;
        (uint256 quoted, uint160 sqrtAfter,) = quoter.quoteExactOutputSingle(q);
        assertEq(sqrtAfter, p.sqrtPriceLimitX96, "quote stops at the limit (partial-fill signal)");

        uint256 aBefore = rawA.balanceOf(alice);
        uint256 bBefore = rawB.balanceOf(bob);
        vm.prank(alice);
        uint256 ret = router.exactOutputSingle(p);
        uint256 paid = aBefore - rawA.balanceOf(alice);
        uint256 delivered = rawB.balanceOf(bob) - bBefore;
        assertEq(ret, paid);
        assertEq(paid, quoted, "price-limited quote == execution");
        assertGt(delivered, 0);
        assertLt(delivered, requested, "partial fill");
        assertLe(paid * requested, uint256(maxIn) * delivered, "per-unit bound held");
        _assertClean();
    }

    /// Same fill, but a per-unit cap of 1 A/B (maxIn == requested): ~1.02 A/B exceeds it, so it reverts.
    function test_039_priceLimitedPartialFill_overPerUnitBound_reverts() public {
        PoolKey memory k = _thinClamm();
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, 1_000 ether, 1_000 ether);
        p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(-200);
        vm.prank(alice);
        vm.expectPartialRevert(PeripheryErrors.SlippageExceeded.selector);
        router.exactOutputSingle(p);
        _assertClean();
    }

    /// BIN with an explicit price limit: partial fill up to the limit is allowed (v3 semantics) when the per-unit bound
    /// is loose; the price-limited quote must equal the execution.
    function test_039_binPriceLimitedPartialFill_succeeds() public {
        PoolKey memory k = _key(tokenA, tokenB, 2000, 10, CurveType.BIN_AMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidity(k, 1_000 ether);
        uint128 requested = 100_000 ether;
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, requested, type(uint128).max);
        p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(-1000);
        ISupaQuoter.QuoteExactOutputSingleParams memory q = _qOut(k, true, requested);
        q.sqrtPriceLimitX96 = p.sqrtPriceLimitX96;
        (uint256 quoted,,) = quoter.quoteExactOutputSingle(q);

        uint256 aBefore = rawA.balanceOf(alice);
        uint256 bBefore = rawB.balanceOf(bob);
        vm.prank(alice);
        uint256 ret = router.exactOutputSingle(p);
        uint256 paid = aBefore - rawA.balanceOf(alice);
        uint256 delivered = rawB.balanceOf(bob) - bBefore;
        assertEq(ret, paid);
        assertEq(paid, quoted, "price-limited BIN quote == execution");
        assertGt(delivered, 0);
        assertLt(delivered, requested, "partial fill up to the limit");
        _assertClean();
    }

    // ------------------------------------------------------------------ sandwich (Jexi PoC inverted)

    function _sandwichSetup() internal returns (PoolKey memory k, ShortfallLP atkLp, int24 lo, int24 hi) {
        k = _key(tokenA, tokenB, 500, 60, CurveType.CLAMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidityRange(k, -600, 600, 100_000 ether); // honest LP
        atkLp = new ShortfallLP(vault, manager, attacker);
        rawA.mint(attacker, 100_000 ether);
        rawB.mint(attacker, 100_000 ether);
        vm.startPrank(attacker);
        rawA.approve(address(router), type(uint256).max);
        rawB.approve(address(router), type(uint256).max);
        rawB.transfer(address(atkLp), 10 ether);
        vm.stopPrank();
        lo = -46200;
        hi = -46020;
        atkLp.modify(k, lo, hi, int256(1_150 ether)); // ~1 B parked at ~100 A/B
        // front-run: drain the honest range down to the top of the attacker range
        ISupaRouter.ExactInputSingleParams memory f = _inSingle(k, true, attacker, 50_000 ether, 0);
        f.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(hi);
        vm.prank(attacker);
        router.exactInputSingle(f);
    }

    /// Control for the sandwich: on the same pool WITHOUT the front-run, the victim's 100 B / 110 A order fills exactly
    /// and costs what the quoter said (Jexi measured an honest quote of ~100.15 A).
    function test_039_sandwichPool_honestFill_unaffected() public {
        PoolKey memory k = _key(tokenA, tokenB, 500, 60, CurveType.CLAMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidityRange(k, -600, 600, 100_000 ether);
        (uint256 honestIn,,) = quoter.quoteExactOutputSingle(_qOut(k, true, 100 ether));
        assertLt(honestIn, 110 ether);
        uint256 vA = rawA.balanceOf(alice);
        uint256 vB = rawB.balanceOf(alice);
        vm.prank(alice);
        uint256 ret = router.exactOutputSingle(_outSingle(k, true, alice, 100 ether, 110 ether));
        assertEq(rawB.balanceOf(alice) - vB, 100 ether, "exact 100 B");
        assertEq(vA - rawA.balanceOf(alice), ret);
        assertEq(ret, honestIn, "quote == execution");
        _assertClean();
    }

    /// Pre-fix: victim paid 103.84 A for 1.03 B (91x their implied cap), attacker PnL +100.84 A.
    /// Now the victim's default (no price limit) exact-out reverts and the round trip costs the attacker fees.
    function test_039_sandwich_victimReverts_attackerUnprofitable() public {
        (PoolKey memory k, ShortfallLP atkLp, int24 lo, int24 hi) = _sandwichSetup();
        // _sandwichSetup mints the attacker exactly 100,000 A and 100,000 B (10 B of it parked via atkLp).
        uint256 atkA0 = 100_000 ether;
        uint256 atkB0 = 100_000 ether;

        uint256 vA = rawA.balanceOf(alice);
        uint256 vB = rawB.balanceOf(alice);
        vm.prank(alice);
        vm.expectPartialRevert(PeripheryErrors.InsufficientOutputAmount.selector);
        router.exactOutputSingle(_outSingle(k, true, alice, 100 ether, 110 ether));
        assertEq(rawA.balanceOf(alice), vA, "victim not charged");
        assertEq(rawB.balanceOf(alice), vB);

        // back-run and withdraw
        ISupaRouter.ExactInputSingleParams memory b = _inSingle(k, false, attacker, 50_000 ether, 0);
        b.sqrtPriceLimitX96 = SQRT_1_1;
        vm.prank(attacker);
        router.exactInputSingle(b);
        atkLp.modify(k, lo, hi, -int256(1_150 ether));
        uint256 atkA1 = rawA.balanceOf(attacker) + rawA.balanceOf(address(atkLp));
        uint256 atkB1 = rawB.balanceOf(attacker) + rawB.balanceOf(address(atkLp));
        int256 pnl = (int256(atkA1) - int256(atkA0)) + (int256(atkB1) - int256(atkB0));
        emit log_named_decimal_int("attacker PnL (A+B at 1:1)", pnl, 18);
        assertLe(pnl, 0, "sandwich no longer profitable");
        _assertClean();
    }

    /// A victim that passes the common "no limit" sentinel (MIN_SQRT_RATIO + 1) takes the partial-fill branch, where
    /// the per-unit bound (110 A / 100 B = 1.10 A/B) stops the ~100 A/B fill.
    function test_039_sandwich_sentinelPriceLimit_perUnitBoundReverts() public {
        (PoolKey memory k,,,) = _sandwichSetup();
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, alice, 100 ether, 110 ether);
        p.sqrtPriceLimitX96 = TickMathLib.MIN_SQRT_RATIO + 1;
        uint256 vA = rawA.balanceOf(alice);
        vm.prank(alice);
        vm.expectPartialRevert(PeripheryErrors.SlippageExceeded.selector);
        router.exactOutputSingle(p);
        assertEq(rawA.balanceOf(alice), vA);
        _assertClean();
    }

    // ------------------------------------------------------------------ composability (Jexi PoC inverted)

    /// Pre-fix: the integrator paid 90.05 B of its user's 100 B from other users' float (500 -> 409.95).
    function test_039_naiveIntegrator_floatProtected() public {
        PoolKey memory k = _thinClamm();
        ShortfallNaiveForwarder fw = new ShortfallNaiveForwarder(router);
        rawB.mint(address(fw), 500 ether);
        vm.prank(alice);
        rawA.approve(address(fw), type(uint256).max);
        uint256 aBefore = rawA.balanceOf(alice);
        vm.expectPartialRevert(PeripheryErrors.InsufficientOutputAmount.selector);
        fw.buyFor(alice, k, 100 ether, 120 ether, rawA, rawB);
        assertEq(rawB.balanceOf(address(fw)), 500 ether, "integrator float untouched");
        assertEq(rawA.balanceOf(alice), aBefore);
    }

    // ------------------------------------------------------------------ multi-hop

    /// Inner-hop shortfall (C <-STABLE- A <-thin- B): explicit InsufficientOutputAmount (was CurrencyNotSettled).
    function test_039_multiHop_innerHopShortfall_reverts() public {
        PoolKey memory k = _thinClamm();
        bytes memory path = _path2(tokenC, stableAC, tokenA, k, tokenB);
        vm.prank(alice);
        vm.expectPartialRevert(PeripheryErrors.InsufficientOutputAmount.selector);
        router.exactOutput(_outMulti(path, alice, 1_000 ether, type(uint128).max));
        _assertClean();
    }

    /// Outer-hop shortfall (B <-thin- A <-STABLE- C).
    function test_039_multiHop_outerHopShortfall_reverts() public {
        PoolKey memory k = _thinClamm();
        bytes memory path = _path2(tokenB, k, tokenA, stableAC, tokenC);
        vm.prank(alice);
        try router.exactOutput(_outMulti(path, alice, 1_000 ether, type(uint128).max)) {
            fail("outer-hop shortfall must revert");
        } catch (bytes memory err) {
            (uint256 req, uint256 delivered) = _decodeShortfall(err);
            assertEq(req, 1_000 ether, "outer hop owes the recipient's amount");
            assertLt(delivered, req);
        }
        _assertClean();
    }

    // ------------------------------------------------------------------ quoter

    /// Pre-fix: the quoter returned 10.15 A for a 1,000 B request (priced only the fillable part, no flag).
    function test_039_quoter_singleShortfall_reverts() public {
        PoolKey memory k = _thinClamm();
        try quoter.quoteExactOutputSingle(_qOut(k, true, 1_000 ether)) returns (uint256, uint160, int24) {
            fail("quoter must not price a partial fill as a full one");
        } catch (bytes memory err) {
            (uint256 req, uint256 delivered) = _decodeShortfall(err);
            assertEq(req, 1_000 ether);
            assertGt(delivered, 0);
            assertLt(delivered, req);
        }
        vm.expectPartialRevert(PeripheryErrors.InsufficientOutputAmount.selector);
        quoter.quoteExactOutputSingleWithFee(_qOut(k, true, 1_000 ether));
    }

    function test_039_quoter_multiHopShortfall_reverts() public {
        PoolKey memory k = _thinClamm();
        vm.expectPartialRevert(PeripheryErrors.InsufficientOutputAmount.selector);
        quoter.quoteExactOutput(_path2(tokenB, k, tokenA, stableAC, tokenC), 1_000 ether);
        vm.expectPartialRevert(PeripheryErrors.InsufficientOutputAmount.selector);
        quoter.quoteExactOutput(_path2(tokenC, stableAC, tokenA, k, tokenB), 1_000 ether);
    }
}
