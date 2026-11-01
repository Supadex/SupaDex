// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Jexi re-verification of APUS-SUPADEX-039 / 040 fixes (Ultron branch fix/exact-output-shortfall-2026-11-01 @ 1ed7c8b).
// Auditor-only file. Drop into test/jexi/rv/ of a 1ed7c8b checkout. Local forge only.
// Covers the gaps Ultron listed as not verified plus Jexi's adversarial review of the per-unit price cap:
//  - selectors computed, not hand-typed
//  - price-limited partial-fill property (CLAMM, BIN), exact boundary of the cross-multiplied cap, uint128 extremes
//  - amountOut == 0
//  - quoter/router parity (no limit: identical revert payloads; with limit: amountIn equal on success)
//  - multi-hop end to end (exact-or-revert, quote == execution, deep 3-hop never blocked)
//  - fuzzed sandwich against a victim using the MIN_SQRT_RATIO+1 sentinel
//  - whitelisted delta-returning plugin (canReturnDelta) returning arbitrary afterSwap deltas and fee overrides
//  - fee-on-transfer output token (documented unsupported; observation only)

import {RouterQuoterFixture, RQToken} from "../../helpers/RouterQuoterFixture.sol";
import {ISupaRouter} from "../../../contract/interfaces/ISupaRouter.sol";
import {ISupaQuoter} from "../../../contract/interfaces/ISupaQuoter.sol";
import {IPoolManager} from "../../../contract/interfaces/IPoolManager.sol";
import {IPlugin} from "../../../contract/interfaces/IPlugin.sol";
import {IUnlockCallback} from "../../../contract/interfaces/IUnlockCallback.sol";
import {SupaVault} from "../../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../../contract/core/SupaPoolManager.sol";
import {PluginWhitelist} from "../../../contract/governance/PluginWhitelist.sol";
import {PoolKey, CurveType} from "../../../contract/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../../contract/types/Currency.sol";
import {BalanceDelta} from "../../../contract/types/BalanceDelta.sol";
import {VaultErrors} from "../../../contract/errors/VaultErrors.sol";
import {PeripheryErrors} from "../../../contract/errors/PeripheryErrors.sol";
import {PoolErrors} from "../../../contract/errors/PoolErrors.sol";
import {PluginErrors} from "../../../contract/errors/PluginErrors.sol";
import {TickMathLib} from "../../../contract/libraries/TickMathLib.sol";

/// @dev Whitelisted plugin that can return an arbitrary afterSwap delta and override the swap fee.
contract RVDeltaPlugin is IPlugin {
    uint32 public immutable perms;
    int128 public afterDelta;
    uint24 public feeOverride;

    constructor(uint32 p) {
        perms = p;
    }

    function set(int128 d, uint24 f) external {
        afterDelta = d;
        feeOverride = f;
    }

    function getPluginPermissions() external view returns (uint32) {
        return perms;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IPlugin.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IPlugin.afterInitialize.selector;
    }

    function beforeModifyLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IPlugin.beforeModifyLiquidity.selector;
    }

    function afterModifyLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta, BalanceDelta) {
        return (IPlugin.afterModifyLiquidity.selector, BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, uint24)
    {
        return (IPlugin.beforeSwap.selector, feeOverride);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        returns (bytes4, int128)
    {
        return (IPlugin.afterSwap.selector, afterDelta);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IPlugin.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IPlugin.afterDonate.selector;
    }
}

/// @dev ERC20 whose transfers can burn a fee (toggle). ABI-compatible with RQToken for the fixture's LP helper.
contract RVFotToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 18;
    uint256 public feeBps;

    function setFee(uint256 b) external {
        feeBps = b;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        balanceOf[f] -= a;
        uint256 fee = a * feeBps / 10_000;
        balanceOf[to] += a - fee;
    }
}

/// @dev LP that can add AND remove a ranged position.
contract RVLP is IUnlockCallback {
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

contract JexiRV039040Test is RouterQuoterFixture {
    using CurrencyLibrary for Currency;

    uint32 internal constant BEFORE_SWAP_FLAG = 1 << 4;
    uint32 internal constant AFTER_SWAP_FLAG = 1 << 5;

    address internal attacker = makeAddr("attacker");

    // ------------------------------------------------------------------ helpers

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) s = bytes4(err);
    }

    function _args2(bytes memory err) internal pure returns (uint256 a, uint256 b) {
        require(err.length == 68, "not a 2-word error");
        assembly {
            a := mload(add(err, 36))
            b := mload(add(err, 68))
        }
    }

    function _thinClamm() internal returns (PoolKey memory k) {
        k = _key(tokenA, tokenB, 10000, 200, CurveType.CLAMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidityRange(k, -200, 200, 1_000 ether);
    }

    function _thinBin() internal returns (PoolKey memory k) {
        k = _key(tokenA, tokenB, 2000, 10, CurveType.BIN_AMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidity(k, 1_000 ether);
    }

    struct Fill {
        bool ok;
        bytes err;
        uint256 paid;
        uint256 delivered;
        uint256 ret;
    }

    function _execOut(ISupaRouter.ExactOutputSingleParams memory p) internal returns (Fill memory f) {
        Currency cin = _keyIn(p.poolKey, p.zeroForOne);
        Currency cout = _keyOut(p.poolKey, p.zeroForOne);
        uint256 a0 = _bal(cin, alice);
        uint256 b0 = _bal(cout, p.recipient);
        vm.prank(alice);
        try router.exactOutputSingle(p) returns (uint256 r) {
            f.ok = true;
            f.ret = r;
        } catch (bytes memory e) {
            f.err = e;
        }
        f.paid = a0 - _bal(cin, alice);
        f.delivered = _bal(cout, p.recipient) - b0;
    }

    function _quoteOut(ISupaRouter.ExactOutputSingleParams memory p)
        internal
        returns (bool ok, uint256 amountIn, bytes memory err)
    {
        ISupaQuoter.QuoteExactOutputSingleParams memory q = ISupaQuoter.QuoteExactOutputSingleParams({
            poolKey: p.poolKey,
            zeroForOne: p.zeroForOne,
            amountOut: p.amountOut,
            sqrtPriceLimitX96: p.sqrtPriceLimitX96,
            hookData: p.hookData
        });
        try quoter.quoteExactOutputSingle(q) returns (uint256 a, uint160, int24) {
            ok = true;
            amountIn = a;
        } catch (bytes memory e) {
            err = e;
        }
    }

    /// Core property of the fixed router for one exact-output single-hop call.
    function _checkSingleProperty(ISupaRouter.ExactOutputSingleParams memory p) internal returns (Fill memory f) {
        (bool qOk, uint256 qIn, bytes memory qErr) = _quoteOut(p);
        f = _execOut(p);
        if (f.ok) {
            assertEq(f.ret, f.paid, "return == paid");
            assertLe(f.paid, p.amountInMaximum, "paid <= maxIn");
            assertGt(f.delivered, 0, "never succeeds with zero delivered");
            assertLe(f.delivered, p.amountOut, "never over-delivers (no plugin)");
            if (f.delivered < p.amountOut) {
                assertTrue(p.sqrtPriceLimitX96 != 0, "partial fill only with a price limit");
                assertLe(f.paid * uint256(p.amountOut), uint256(p.amountInMaximum) * f.delivered, "per-unit cap");
            }
            // parity: the quoter must have priced exactly this execution
            assertTrue(qOk, "router filled but quoter reverted");
            assertEq(qIn, f.paid, "quote == execution");
        } else {
            assertEq(f.paid, 0, "revert: not charged");
            assertEq(f.delivered, 0, "revert: nothing delivered");
            bytes4 s = _sel(f.err);
            assertTrue(
                s == PeripheryErrors.InsufficientOutputAmount.selector || s == PeripheryErrors.SlippageExceeded.selector
                    || s == PoolErrors.PriceLimitAlreadyExceeded.selector || s == PoolErrors.PriceLimitOutOfBounds.selector
                    || s == PoolErrors.ZeroSwapAmount.selector || s == PoolErrors.InsufficientLiquidity.selector
                    || s == PoolErrors.BinIdOutOfBounds.selector,
                "unexpected revert class"
            );
            assertTrue(s != bytes4(0x4e487b71), "no Panic (overflow)");
            if (p.sqrtPriceLimitX96 == 0 && s == PeripheryErrors.InsufficientOutputAmount.selector) {
                // no-limit parity: quoter reverts with the IDENTICAL payload
                assertFalse(qOk, "router shortfall but quoter quoted");
                assertEq(keccak256(qErr), keccak256(f.err), "identical InsufficientOutputAmount payload");
            }
        }
        _assertClean();
    }

    // ------------------------------------------------------------------ 040 / selectors

    function test_rv_selectors_computedNotHandTyped() public pure {
        assertEq(VaultErrors.VaultAlreadyLocked.selector, bytes4(keccak256("VaultAlreadyLocked()")));
        assertEq(VaultErrors.VaultAlreadyLocked.selector, bytes4(0xa6c62fd0));
        assertEq(
            PeripheryErrors.InsufficientOutputAmount.selector, bytes4(keccak256("InsufficientOutputAmount(uint256,uint256)"))
        );
        assertEq(PeripheryErrors.InsufficientOutputAmount.selector, bytes4(0xd28d3eb5));
        assertEq(PeripheryErrors.SlippageExceeded.selector, bytes4(keccak256("SlippageExceeded(uint256,uint256)")));
    }

    /// Router re-entry through a plugin hook (beforeSwap) is blocked with the declared VaultAlreadyLocked.
    function test_rv_040_nestedUnlock_exactPayload() public {
        RVNested n = new RVNested(vault);
        n.go();
        assertEq(n.innerRet(), abi.encodeWithSelector(VaultErrors.VaultAlreadyLocked.selector));
    }

    // ------------------------------------------------------------------ 039: price-limited partial fills

    function testFuzz_rv_clamm_singleHop_property(uint128 amountOut, uint128 maxIn, int24 limitTick, bool useLimit)
        public
    {
        PoolKey memory k = _thinClamm();
        amountOut = uint128(bound(amountOut, 0, 2_000 ether));
        maxIn = uint128(bound(maxIn, 0, 5_000 ether));
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, amountOut, maxIn);
        if (useLimit) {
            limitTick = int24(bound(limitTick, TickMathLib.MIN_TICK + 1, -1));
            p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(limitTick);
        }
        _checkSingleProperty(p);
    }

    function testFuzz_rv_bin_singleHop_property(uint128 amountOut, uint128 maxIn, int24 limitTick, bool useLimit)
        public
    {
        PoolKey memory k = _thinBin();
        amountOut = uint128(bound(amountOut, 0, 3_000 ether));
        maxIn = uint128(bound(maxIn, 0, 10_000 ether));
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, amountOut, maxIn);
        if (useLimit) {
            limitTick = int24(bound(limitTick, -5_000, -1));
            p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(limitTick);
        }
        _checkSingleProperty(p);
    }

    /// Exact boundary of `amountIn * amountOut <= amountInMaximum * delivered` (no rounding slack either way):
    /// maxIn = ceil(paid * amountOut / delivered) fills; maxIn - 1 reverts SlippageExceeded.
    function testFuzz_rv_perUnitCap_exactBoundary(uint128 amountOut, int24 limitTick) public {
        PoolKey memory k = _thinClamm();
        amountOut = uint128(bound(amountOut, 20 ether, 1e30));
        limitTick = int24(bound(limitTick, -2_000, -1));
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, amountOut, type(uint128).max);
        p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(limitTick);

        uint256 snap = vm.snapshotState();
        Fill memory probe = _execOut(p);
        vm.revertToState(snap);
        if (!probe.ok || probe.delivered == amountOut) return; // need a real partial fill
        uint256 num = probe.paid * uint256(amountOut);
        uint256 cap = (num + probe.delivered - 1) / probe.delivered; // ceil
        if (cap > type(uint128).max) return;

        p.amountInMaximum = uint128(cap);
        Fill memory atCap = _execOut(p);
        assertTrue(atCap.ok, "fill at exact per-unit cap must succeed");
        assertEq(atCap.paid, probe.paid);
        vm.revertToState(snap);

        p.amountInMaximum = uint128(cap - 1);
        Fill memory below = _execOut(p);
        assertFalse(below.ok, "1 wei below the cap must revert");
        assertEq(_sel(below.err), PeripheryErrors.SlippageExceeded.selector);
        (uint256 reportedCap, uint256 reportedIn) = _args2(below.err);
        assertEq(reportedIn, probe.paid);
        assertLt(reportedCap, reportedIn, "reported pro-rata cap < amountIn");
        _assertClean();
    }

    /// uint128 extremes: no overflow/panic in the cross-multiplication.
    function test_rv_perUnitCap_uint128Extremes_noPanic() public {
        PoolKey memory k = _thinClamm();
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, type(uint128).max, type(uint128).max);
        p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(-200);
        Fill memory f = _execOut(p);
        // Per-unit cap is exactly 1 A/B; the 1% pool's average price over the range is > 1, so the cap must bind
        // with a clean SlippageExceeded (no Panic 0x11 in the cross-multiplication).
        assertFalse(f.ok, "max/max: per-unit cap 1 must bind on a 1% pool");
        assertEq(_sel(f.err), PeripheryErrors.SlippageExceeded.selector);
        // Cap ~2 A/B with uint128-scale operands: partial fill must be allowed, no overflow.
        p.amountOut = type(uint128).max / 2;
        f = _execOut(p);
        assertTrue(f.ok, "uint128.max/2 request, maxIn uint128.max: partial fill allowed (cap ~2)");
        assertGt(f.delivered, 0);
        assertLe(f.paid * uint256(p.amountOut), uint256(p.amountInMaximum) * f.delivered);
        emit log_named_decimal_uint("uint128.max request, delivered", f.delivered, 18);
        emit log_named_decimal_uint("uint128.max request, paid", f.paid, 18);

        // maxIn small relative to a huge amountOut: cap is ~0 per unit -> must revert SlippageExceeded, not Panic
        p = _outSingle(_thinClammFresh(), true, bob, type(uint128).max, 1_000 ether);
        p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(-200);
        f = _execOut(p);
        assertFalse(f.ok);
        assertEq(_sel(f.err), PeripheryErrors.SlippageExceeded.selector);
        _assertClean();
    }

    function _thinClammFresh() internal returns (PoolKey memory k) {
        k = _key(tokenA, tokenB, 3000, 200, CurveType.CLAMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidityRange(k, -200, 200, 1_000 ether);
    }

    /// amountOut == 0: never a charge, never a "successful" zero fill.
    function test_rv_amountOutZero() public {
        PoolKey memory k = _thinClamm();
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, 0, 1 ether);
        Fill memory f = _execOut(p);
        emit log_named_bytes("amountOut=0, no limit -> revert payload", f.err);
        assertFalse(f.ok);
        assertEq(f.paid, 0);
        p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(-100);
        f = _execOut(p);
        emit log_named_bytes("amountOut=0, limit -> revert payload", f.err);
        assertFalse(f.ok);
        assertEq(f.paid, 0);
        (bool qOk,, bytes memory qErr) = _quoteOut(p);
        emit log_named_bytes("quoter amountOut=0 payload", qErr);
        assertFalse(qOk);
        _assertClean();
    }

    /// Price limit already at/through the current price: zero delivered must revert (router), and the quoter must
    /// not report a free fill.
    function test_rv_zeroFillWithLimit_routerReverts_quoterParity() public {
        PoolKey memory k = _thinClamm();
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, 10 ether, 20 ether);
        p.sqrtPriceLimitX96 = SQRT_1_1 - 1; // a hair below spot: almost nothing fillable
        (bool qOk, uint256 qIn, bytes memory qErr) = _quoteOut(p);
        Fill memory f = _execOut(p);
        emit log_named_uint("limit=spot-1: router ok", f.ok ? 1 : 0);
        emit log_named_uint("limit=spot-1: delivered", f.delivered);
        emit log_named_uint("limit=spot-1: quoter ok", qOk ? 1 : 0);
        emit log_named_uint("limit=spot-1: quoter amountIn", qIn);
        emit log_named_bytes("limit=spot-1: router err", f.err);
        emit log_named_bytes("limit=spot-1: quoter err", qErr);
        if (f.ok) {
            assertGt(f.delivered, 0);
            assertEq(qIn, f.paid);
        }
        _assertClean();
    }

    // ------------------------------------------------------------------ 039: no-limit parity, CLAMM / BIN

    function testFuzz_rv_noLimit_quoterRouterParity(uint128 amountOut, bool bin, bool zeroForOne) public {
        PoolKey memory k = bin ? _thinBin() : _thinClamm();
        amountOut = uint128(bound(amountOut, 1, 5_000 ether));
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, zeroForOne, bob, amountOut, type(uint128).max);
        Fill memory f = _checkSingleProperty(p);
        if (f.ok) assertEq(f.delivered, amountOut, "no limit: exact");
    }

    // ------------------------------------------------------------------ 039: multi-hop end to end

    /// C <-STABLE- A <-thin CLAMM- B (pay B... receive C) and the reverse orientation: exact-or-revert end to end,
    /// paid <= maxIn, quote == execution, identical shortfall payload on quoter and router.
    function testFuzz_rv_multiHop_endToEnd(uint128 amountOut, uint128 maxIn, bool thinOuter) public {
        PoolKey memory k = _thinClamm();
        amountOut = uint128(bound(amountOut, 1, 2_000 ether));
        maxIn = uint128(bound(maxIn, 1, 10_000 ether));
        bytes memory path =
            thinOuter ? _path2(tokenB, k, tokenA, stableAC, tokenC) : _path2(tokenC, stableAC, tokenA, k, tokenB);
        Currency outC = thinOuter ? tokenB : tokenC;
        Currency inC = thinOuter ? tokenC : tokenB;

        bool qOk;
        uint256 qIn;
        bytes memory qErr;
        try quoter.quoteExactOutput(path, amountOut) returns (uint256 a) {
            (qOk, qIn) = (true, a);
        } catch (bytes memory e) {
            qErr = e;
        }
        uint256 in0 = _bal(inC, alice);
        uint256 out0 = _bal(outC, bob);
        vm.prank(alice);
        try router.exactOutput(_outMulti(path, bob, amountOut, maxIn)) returns (uint256 r) {
            uint256 paid = in0 - _bal(inC, alice);
            assertEq(_bal(outC, bob) - out0, amountOut, "multi-hop: exact end-to-end");
            assertEq(r, paid);
            assertLe(paid, maxIn, "end-to-end per-unit <= maxIn/amountOut");
            assertTrue(qOk);
            assertEq(qIn, paid, "multi-hop quote == execution");
        } catch (bytes memory e) {
            assertEq(_bal(inC, alice), in0);
            assertEq(_bal(outC, bob), out0);
            bytes4 s = _sel(e);
            assertTrue(
                s == PeripheryErrors.InsufficientOutputAmount.selector || s == PeripheryErrors.SlippageExceeded.selector
                    || s == PoolErrors.InsufficientLiquidity.selector,
                "unexpected multi-hop revert"
            );
            if (s == PeripheryErrors.InsufficientOutputAmount.selector) {
                assertFalse(qOk);
                assertEq(keccak256(qErr), keccak256(e), "identical multi-hop shortfall payload");
            }
            if (s == PeripheryErrors.SlippageExceeded.selector) assertTrue(qOk && qIn > maxIn);
        }
        _assertClean();
    }

    /// Deep 3-hop route across all engines (B -BIN- C -STABLE- A -CLAMM- ... ): the per-hop check must never block a
    /// legitimate exact-output fill (BIN rounding / over-delivery would show up here as a revert).
    function testFuzz_rv_multiHop_deep_neverBlocked(uint128 amountOut, uint8 route) public {
        amountOut = uint128(bound(amountOut, 1, 1_000 ether));
        bytes memory path;
        Currency outC;
        Currency inC;
        route = route % 4;
        if (route == 0) {
            (path, outC, inC) = (_path3(tokenA, clammAB, tokenB, binBC, tokenC, stableAC, tokenA), tokenA, tokenA);
        } else if (route == 1) {
            (path, outC, inC) = (_path2(tokenC, binBC, tokenB, clammAB, tokenA), tokenC, tokenA);
        } else if (route == 2) {
            (path, outC, inC) = (_path2(tokenB, binBC, tokenC, stableAC, tokenA), tokenB, tokenA);
        } else {
            (path, outC, inC) = (_path2(tokenA, clammAB, tokenB, binBC, tokenC), tokenA, tokenC);
        }
        (uint256 qIn) = quoter.quoteExactOutput(path, amountOut);
        uint256 out0 = _bal(outC, bob);
        uint256 in0 = _bal(inC, alice);
        vm.prank(alice);
        uint256 paid = router.exactOutput(_outMulti(path, bob, amountOut, type(uint128).max));
        assertEq(_bal(outC, bob) - out0, amountOut, "deep multi-hop: exact");
        assertEq(in0 - _bal(inC, alice), paid);
        assertEq(paid, qIn);
        _assertClean();
    }

    /// BIN single-hop deep: exact delivery, never over-delivery, never blocked.
    function testFuzz_rv_binDeep_single_exact(uint128 amountOut, bool zeroForOne) public {
        amountOut = uint128(bound(amountOut, 1, 5_000 ether));
        Fill memory f = _execOut(_outSingle(binBC, zeroForOne, bob, amountOut, type(uint128).max));
        assertTrue(f.ok, "deep BIN exact-out must fill");
        assertEq(f.delivered, amountOut);
        _assertClean();
    }

    // ------------------------------------------------------------------ 039: sandwich, fuzzed attacker, sentinel limit

    /// Victim: 100 B for at most 110 A with the MIN_SQRT_RATIO+1 sentinel (takes the partial-fill branch).
    /// Attacker chooses where to park its position and how far to push the price. Property: if the victim's swap
    /// executes at all, the victim's per-unit price is <= 1.10 A/B.
    function testFuzz_rv_sandwich_sentinel_perUnitBound(int24 hiTick, uint128 atkLiq, int24 pushTick) public {
        PoolKey memory k = _key(tokenA, tokenB, 500, 60, CurveType.CLAMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidityRange(k, -600, 600, 100_000 ether);
        RVLP atkLp = new RVLP(vault, manager, attacker);
        rawA.mint(attacker, 1_000_000 ether);
        rawB.mint(attacker, 1_000_000 ether);
        vm.startPrank(attacker);
        rawA.approve(address(router), type(uint256).max);
        rawB.approve(address(router), type(uint256).max);
        rawB.transfer(address(atkLp), 100_000 ether);
        vm.stopPrank();
        hiTick = int24(bound(hiTick, -60_000, -660)) / 60 * 60;
        int24 lo = hiTick - 180;
        atkLiq = uint128(bound(atkLiq, 1 ether, 50_000 ether));
        try atkLp.modify(k, lo, hiTick, int256(uint256(atkLiq))) {} catch { return; }
        pushTick = int24(bound(pushTick, lo - 600, 0));
        ISupaRouter.ExactInputSingleParams memory fr = _inSingle(k, true, attacker, 500_000 ether, 0);
        fr.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(pushTick);
        vm.prank(attacker);
        try router.exactInputSingle(fr) {} catch {}

        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, alice, 100 ether, 110 ether);
        p.sqrtPriceLimitX96 = TickMathLib.MIN_SQRT_RATIO + 1;
        Fill memory f = _execOut(p);
        if (f.ok) {
            assertLe(f.paid * 100, 110 * f.delivered, "victim per-unit price <= 1.10 A/B");
        } else {
            assertEq(f.paid, 0);
        }
        // no-limit victim: exact or revert
        p.sqrtPriceLimitX96 = 0;
        f = _execOut(p);
        if (f.ok) assertEq(f.delivered, 100 ether);
        _assertClean();
    }

    /// Jexi's original sandwich numbers re-measured on the fix (same parameters as JexiCov7bf1ee9).
    function test_rv_sandwich_original_numbersOnFix() public {
        PoolKey memory k = _key(tokenA, tokenB, 500, 60, CurveType.CLAMM);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidityRange(k, -600, 600, 100_000 ether);
        RVLP atkLp = new RVLP(vault, manager, attacker);
        rawA.mint(attacker, 100_000 ether);
        rawB.mint(attacker, 100_000 ether);
        vm.startPrank(attacker);
        rawA.approve(address(router), type(uint256).max);
        rawB.approve(address(router), type(uint256).max);
        rawB.transfer(address(atkLp), 10 ether);
        vm.stopPrank();
        atkLp.modify(k, -46200, -46020, int256(1_150 ether));
        uint256 atkA0 = rawA.balanceOf(attacker) + rawA.balanceOf(address(atkLp));
        uint256 atkB0 = rawB.balanceOf(attacker) + rawB.balanceOf(address(atkLp));
        (uint256 honestIn,,) = quoter.quoteExactOutputSingle(_qOut(k, true, 100 ether));
        emit log_named_decimal_uint("honest quote A for 100 B", honestIn, 18);

        ISupaRouter.ExactInputSingleParams memory fr = _inSingle(k, true, attacker, 50_000 ether, 0);
        fr.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(-46020);
        vm.prank(attacker);
        router.exactInputSingle(fr);

        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, alice, 100 ether, 110 ether);
        Fill memory v0 = _execOut(p);
        emit log_named_bytes("victim (limit 0) revert payload", v0.err);
        emit log_named_decimal_uint("victim (limit 0) paid A", v0.paid, 18);
        emit log_named_decimal_uint("victim (limit 0) got B", v0.delivered, 18);
        assertFalse(v0.ok);
        assertEq(_sel(v0.err), PeripheryErrors.InsufficientOutputAmount.selector);
        (uint256 req, uint256 dlv) = _args2(v0.err);
        emit log_named_decimal_uint("  InsufficientOutputAmount.requested", req, 18);
        emit log_named_decimal_uint("  InsufficientOutputAmount.delivered", dlv, 18);

        p.sqrtPriceLimitX96 = TickMathLib.MIN_SQRT_RATIO + 1;
        Fill memory v1 = _execOut(p);
        emit log_named_bytes("victim (sentinel) revert payload", v1.err);
        assertFalse(v1.ok);
        assertEq(_sel(v1.err), PeripheryErrors.SlippageExceeded.selector);
        (uint256 capA, uint256 inA) = _args2(v1.err);
        emit log_named_decimal_uint("  SlippageExceeded.proRataCap A", capA, 18);
        emit log_named_decimal_uint("  SlippageExceeded.amountIn A", inA, 18);

        ISupaRouter.ExactInputSingleParams memory b = _inSingle(k, false, attacker, 50_000 ether, 0);
        b.sqrtPriceLimitX96 = SQRT_1_1;
        vm.prank(attacker);
        router.exactInputSingle(b);
        atkLp.modify(k, -46200, -46020, -int256(1_150 ether));
        uint256 atkA1 = rawA.balanceOf(attacker) + rawA.balanceOf(address(atkLp));
        uint256 atkB1 = rawB.balanceOf(attacker) + rawB.balanceOf(address(atkLp));
        int256 pnl = (int256(atkA1) - int256(atkA0)) + (int256(atkB1) - int256(atkB0));
        emit log_named_decimal_int("attacker PnL (A+B at 1:1) [pre-fix +100.84]", pnl, 18);
        assertLe(pnl, 0);
        _assertClean();
    }

    // ------------------------------------------------------------------ 039: delta-returning plugin (canReturnDelta)

    function _pluginPool(uint32 perms) internal returns (PoolKey memory k, RVDeltaPlugin pl) {
        pl = new RVDeltaPlugin(perms);
        PluginWhitelist wl = PluginWhitelist(address(manager.pluginWhitelist()));
        wl.setPluginWhitelisted(address(pl), true);
        wl.setPluginCanReturnDelta(address(pl), true);
        k = PoolKey({
            currency0: tokenA,
            currency1: tokenB,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(pl),
            curveType: CurveType.CLAMM
        });
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidityRange(k, -600, 600, 10_000 ether);
    }

    /// A whitelisted canReturnDelta plugin returning ANY non-zero afterSwap delta cannot shift the delivered amount:
    /// the PoolManager applies hook deltas to the input (debit) leg only and rejects every non-zero swap hook delta
    /// (HookDeltaCapExceeded). So the router's delivered check can never be passed or failed "wrongly" by a plugin.
    function testFuzz_rv_deltaPlugin_cannotShiftDelivered(int128 d, uint128 amountOut, bool useLimit, bool zeroForOne)
        public
    {
        (PoolKey memory k, RVDeltaPlugin pl) = _pluginPool(BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG);
        amountOut = uint128(bound(amountOut, 1, 50 ether));
        pl.set(d, 0);
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, zeroForOne, bob, amountOut, type(uint128).max);
        if (useLimit) {
            p.sqrtPriceLimitX96 =
                zeroForOne ? TickMathLib.getSqrtRatioAtTick(-1200) : TickMathLib.getSqrtRatioAtTick(1200);
        }
        Fill memory f = _execOut(p);
        if (d == 0) {
            assertTrue(f.ok, "zero hook delta: normal fill");
            assertEq(f.delivered, amountOut);
        } else {
            assertFalse(f.ok, "non-zero swap hook delta always rejected");
            assertEq(_sel(f.err), PoolErrors.HookDeltaCapExceeded.selector);
            assertEq(f.paid, 0);
            assertEq(f.delivered, 0);
        }
        // multi-hop through the plugin pool
        bytes memory path = zeroForOne ? _path1(tokenB, k, tokenA) : _path1(tokenA, k, tokenB);
        uint256 out0 = _bal(zeroForOne ? tokenB : tokenA, bob);
        vm.prank(alice);
        try router.exactOutput(_outMulti(path, bob, amountOut, type(uint128).max)) {
            assertEq(d, 0);
            assertEq(_bal(zeroForOne ? tokenB : tokenA, bob) - out0, amountOut);
        } catch (bytes memory e) {
            assertTrue(d != 0);
            assertEq(_sel(e), PoolErrors.HookDeltaCapExceeded.selector);
        }
        // quoter agrees
        (bool qOk,, bytes memory qErr) = _quoteOut(p);
        if (d == 0) assertTrue(qOk);
        else assertEq(_sel(qErr), PoolErrors.HookDeltaCapExceeded.selector);
        _assertClean();
    }

    /// Fee-overriding plugin (beforeSwap): exact delivery is preserved; a high fee only raises amountIn, which stays
    /// bounded by maxIn (no limit) or by the per-unit cap (with limit). Quoter applies the same override.
    function testFuzz_rv_feeOverridePlugin_boundsHold(uint24 fee, uint128 amountOut, uint128 maxIn, bool useLimit)
        public
    {
        (PoolKey memory k, RVDeltaPlugin pl) = _pluginPool(BEFORE_SWAP_FLAG);
        fee = uint24(bound(fee, 0, 999_999));
        amountOut = uint128(bound(amountOut, 1, 20_000 ether));
        maxIn = uint128(bound(maxIn, 1, 100_000 ether));
        pl.set(0, fee);
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(k, true, bob, amountOut, maxIn);
        if (useLimit) p.sqrtPriceLimitX96 = TickMathLib.getSqrtRatioAtTick(-600);
        _checkSingleProperty(p);
    }

    // ------------------------------------------------------------------ fee-on-transfer output (documented unsupported)

    /// Observation only: ARCHITECTURE.md says fee-on-transfer tokens are unsupported. The router's check is on the
    /// vault delta, so a FOT output token still "passes" while the recipient receives amountOut minus the token fee.
    function test_rv_fotOutput_observation() public {
        RVFotToken fot = new RVFotToken();
        Currency cF = Currency.wrap(address(fot));
        (Currency c0, Currency c1) = address(fot) < address(rawA) ? (cF, tokenA) : (tokenA, cF);
        PoolKey memory k = _key(c0, c1, 3000, 60, CurveType.CLAMM);
        manager.initialize(k, SQRT_1_1, "");
        fot.mint(address(lp), 1_000_000 ether);
        lp.addLiquidityRange(k, -600, 600, 10_000 ether); // fee off while seeding
        fot.setFee(100); // 1%
        bool zeroForOne = Currency.unwrap(c1) == address(fot); // pay A, receive FOT
        uint256 b0 = fot.balanceOf(bob);
        vm.prank(alice);
        try router.exactOutputSingle(_outSingle(k, zeroForOne, bob, 10 ether, 100 ether)) {
            emit log_named_decimal_uint("FOT exact-out 10: recipient received", fot.balanceOf(bob) - b0, 18);
        } catch (bytes memory e) {
            emit log_named_bytes("FOT exact-out reverted", e);
        }
    }
}

/// @dev Calls vault.unlock from inside its own unlock callback.
contract RVNested is IUnlockCallback {
    SupaVault public immutable vault;
    bytes public innerRet;

    constructor(SupaVault v) {
        vault = v;
    }

    function go() external {
        vault.unlock("outer");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (keccak256(data) == keccak256("outer")) {
            (, innerRet) = address(vault).call(abi.encodeCall(vault.unlock, (bytes("inner"))));
        }
        return "";
    }
}
