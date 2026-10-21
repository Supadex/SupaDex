// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {ICircuitBreaker} from "../../contract/interfaces/ICircuitBreaker.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {Slot0} from "../../contract/types/Slot0.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";
import {JFlashActor, JToken} from "../unit/security/JexiRegression.t.sol";

/// @notice Cross-protocol handler: three curves (CLAMM, multi-bin BIN, StableSwap) on ONE token pair in ONE vault,
///         several LPs, traders, a round-trip arbitrageur and an unauthorized caller. Reverts are classified: only
///         documented economic errors are "expected"; anything else is counted as unexpected.
contract CrossProtocolHandler is Test {
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public pm;
    JToken public t0;
    JToken public t1;
    PoolKey[3] internal keys;
    JFlashActor[3] public lps;
    JFlashActor public trader;
    JFlashActor public arb;

    mapping(uint256 => mapping(uint256 => uint256)) public liq; // lp => pool => liquidity units held
    uint256 public roundTripProfits;
    uint256 public unauthorizedSuccesses;
    uint256 public unexpectedReverts;
    bytes4 public lastUnexpected;
    mapping(string => uint256) public calls;
    uint256 public expectedReverts;

    constructor(SupaVault v, SupaPoolManager m, JToken a, JToken b, PoolKey[3] memory k) {
        vault = v;
        pm = m;
        t0 = a;
        t1 = b;
        for (uint256 i; i < 3; i++) {
            keys[i] = k[i];
        }
        for (uint256 i; i < 3; i++) {
            lps[i] = new JFlashActor(v, m);
            t0.mint(address(lps[i]), 1e30);
            t1.mint(address(lps[i]), 1e30);
        }
        trader = new JFlashActor(v, m);
        arb = new JFlashActor(v, m);
        t0.mint(address(trader), 1e30);
        t1.mint(address(trader), 1e30);
        t0.mint(address(arb), 1e30);
        t1.mint(address(arb), 1e30);
    }

    function key(uint256 p) external view returns (PoolKey memory) {
        return keys[p];
    }

    function range(uint256 p) public pure returns (int24 lo, int24 hi) {
        if (p == 0) return (-600, 600); // CLAMM
        if (p == 1) return (-8, 8); // BIN ids (17 bins)
        return (0, 0); // STABLE (ignored)
    }

    function _op(uint8 kind, uint256 p, int256 amt, bool z) internal view returns (JFlashActor.Op memory o) {
        (int24 lo, int24 hi) = range(p);
        o = JFlashActor.Op({kind: kind, key: keys[p], lo: lo, hi: hi, amt: amt, zeroForOne: z});
    }

    function _one(JFlashActor.Op memory o) internal pure returns (JFlashActor.Op[] memory ops) {
        ops = new JFlashActor.Op[](1);
        ops[0] = o;
    }

    function _classify(bytes memory err) internal {
        bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
        if (
            sel == PoolErrors.InsufficientLiquidity.selector || sel == PoolErrors.ZeroSwapAmount.selector
                || sel == PoolErrors.StableImbalanceExceeded.selector
                || sel == PoolErrors.InsufficientInitialLiquidity.selector
        ) {
            expectedReverts++;
        } else {
            unexpectedReverts++;
            lastUnexpected = sel;
        }
    }

    // ------------------------------------------------------------------ actions
    function addLiquidity(uint256 lpSeed, uint256 poolSeed, uint256 amt) external {
        uint256 i = lpSeed % 3;
        uint256 p = poolSeed % 3;
        amt = bound(amt, p == 1 ? 1e15 : 1e18, p == 1 ? 1e22 : 1e24);
        calls["add"]++;
        // StableSwap locks MINIMUM_LIQUIDITY (1000) of the first deposit forever (ADR-0001).
        bool firstStable = p == 2 && pm.getLiquidity(keys[2].toId()) == 0;
        try lps[i].exec(_one(_op(0, p, int256(amt), false))) {
            liq[i][p] += firstStable ? amt - 1000 : amt;
        } catch (bytes memory err) {
            _classify(err);
        }
    }

    function removeLiquidity(uint256 lpSeed, uint256 poolSeed, uint256 pct) external {
        uint256 i = lpSeed % 3;
        uint256 p = poolSeed % 3;
        uint256 held = liq[i][p];
        if (held == 0) return;
        uint256 amt = held * bound(pct, 1, 100) / 100;
        if (amt == 0) return;
        calls["remove"]++;
        try lps[i].exec(_one(_op(0, p, -int256(amt), false))) {
            liq[i][p] = held - amt;
        } catch (bytes memory err) {
            _classify(err);
        }
    }

    function swap(uint256 poolSeed, bool z, uint256 amt) external {
        uint256 p = poolSeed % 3;
        amt = bound(amt, 1e6, 1e23);
        calls["swap"]++;
        try trader.exec(_one(_op(1, p, int256(amt), z))) {}
        catch (bytes memory err) {
            _classify(err);
        }
    }

    /// Same-block A->B->A round trip by a dedicated arbitrageur. "Profit" means (a) a free lunch: one token up and
    /// the other not down, or (b) a positive net value at the pool's pre-trade marginal price beyond 1 wei of each
    /// token (exact-input steps may leave <= 1 wei unconsumed, which is returned to the trader and is not a gain).
    function roundTrip(uint256 poolSeed, bool z, uint256 amt) external {
        uint256 p = poolSeed % 3;
        amt = bound(amt, 1e9, 1e22);
        calls["roundTrip"]++;
        uint256 sqrtP = uint256(uint160(uint256(Slot0.unwrap(pm.getSlot0(keys[p].toId())))));
        uint256 b0 = t0.balanceOf(address(arb));
        uint256 b1 = t1.balanceOf(address(arb));
        try arb.exec(_one(_op(1, p, int256(amt), z))) {}
        catch (bytes memory err) {
            _classify(err);
            return;
        }
        JToken tout = z ? t1 : t0;
        uint256 got = tout.balanceOf(address(arb)) - (z ? b1 : b0);
        if (got == 0) return;
        try arb.exec(_one(_op(1, p, int256(got), !z))) {}
        catch (bytes memory err) {
            _classify(err);
            return;
        }
        int256 g0 = int256(t0.balanceOf(address(arb))) - int256(b0);
        int256 g1 = int256(t1.balanceOf(address(arb))) - int256(b1);
        if ((g0 > 0 && g1 >= 0) || (g1 > 0 && g0 >= 0)) {
            roundTripProfits++; // free lunch
            return;
        }
        // value in token1 units at the pre-trade price P = sqrtP^2 / 2^192
        uint256 v0 = FullMathLib.mulDiv(FullMathLib.mulDiv(uint256(g0 < 0 ? -g0 : g0), sqrtP, 1 << 96), sqrtP, 1 << 96);
        uint256 tol = FullMathLib.mulDiv(FullMathLib.mulDiv(1, sqrtP, 1 << 96), sqrtP, 1 << 96) + 2;
        int256 value = (g0 < 0 ? -int256(v0) : int256(v0)) + g1;
        if (value > int256(tol)) roundTripProfits++;
        if (g0 > 0 || g1 > 0) dustReturned++;
    }

    uint256 public dustReturned;

    /// Unauthorized caller tries every privileged entry point; any success is a violation.
    function unauthorized(address caller, uint256 which) external {
        if (caller == address(0) || caller == pm.owner() || caller == vault.owner() || caller == address(vault)) {
            return;
        }
        calls["unauthorized"]++;
        which = which % 7;
        vm.startPrank(caller);
        bool ok;
        if (which == 0) {
            (ok,) = address(pm).call(abi.encodeCall(SupaPoolManager.transferOwnership, (caller)));
        } else if (which == 1) {
            (ok,) = address(pm).call(abi.encodeCall(SupaPoolManager.setProtocolFee, (keys[0], 100)));
        } else if (which == 2) {
            (ok,) = address(vault).call(abi.encodeCall(SupaVault.sweepSurplus, (Currency.wrap(address(t0)), caller)));
        } else if (which == 3) {
            (ok,) = address(vault).call(abi.encodeCall(SupaVault.setPoolManager, (caller, true)));
        } else if (which == 4) {
            (ok,) = address(pm).call(abi.encodeCall(SupaPoolManager.setPluginWhitelist, (IPluginWhitelist(caller))));
        } else if (which == 5) {
            (ok,) = address(pm.stableEngine())
                .call(abi.encodeCall(StableAMMEngine.rampA, (keys[2], 200, block.timestamp + 2 days)));
        } else {
            (ok,) = address(vault).call(abi.encodeCall(SupaVault.transferOwnership, (caller)));
        }
        vm.stopPrank();
        if (ok) unauthorizedSuccesses++;
    }
}

contract CrossProtocolInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;

    SupaVault internal vault;
    SupaPoolManager internal pm;
    CLAMMEngine internal clamm;
    BinAMMEngine internal bin;
    StableAMMEngine internal stable;
    JToken internal t0;
    JToken internal t1;
    CrossProtocolHandler internal h;
    PoolKey[3] internal keys;

    function setUp() public {
        vault = new SupaVault(address(this));
        (pm, clamm, bin, stable) = SecurityTestSetup.deployManagerWithEnginesBinEnabled(vault);
        vault.setPoolManager(address(pm), true);
        SecurityTestSetup.installEmptyWhitelist(pm, address(this));
        JToken a = new JToken("A");
        JToken b = new JToken("B");
        if (address(a) > address(b)) (a, b) = (b, a);
        t0 = a;
        t1 = b;
        Currency c0 = Currency.wrap(address(a));
        Currency c1 = Currency.wrap(address(b));
        keys[0] = PoolKey(c0, c1, 3000, 60, address(0), CurveType.CLAMM);
        keys[1] = PoolKey(c0, c1, 2000, 10, address(0), CurveType.BIN_AMM);
        keys[2] = PoolKey(c0, c1, 400, 100, address(0), CurveType.STABLE_AMM);
        for (uint256 i; i < 3; i++) {
            pm.initialize(keys[i], 1 << 96, "");
        }
        PoolKey[3] memory km = [keys[0], keys[1], keys[2]];
        h = new CrossProtocolHandler(vault, pm, t0, t1, km);
        // seed every pool so the run starts from a live state
        h.addLiquidity(0, 0, 1e24);
        h.addLiquidity(0, 1, 1e22);
        h.addLiquidity(0, 2, 1e24);
        targetContract(address(h));
    }

    /// TOKENS + LIQUIDITY: every LP can always fully exit every pool, and afterwards the vault still holds at least
    /// the protocol-fee liabilities (liabilities <= assets; no stuck or missing value).
    function invariant_everyoneCanExitAndVaultCoversLiabilities() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 3; i++) {
            JFlashActor lp = h.lps(i);
            for (uint256 p; p < 3; p++) {
                uint256 held = h.liq(i, p);
                if (held == 0) continue;
                (int24 lo, int24 hi) = h.range(p);
                JFlashActor.Op[] memory ops = new JFlashActor.Op[](1);
                ops[0] = JFlashActor.Op({kind: 0, key: h.key(p), lo: lo, hi: hi, amt: -int256(held), zeroForOne: false});
                lp.exec(ops); // reverts the invariant if an LP is stuck
            }
        }
        assertGe(t0.balanceOf(address(vault)), pm.protocolFeesAccrued(Currency.wrap(address(t0))), "token0 liabilities");
        assertGe(t1.balanceOf(address(vault)), pm.protocolFeesAccrued(Currency.wrap(address(t1))), "token1 liabilities");
        vm.revertToState(snap);
    }

    function invariant_transientDeltasZeroAndLocked() public view {
        assertFalse(vault.isUnlocked());
        assertEq(vault.getCurrencyDelta(address(h.trader()), Currency.wrap(address(t0))), 0);
        assertEq(vault.getCurrencyDelta(address(h.trader()), Currency.wrap(address(t1))), 0);
    }

    /// ECONOMICS: no same-block round trip is ever profitable on any curve.
    function invariant_noProfitableRoundTrip() public view {
        assertEq(h.roundTripProfits(), 0);
    }

    /// ACCESS CONTROL: no privileged call ever succeeds from an unauthorized address; ownership never moves.
    function invariant_accessControl() public view {
        assertEq(h.unauthorizedSuccesses(), 0);
        assertEq(pm.owner(), address(this));
        assertEq(vault.owner(), address(this));
    }

    /// BIN: active id stays inside the overflow-safe domain (ADR-0006).
    function invariant_binActiveIdBounded() public view {
        int24 id = bin.getActiveBinId(keys[1].toId());
        uint256 absId = id < 0 ? uint256(-int256(id)) : uint256(int256(id));
        assertLe(absId * 10, 880_000, "BinMathLib.MAX_ID_STEP_PRODUCT");
    }

    /// STABLE: reserves never exceed the documented imbalance bound (ADR-0008).
    function invariant_stableImbalanceBounded() public view {
        (uint256 r0, uint256 r1) = stable.getReserves(keys[2].toId());
        if (r0 == 0 || r1 == 0) return;
        uint256 hi = r0 > r1 ? r0 : r1;
        uint256 lo = r0 > r1 ? r1 : r0;
        assertLe(hi, lo * stable.MAX_IMBALANCE_RATIO());
    }

    /// Handler health: only documented economic errors may revert (no unexpected failure modes).
    function invariant_noUnexpectedReverts() public view {
        assertEq(h.unexpectedReverts(), 0, "unexpected revert selector");
    }

    function afterInvariant() external view {
        console2.log("calls add/remove/swap:", h.calls("add"), h.calls("remove"), h.calls("swap"));
        console2.log("calls roundTrip/unauthorized:", h.calls("roundTrip"), h.calls("unauthorized"));
        console2.log("expected reverts:", h.expectedReverts(), "unexpected:", h.unexpectedReverts());
        console2.log("round trips returning <=1 wei unconsumed input:", h.dustReturned());
    }
}
