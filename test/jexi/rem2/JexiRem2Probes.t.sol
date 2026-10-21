// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// PORT (remediation-3): Jexi's remediation-2 probes (apus-ops/security-findings/supadex/tests/rem2/JexiRem2Probes.t.sol,
// pinned 192664b). Exploit-positive probes are INVERTED to assert the fix: 023 (push-then-return), 024 (no stranded
// principal), 025 (multi-hop dust), 026 (hostile stable init). STABLE keys follow ADR-0007 rev. 2: tickSpacing == 1,
// with A passed as an init param. Stack-heavy bodies are split into helpers so the legacy (coverage) profile compiles.
// Assertions are not weakened. Every change is marked PORT.

// Jexi remediation-2 probes (192664b). Local only; not part of Ultron's repo.
import {Test, console2, Vm} from "forge-std/Test.sol";
import "../JexiSupaDex.t.sol";
import {JSwapProbe} from "./JexiProbe.t.sol";
import {BaseHook} from "../../../contract/plugins/external/BaseHook.sol";
import {PluginDispatcher} from "../../../contract/core/PluginDispatcher.sol";
import {BalanceDelta, toBalanceDelta} from "../../../contract/types/BalanceDelta.sol";
import {IAggregatorV3} from "../../../contract/interfaces/external/IAggregatorV3.sol";
import {PoolErrors} from "../../../contract/errors/PoolErrors.sol";
import {PoolIdLibrary} from "../../../contract/types/PoolId.sol";
import {TreeBitmapLib} from "../../../contract/libraries/TreeBitmapLib.sol";
import {FullMathLib} from "../../../contract/libraries/FullMathLib.sol";

/// Third-party plugin that haircuts 10% of LP principal on removal (principal hookDelta).
contract JHaircutPlugin is BaseHook {
    constructor(IPoolManager m) BaseHook(m) {}

    function getPluginPermissions() public pure override returns (uint32) {
        return PluginDispatcher.AFTER_MODIFY_LIQUIDITY_FLAG;
    }

    function afterModifyLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta hookDelta, BalanceDelta) {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        int128 h0 = a0 < 0 ? -a0 / 10 : int128(0);
        int128 h1 = a1 < 0 ? -a1 / 10 : int128(0);
        return (this.afterModifyLiquidity.selector, toBalanceDelta(h0, h1), BalanceDelta.wrap(0));
    }
}

contract JFeed is IAggregatorV3 {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract JToken6 {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Generic actor for arbitrary currency pairs (nets both currencies of op[0].key).
contract JPairActor is IUnlockCallback {
    SupaVault public immutable vault;
    SupaPoolManager public immutable pm;

    constructor(SupaVault v, SupaPoolManager m) {
        vault = v;
        pm = m;
    }

    function exec(JFlashActor.Op[] memory ops) external {
        vault.unlock(abi.encode(ops));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        JFlashActor.Op[] memory ops = abi.decode(data, (JFlashActor.Op[]));
        for (uint256 i; i < ops.length; i++) {
            JFlashActor.Op memory o = ops[i];
            if (o.kind == 0) {
                pm.modifyLiquidity(
                    o.key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: o.lo, tickUpper: o.hi, liquidityDelta: o.amt, salt: 0
                    }),
                    ""
                );
            } else {
                pm.swap(
                    o.key,
                    IPoolManager.SwapParams({zeroForOne: o.zeroForOne, amountSpecified: o.amt, sqrtPriceLimitX96: 0}),
                    ""
                );
            }
        }
        _net(ops[0].key.currency0);
        _net(ops[0].key.currency1);
        return "";
    }

    function _net(Currency c) internal {
        int256 d = vault.getCurrencyDelta(address(this), c);
        if (d < 0) {
            vault.sync(c);
            JToken6(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}

contract TreeHarness {
    TreeBitmapLib.Tree t;

    function add(uint24 k) external {
        TreeBitmapLib.add(t, k);
    }

    function remove(uint24 k) external {
        TreeBitmapLib.remove(t, k);
    }

    function below(uint24 k) external view returns (bool, uint24) {
        return TreeBitmapLib.nextBelow(t, k);
    }

    function above(uint24 k) external view returns (bool, uint24) {
        return TreeBitmapLib.nextAbove(t, k);
    }
}

contract JexiRem2ProbesTest is JexiSupaDexTest {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------ (b) CLAMM exact-in dust + router multi-hop
    function test_b_exactInDust_singleAndMultiHop() public {
        // pool with several adjacent ranges so swaps cross initialized ticks
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(0));
        pm.initialize(k, SQRT_1_1, "");
        JFlashActor lp = _actor(1e30);
        lp.exec(_one(_op(0, k, -600, 600, 1e24, false)));
        lp.exec(_one(_op(0, k, -1200, -600, 3e23, false)));
        lp.exec(_one(_op(0, k, 600, 1800, 7e23, false)));
        JSwapProbe p = new JSwapProbe(vault, pm);
        uint256 mism;
        uint256 maxLeft;
        for (uint256 i = 1; i <= 400; i++) {
            int256 amt = int256(uint256(keccak256(abi.encode("d", i))) % 3e22) + 1e9;
            int128 used = p.probe(k, i % 2 == 0, amt);
            if (int256(used) != amt) {
                mism++;
                uint256 left = uint256(amt - int256(used));
                if (left > maxLeft) maxLeft = left;
            }
        }
        console2.log("single-pool exact-in with unconsumed input (of 400):", mism);
        console2.log("max unconsumed (wei):", maxLeft);

        // two-hop path t0 -> t1 -> C on the same kind of pools
        JToken c = new JToken("C");
        Currency cc = Currency.wrap(address(c));
        PoolKey memory k2 = address(c) > address(t1)
            ? PoolKey({
                currency0: c1, currency1: cc, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
            })
            : PoolKey({
                currency0: cc, currency1: c1, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
            });
        pm.initialize(k2, SQRT_1_1, "");
        JFlashActor lp2 = new JFlashActor(vault, pm);
        t1.mint(address(lp2), 1e30);
        c.mint(address(lp2), 1e30);
        lp2.exec(_one(_op(0, k2, -600, 600, 1e24, false)));
        lp2.exec(_one(_op(0, k2, 600, 1800, 7e23, false)));
        lp2.exec(_one(_op(0, k2, -1200, -600, 3e23, false)));
        bytes memory path = abi.encodePacked(
            c0, uint24(3000), int24(60), address(0), uint8(0), c1, uint24(3000), int24(60), address(0), uint8(0), cc
        );
        (uint256 ok, uint256 fail, bytes4 firstSel) = _multiHopLoop(path, "mh", 150);
        console2.log("2-hop exactInput ok / reverted (of 150):", ok, fail);
        console2.logBytes4(firstSel);
        // PORT: inverted for APUS-SUPADEX-025 (router pays / forwards the consumed amount).
        assertEq(fail, 0, "025: 2-hop exactInput must never revert on hop dust");

        // PORT: three-hop t0 -> t1 -> C -> D
        JToken d = new JToken("D");
        Currency cd = Currency.wrap(address(d));
        PoolKey memory k3 = address(d) > address(c)
            ? PoolKey({
                currency0: cc, currency1: cd, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
            })
            : PoolKey({
                currency0: cd, currency1: cc, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
            });
        pm.initialize(k3, SQRT_1_1, "");
        JPairActor lp3 = new JPairActor(vault, pm);
        c.mint(address(lp3), 1e30);
        d.mint(address(lp3), 1e30);
        lp3.exec(_one(_op(0, k3, -600, 600, 1e24, false)));
        lp3.exec(_one(_op(0, k3, 600, 1800, 7e23, false)));
        lp3.exec(_one(_op(0, k3, -1200, -600, 3e23, false)));
        bytes memory path3 = abi.encodePacked(path, uint24(3000), int24(60), address(0), uint8(0), cd);
        (ok, fail, firstSel) = _multiHopLoop(path3, "mh3", 150);
        console2.log("3-hop exactInput ok / reverted (of 150):", ok, fail);
        assertEq(fail, 0, "025: 3-hop exactInput must never revert on hop dust");
        // the router never keeps a balance and leaves no open delta (a revert would have surfaced above)
        assertEq(t0.balanceOf(address(router)) + t1.balanceOf(address(router)) + c.balanceOf(address(router)), 0);
    }

    function _multiHopLoop(bytes memory path, string memory tag, uint256 n)
        internal
        returns (uint256 ok, uint256 fail, bytes4 firstSel)
    {
        for (uint256 i = 1; i <= n; i++) {
            uint256 snap = vm.snapshotState();
            uint128 amt = uint128(uint256(keccak256(abi.encode(tag, i))) % 3e22) + 1e9;
            try router.exactInput(
                ISupaRouter.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    amountIn: amt,
                    amountOutMinimum: 0,
                    payWithClaims: false,
                    receiveAsClaims: false,
                    deadline: block.timestamp
                })
            ) returns (
                uint256
            ) {
                ok++;
            } catch (bytes memory err) {
                fail++;
                if (firstSel == bytes4(0)) firstSel = bytes4(err);
            }
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------ (c) orphaned principal hook deltas
    function test_c_orphanedPrincipalHookDelta_notSweepable() public {
        JHaircutPlugin hp = new JHaircutPlugin(pm);
        vm.startPrank(address(timelock));
        wl.setPluginWhitelisted(address(hp), true);
        wl.setPluginCanReturnDelta(address(hp), true);
        vm.stopPrank();
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(hp));
        pm.initialize(k, SQRT_1_1, "");
        JFlashActor a = _actor(1e24);
        JFlashActor b = _actor(1e24);
        a.exec(_one(_op(0, k, -600, 600, 1e21, false)));
        b.exec(_one(_op(0, k, -600, 600, 1e21, false)));
        uint256 a0Before = t0.balanceOf(address(a));
        a.exec(_one(_op(0, k, -600, 600, -1e21, false)));
        uint256 got = t0.balanceOf(address(a)) - a0Before;
        console2.log("LP A received token0 on exit:", got);
        // PORT: inverted for APUS-SUPADEX-024. A's haircut is donated to the remaining in-range LP (B) and not stranded.
        uint256 b0Before = t0.balanceOf(address(b));
        uint256 pf0Before = pm.protocolFeesAccrued(c0);
        b.exec(_one(_op(0, k, -600, 600, -1e21, false)));
        uint256 gotB = t0.balanceOf(address(b)) - b0Before;
        console2.log("LP B received token0 on exit:", gotB);
        uint256 pfDelta = pm.protocolFeesAccrued(c0) - pf0Before;
        console2.log("B's haircut booked as protocol fees (pool empty):", pfDelta);
        // B gets 90% of (its principal + A's donated haircut): strictly more than A got for the same position
        assertGt(gotB, got, "A's haircut must reach B as fees");
        // the last LP's haircut has no LP to go to -> protocol fees (collectable), not orphaned
        assertGt(pfDelta, 0, "last haircut must become collectable protocol fees");
        // vault solvency
        assertGe(t0.balanceOf(address(vault)), vault.reservesOf(c0), "solvent");
    }

    // ------------------------------------------------------------ (d) LVR oracle: max-deviation fallback bypass
    function _lvrSetup() internal returns (PoolKey memory k, JFeed f) {
        k = _key(CurveType.CLAMM, 3000, 60, address(lvr));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e30).exec(_one(_op(0, k, -60000, 60000, 1e24, false)));
        vm.warp(block.timestamp + 1000);
        f = new JFeed();
        f.set(95_000_000); // feed 0.95 token1/token0, pool at 1.00 (pool above feed ~526 bps)
        vm.prank(address(timelock));
        lvr.setOracleConfig(k, f, false, 3600, 10_000, 30, 1000, 10_000);
        vm.warp(block.timestamp + 100);
        f.set(95_000_000);
    }

    function _lastSwapFee(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    function _swapLimit(PoolKey memory k, bool z, uint128 amt, uint160 lim) internal returns (uint24 fee) {
        vm.recordLogs();
        router.exactInputSingle(
            ISupaRouter.ExactInputSingleParams({
                poolKey: k,
                zeroForOne: z,
                recipient: address(this),
                amountIn: amt,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: lim,
                hookData: "",
                payWithClaims: false,
                receiveAsClaims: false,
                deadline: block.timestamp
            })
        );
        fee = _lastSwapFee(vm.getRecordedLogs());
    }

    function _valueAtFeed(int256 d0, int256 d1) internal pure returns (int256) {
        return d0 * 95 / 100 + d1;
    }

    function test_d_lvrMaxDeviationFallbackBypass() public {
        (PoolKey memory k,) = _lvrSetup();
        uint160 limFeed = 77222371092291862542049607147; // sqrt(0.95)*2^96
        uint160 limPush = 81570539407798004524693447148; // sqrt(1.06)*2^96 (pool ~11.6% above feed)
        uint256 snap = vm.snapshotState();

        // A: direct arbitrage to the feed price
        int256 b0 = int256(t0.balanceOf(address(this)));
        int256 b1 = int256(t1.balanceOf(address(this)));
        uint24 feeA = _swapLimit(k, true, 1e27, limFeed);
        int256 vA = _valueAtFeed(int256(t0.balanceOf(address(this))) - b0, int256(t1.balanceOf(address(this))) - b1);
        console2.log("A direct arb fee (pips):", feeA);
        console2.log("A direct arb P&L at feed price (wei t1):");
        console2.logInt(vA);
        vm.revertToState(snap);

        // B: push away from feed past maxDeviation, then arb back in the same block
        b0 = int256(t0.balanceOf(address(this)));
        b1 = int256(t1.balanceOf(address(this)));
        uint24 feePush = _swapLimit(k, false, 1e27, limPush);
        uint24 feeBack = _swapLimit(k, true, 1e27, limFeed);
        int256 vB = _valueAtFeed(int256(t0.balanceOf(address(this))) - b0, int256(t1.balanceOf(address(this))) - b1);
        console2.log("B push fee / return fee (pips):", feePush, feeBack);
        console2.log("B push+return P&L at feed price (wei t1):");
        console2.logInt(vB);
        // PORT: inverted for APUS-SUPADEX-023. The return leg beyond maxDeviation pays at least the capped surcharge.
        assertGe(feeBack, feeA, "023: return leg must pay >= the direct arbitrage fee");
        assertLe(vB, vA, "023: push-then-return must not beat the direct path");
    }

    function test_d_lvrFeedRevertsOrBurnsGas_fallsBackNotReverts() public {
        (PoolKey memory k, JFeed f) = _lvrSetup();
        // stale feed -> fallback floor (>= 10_000)
        vm.warp(block.timestamp + 4000);
        uint24 fee = _swapLimit(k, true, 1e18, 0);
        console2.log("stale feed fee:", fee);
        assertGe(fee, 10_000);
        f;
    }

    function test_d_lvrGasGuard_underfundedSwapReverts() public {
        (PoolKey memory k,) = _lvrSetup();
        // try a range of gas limits; record whether any succeed with a fallback fee (would be griefing)
        uint256 fallbackSuccess;
        uint256 okNormal;
        for (uint256 g = 150_000; g <= 600_000; g += 5_000) {
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            (bool ok,) = address(router).call{gas: g}(
                abi.encodeCall(
                    ISupaRouter.exactInputSingle,
                    (ISupaRouter.ExactInputSingleParams({
                            poolKey: k,
                            zeroForOne: true,
                            recipient: address(this),
                            amountIn: 1e18,
                            amountOutMinimum: 0,
                            sqrtPriceLimitX96: 0,
                            hookData: "",
                            payWithClaims: false,
                            receiveAsClaims: false,
                            deadline: block.timestamp
                        }))
                )
            );
            if (ok) {
                Vm.Log[] memory logs = vm.getRecordedLogs();
                bool fb;
                for (uint256 i; i < logs.length; i++) {
                    if (logs[i].topics[0] == keccak256("LVROracleFallback(bytes32,uint8)")) fb = true;
                }
                if (fb) fallbackSuccess++;
                else okNormal++;
            }
            vm.revertToState(snap);
        }
        console2.log("gas sweep: successes with fallback / normal:", fallbackSuccess, okNormal);
        assertEq(fallbackSuccess, 0, "under-funded call forced fallback");
    }

    // ------------------------------------------------------------ (e) stable decimals
    function _stable2(uint8 d0, uint8 d1, uint160 sqrtP, uint24 fee, int24 A)
        internal
        returns (PoolKey memory k, JToken6 a, JToken6 b)
    {
        a = new JToken6(d0);
        b = new JToken6(d1);
        if (address(a) > address(b)) (a, b) = (b, a);
        k = PoolKey({
            currency0: Currency.wrap(address(a)),
            currency1: Currency.wrap(address(b)),
            fee: fee,
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        }); // PORT
        pm.initializeWithParams(k, sqrtP, abi.encode(uint256(uint24(A))), "");
    }

    function test_e_stable24DecimalsRejected() public {
        JToken6 a = new JToken6(24);
        JToken6 b = new JToken6(18);
        if (address(a) > address(b)) (a, b) = (b, a);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(a)),
            currency1: Currency.wrap(address(b)),
            fee: 400,
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        }); // PORT
        vm.expectRevert();
        pm.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), "");
    }

    /// PORT: inverted for APUS-SUPADEX-026. A hostile creator price is ignored: the pool starts at the normalised peg
    /// and the first deposit succeeds.
    function test_e_stableInitPriceGriefing_firstDepositSucceeds() public {
        JToken6 a = new JToken6(6);
        JToken6 b = new JToken6(18);
        (JToken6 lo, JToken6 hi) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(lo)),
            currency1: Currency.wrap(address(hi)),
            fee: 400,
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        });
        pm.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), ""); // raw 1:1 = value 1e12:1 for 6/18 decimals
        // the stored price is the peg: raw token1 per token0 = 10^(d1 - d0)
        uint256 sqrtP = uint256(Slot0.unwrap(pm.getSlot0(k.toId()))) & ((uint256(1) << 160) - 1);
        uint256 expected = lo.decimals() == 6 ? uint256(1e6) << 96 : (uint256(1) << 96) / 1e6;
        assertApproxEqRel(sqrtP, expected, 1e12, "026: stable pool must start at the normalised peg");
        JPairActor lp = new JPairActor(vault, pm);
        lo.mint(address(lp), 1e40);
        hi.mint(address(lp), 1e40);
        lp.exec(_one(_op(0, k, 0, 0, int256(1e24), false)));
        assertEq(stable.getLiquidity(k.toId()), 1e24, "026: first deposit must succeed after a hostile init price");
        vm.expectRevert();
        pm.initializeWithParams(k, 79228162514264337593543950336000000, abi.encode(uint256(100)), "");
    }

    struct MixedCtx {
        JToken6 a;
        JToken6 b;
        PoolKey k;
        JPairActor t;
        bool xLow;
    }

    function _mixedPool(uint24 fee, uint256 aSeed) internal returns (MixedCtx memory c) {
        int24 A = int24(int256(bound(aSeed, 10, 5000))); // PORT: governance creator range [minA, maxA] = [10, 5000]
        JToken6 x = new JToken6(6);
        JToken6 y = new JToken6(18);
        c.xLow = address(x) < address(y);
        uint160 sqrtP = c.xLow ? uint160(uint256(1e6) << 96) : uint160((uint256(1) << 96) / 1e6);
        (c.a, c.b) = c.xLow ? (x, y) : (y, x);
        c.k = PoolKey({
            currency0: Currency.wrap(address(c.a)),
            currency1: Currency.wrap(address(c.b)),
            fee: fee,
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        });
        pm.initializeWithParams(c.k, sqrtP, abi.encode(uint256(uint24(A))), "");
        JPairActor lp = new JPairActor(vault, pm);
        c.a.mint(address(lp), 1e40);
        c.b.mint(address(lp), 1e40);
        lp.exec(_one(_op(0, c.k, 0, 0, 1e24, false)));
        c.t = new JPairActor(vault, pm);
        c.a.mint(address(c.t), 1e40);
        c.b.mint(address(c.t), 1e40);
    }

    function testFuzz_e_stableMixedDecimalsRoundTripNoGain(
        uint256 amt,
        bool dir,
        uint256 skew,
        bool skewDir,
        uint24 fee,
        uint256 aSeed
    ) public {
        MixedCtx memory c = _mixedPool(uint24(bound(fee, 0, 3000)), aSeed);
        _mixedSkew(c, bound(skew, 0, 4e23), skewDir);
        _mixedRoundTrip(c, bound(amt, 1, 1e24), dir);
    }

    function _mixedSkew(MixedCtx memory c, uint256 skew, bool skewDir) internal {
        if (skew == 0) return;
        uint256 raw = skewDir == c.xLow ? skew / 1e12 : skew; // input token decimals
        if (raw > 0) {
            try c.t.exec(_one(_op(1, c.k, 0, 0, int256(raw), skewDir))) {} catch {}
        }
    }

    function _mixedRoundTrip(MixedCtx memory c, uint256 amt, bool dir) internal {
        JToken6 tin = dir ? c.a : c.b;
        JToken6 tout = dir ? c.b : c.a;
        uint256 in0 = tin.balanceOf(address(c.t));
        uint256 out0 = tout.balanceOf(address(c.t));
        try c.t.exec(_one(_op(1, c.k, 0, 0, int256(amt), dir))) {}
        catch {
            return;
        }
        uint256 got = tout.balanceOf(address(c.t)) - out0;
        if (got == 0) return;
        try c.t.exec(_one(_op(1, c.k, 0, 0, int256(got), !dir))) {}
        catch {
            return;
        }
        assertLe(tin.balanceOf(address(c.t)), in0, "round trip returned more input than spent");
        assertEq(tout.balanceOf(address(c.t)), out0, "exact-in leg2 left output unconsumed");
    }

    // ------------------------------------------------------------ (e) A ramp round trip
    function testFuzz_e_rampRoundTripAcrossRamp(uint256 amt, bool dir, uint256 dt, bool up) public {
        PoolKey memory k = _key(CurveType.STABLE_AMM, 400, 1, address(0)); // PORT: A = 100 via init params
        pm.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), "");
        _actor(1e30).exec(_one(_op(0, k, 0, 0, 1e24, false)));
        JFlashActor imb = _actor(1e30);
        imb.exec(_one(_op(1, k, 0, 0, 4e23, true))); // imbalance the pool
        uint256 now_ = vm.getBlockTimestamp() + 2 days; // PORT: absolute warps (via-IR timestamp caching)
        vm.warp(now_);
        vm.prank(address(timelock));
        stable.rampA(k, up ? 1000 : 10, now_ + 1 days);
        _rampTrip(k, bound(amt, 1e15, 1e23), dir, now_ + bound(dt, 1, 1 days));
    }

    function _rampTrip(PoolKey memory k, uint256 amt, bool dir, uint256 tWarp) internal {
        JFlashActor t = _actor(1e30);
        uint256 in0 = (dir ? t0 : t1).balanceOf(address(t));
        uint256 got = _leg(t, k, amt, dir);
        if (got == type(uint256).max) return;
        vm.warp(tWarp);
        if (_leg(t, k, got, !dir) == type(uint256).max) return;
        int256 gain = int256((dir ? t0 : t1).balanceOf(address(t))) - int256(in0);
        if (gain > 0) {
            // expected by design for a ramp (LPs pay for A change); record magnitude relative to amount
            emit log_named_uint("ramp round-trip gain bps x100", uint256(gain) * 1e6 / amt);
        }
    }

    /// @dev Exact-in swap; returns the output received, or type(uint256).max when the swap reverted.
    function _leg(JFlashActor t, PoolKey memory k, uint256 amt, bool z) internal returns (uint256) {
        JToken tout = z ? t1 : t0;
        uint256 out0 = tout.balanceOf(address(t));
        try t.exec(_one(_op(1, k, 0, 0, int256(amt), z))) {}
        catch {
            return type(uint256).max;
        }
        return tout.balanceOf(address(t)) - out0;
    }

    // ------------------------------------------------------------ tree bitmap differential fuzz
    function testFuzz_treeBitmapMatchesReference(uint256 seed, uint24 q) public {
        TreeHarness h = new TreeHarness();
        uint24 base = uint24(bound(seed % (1 << 24), 0, (1 << 24) - 140_000));
        uint24[] memory keys = new uint24[](24);
        uint256 n;
        for (uint256 i; i < 24; i++) {
            uint24 k = base + uint24(uint256(keccak256(abi.encode(seed, i))) % 140_000);
            h.add(k);
            keys[n++] = k;
        }
        // remove a few
        for (uint256 i; i < 6; i++) {
            uint256 j = uint256(keccak256(abi.encode(seed, "r", i))) % n;
            h.remove(keys[j]);
            // mark removed if no duplicate remains
            uint24 rk = keys[j];
            for (uint256 m; m < n; m++) {
                if (keys[m] == rk) keys[m] = type(uint24).max;
            }
        }
        q = base + uint24(bound(q, 0, 140_000));
        (bool fb, uint24 kb) = h.below(q);
        (bool fa, uint24 ka) = h.above(q);
        bool eb;
        uint24 xb;
        bool ea;
        uint24 xa = type(uint24).max;
        for (uint256 m; m < n; m++) {
            uint24 k = keys[m];
            if (k == type(uint24).max) continue;
            if (k < q && (!eb || k > xb)) {
                eb = true;
                xb = k;
            }
            if (k > q && (!ea || k < xa)) {
                ea = true;
                xa = k;
            }
        }
        assertEq(fb, eb, "below found");
        if (eb) assertEq(kb, xb, "below key");
        assertEq(fa, ea, "above found");
        if (ea) assertEq(ka, xa, "above key");
    }

    // ------------------------------------------------------------ BIN multi-bin properties
    function _binPool(uint24 fee) internal returns (PoolKey memory k) {
        k = _key(CurveType.BIN_AMM, fee, 10, address(0));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e30).exec(_one(_op(0, k, -20, 20, 1e22, false)));
    }

    function testFuzz_bin_roundTripNoGain(uint256 amt, bool dir, uint24 fee, uint256 pre, bool preDir) public {
        PoolKey memory k = _binPool(uint24(bound(fee, 0, 10_000)));
        JFlashActor t = _actor(1e30);
        pre = bound(pre, 0, 2e23);
        if (pre > 0) {
            try t.exec(_one(_op(1, k, 0, 0, int256(pre), preDir))) {} catch {}
        }
        _binRoundTrip(k, t, bound(amt, 1, 3e23), dir);
    }

    function _binRoundTrip(PoolKey memory k, JFlashActor t, uint256 amt, bool dir) internal {
        JToken tin = dir ? t0 : t1;
        JToken tout = dir ? t1 : t0;
        uint256 in0 = tin.balanceOf(address(t));
        uint256 out0 = tout.balanceOf(address(t));
        try t.exec(_one(_op(1, k, 0, 0, int256(amt), dir))) {}
        catch {
            return;
        }
        uint256 got = tout.balanceOf(address(t)) - out0;
        if (got == 0) return;
        try t.exec(_one(_op(1, k, 0, 0, int256(got), !dir))) {}
        catch {
            return;
        }
        assertLe(tin.balanceOf(address(t)), in0, "BIN round trip returned more input");
    }

    function testFuzz_bin_addRemoveAfterMoveNoGain(uint256 move, bool dir, uint256 shares, int24 lo, uint8 width)
        public
    {
        PoolKey memory k = _binPool(2000);
        JFlashActor t = _actor(1e30);
        move = bound(move, 0, 2e23);
        if (move > 0) {
            try t.exec(_one(_op(1, k, 0, 0, int256(move), dir))) {} catch {}
        }
        lo = int24(bound(lo, -30, 30));
        int24 hi = lo + int24(uint24(bound(width, 0, 20)));
        _binAddRemove(k, lo, hi, bound(shares, 1, 1e24));
    }

    function _binAddRemove(PoolKey memory k, int24 lo, int24 hi, uint256 shares) internal {
        JFlashActor lp = _actor(1e30);
        uint256 a0 = t0.balanceOf(address(lp));
        uint256 a1 = t1.balanceOf(address(lp));
        try lp.exec(_one(_op(0, k, lo, hi, int256(shares), false))) {}
        catch {
            return;
        }
        lp.exec(_one(_op(0, k, lo, hi, -int256(shares), false)));
        assertLe(t0.balanceOf(address(lp)), a0, "t0 gained");
        assertLe(t1.balanceOf(address(lp)), a1, "t1 gained");
    }

    function testFuzz_bin_exactOutChargesAtLeastBinPrice(uint256 out, bool dir) public {
        PoolKey memory k = _binPool(0);
        JFlashActor t = _actor(1e30);
        out = bound(out, 1, 2e23);
        JToken tin = dir ? t0 : t1;
        JToken tout = dir ? t1 : t0;
        uint256 in0 = tin.balanceOf(address(t));
        uint256 out0 = tout.balanceOf(address(t));
        try t.exec(_one(_op(1, k, 0, 0, -int256(out), dir))) {}
        catch {
            return;
        }
        uint256 paid = in0 - tin.balanceOf(address(t));
        uint256 recv = tout.balanceOf(address(t)) - out0;
        // with fee 0 and price ~1 (bins ±20 of 10bps), paid must be >= received*0.98 and never less than recv at bin-0 price for the leg direction
        assertGe(paid * 1000, recv * 979, "underpaid");
    }

    // ------------------------------------------------------------ (f) timelock
    function test_f_timelockAdminBypassRemovedAndSoD() public {
        uint256 T = 1_000_000;
        vm.warp(T);
        // GOV is proposer/canceller, 0xE7EC executor, admin GOV has no extra power
        vm.prank(GOV);
        timelock.schedule(
            address(pm),
            0,
            abi.encodeCall(SupaPoolManager.setProtocolFee, (_key(CurveType.CLAMM, 3000, 60, address(0)), 0)),
            bytes32(0),
            bytes32("x"),
            1 days
        );
        T += 1 days + 1;
        vm.warp(T);
        vm.prank(GOV);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        timelock.execute(
            address(pm),
            0,
            abi.encodeCall(SupaPoolManager.setProtocolFee, (_key(CurveType.CLAMM, 3000, 60, address(0)), 0)),
            bytes32(0),
            bytes32("x")
        );
        // admin cannot schedule without proposer role
        address[] memory p = new address[](1);
        p[0] = address(0xAAA1);
        address[] memory e = new address[](1);
        e[0] = address(0xBBB1);
        SupaTimelock tl2 = new SupaTimelock(1 days, address(0xADD), p, e, p);
        vm.prank(address(0xADD));
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl2.schedule(address(1), 0, "", bytes32(0), bytes32(0), 1 days);
        // proposer cannot become executor via self-call; last executor cannot be removed
        bytes memory d1 = abi.encodeCall(SupaTimelock.setExecutor, (address(0xAAA1), true));
        vm.prank(address(0xAAA1));
        tl2.schedule(address(tl2), 0, d1, bytes32(0), bytes32("1"), 1 days);
        T += 1 days + 1;
        vm.warp(T);
        vm.prank(address(0xBBB1));
        vm.expectRevert();
        tl2.execute(address(tl2), 0, d1, bytes32(0), bytes32("1"));
        bytes memory d2 = abi.encodeCall(SupaTimelock.setExecutor, (address(0xBBB1), false));
        vm.prank(address(0xAAA1));
        tl2.schedule(address(tl2), 0, d2, bytes32(0), bytes32("2"), 1 days);
        T += 1 days + 1;
        vm.warp(T);
        vm.prank(address(0xBBB1));
        vm.expectRevert();
        tl2.execute(address(tl2), 0, d2, bytes32(0), bytes32("2"));
        // rotation (add new executor, then remove old) works
        bytes memory d3 = abi.encodeCall(SupaTimelock.setExecutor, (address(0xBBB2), true));
        vm.prank(address(0xAAA1));
        tl2.schedule(address(tl2), 0, d3, bytes32(0), bytes32("3"), 1 days);
        T += 1 days + 1;
        vm.warp(T);
        vm.prank(address(0xBBB1));
        tl2.execute(address(tl2), 0, d3, bytes32(0), bytes32("3"));
        assertTrue(tl2.isExecutor(address(0xBBB2)));
    }
}
