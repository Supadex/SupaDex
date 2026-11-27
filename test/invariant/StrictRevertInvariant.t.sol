// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {SupaPositionManager} from "../../contract/periphery/SupaPositionManager.sol";
import {PositionNFTDescriptor} from "../../contract/periphery/PositionNFTDescriptor.sol";
import {SupaClaimsRouter} from "../../contract/periphery/SupaClaimsRouter.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {AntiJITVestingPlugin} from "../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {ISupaPositionManager} from "../../contract/interfaces/ISupaPositionManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";
import {JToken} from "../unit/security/JexiRegression.t.sol";
import {RevertClassifier, RevertClassifyingHandler} from "./RevertClassifier.sol";

/// @notice T-6 strict-revert actor: modify / swap / donate inside ONE unlock, then nets
///         deltas (pays debts from its own balance, takes credits). Extends the JFlashActor
///         pattern with donate (kind 2), which the strict suite must cover.
contract StrictActor is IUnlockCallback {
    struct Op {
        uint8 kind; // 0 = modifyLiquidity, 1 = swap, 2 = donate
        PoolKey key;
        int24 lo;
        int24 hi;
        int256 amt; // liquidityDelta | amountSpecified | donate amount0
        int256 amt1; // donate amount1 (kind 2 only)
        bool zeroForOne;
    }

    SupaVault public immutable vault;
    SupaPoolManager public immutable pm;

    constructor(SupaVault v, SupaPoolManager m) {
        vault = v;
        pm = m;
    }

    function exec(Op[] memory ops) external {
        vault.unlock(abi.encode(ops));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault), "only vault");
        Op[] memory ops = abi.decode(data, (Op[]));
        for (uint256 i; i < ops.length; i++) {
            Op memory o = ops[i];
            if (o.kind == 0) {
                pm.modifyLiquidity(
                    o.key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: o.lo, tickUpper: o.hi, liquidityDelta: o.amt, salt: bytes32(0)
                    }),
                    ""
                );
            } else if (o.kind == 1) {
                pm.swap(
                    o.key,
                    IPoolManager.SwapParams({zeroForOne: o.zeroForOne, amountSpecified: o.amt, sqrtPriceLimitX96: 0}),
                    ""
                );
            } else {
                pm.donate(o.key, uint256(o.amt), uint256(o.amt1), "");
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
            JToken(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}

/// @notice T-6 strict handler: every protocol operation goes through try/catch + the shared
///         RevertClassifier. NOTHING is swallowed by a bare catch, and no handler call ever
///         reverts out of the handler — so under [profile.strict] (fail_on_revert = true)
///         any uncaught revert fails the run, and any classified-unexpected revert fails
///         `invariant_noUnexpectedReverts`.
contract StrictRevertHandler is Test, IUnlockCallback, RevertClassifyingHandler {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public pm;
    SupaRouter public router;
    SupaPositionManager public posManager;
    SupaClaimsRouter public claimsRouter;
    JToken public t0;
    JToken public t1;
    PoolKey[5] internal keys; // 0 CLAMM, 1 BIN, 2 STABLE, 3 LVR-CLAMM, 4 JIT-CLAMM
    StrictActor public actor;
    StrictActor public lp;

    mapping(uint256 => mapping(uint256 => uint256)) public liq; // actorIdx 0=lp => pool => held
    uint256[] public positionIds;
    mapping(uint256 => uint128) public positionLiq;
    mapping(uint256 => uint256) public positionPool;
    /// @notice Cumulative successful mintClaims volume. Successful mints are each up to
    ///         int256.max, so a handful would overflow uint256 accounting (mock-token
    ///         balances, ERC-6909 balances, claim supply). mintClaims therefore stops
    ///         once the remaining headroom drops below int256.max — the extreme-magnitude
    ///         behaviour is still exercised by the mints that did run. This is a harness
    ///         bound, not a protocol bound: > 2^256 total minted is economically impossible.
    uint256 public cumulativeMinted;
    uint256 public unauthorizedSuccesses;

    uint8 internal constant ECON = RevertClassifier.CTX_ECONOMIC | RevertClassifier.CTX_INPUT;

    constructor(
        SupaVault v,
        SupaPoolManager m,
        SupaRouter r,
        SupaPositionManager pmgr,
        SupaClaimsRouter cr,
        JToken a,
        JToken b,
        PoolKey[5] memory k
    ) {
        vault = v;
        pm = m;
        router = r;
        posManager = pmgr;
        claimsRouter = cr;
        t0 = a;
        t1 = b;
        for (uint256 i; i < 5; i++) keys[i] = k[i];
        actor = new StrictActor(v, m);
        lp = new StrictActor(v, m);
        t0.mint(address(actor), 1e30);
        t1.mint(address(actor), 1e30);
        t0.mint(address(lp), 1e30);
        t1.mint(address(lp), 1e30);
        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);
        t0.approve(address(claimsRouter), type(uint256).max);
        t1.approve(address(claimsRouter), type(uint256).max);
        t0.approve(address(posManager), type(uint256).max);
        t1.approve(address(posManager), type(uint256).max);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
    }

    function key(uint256 p) external view returns (PoolKey memory) {
        return keys[p % 5];
    }

    function range(uint256 p) public pure returns (int24 lo, int24 hi) {
        if (p % 5 == 0 || p % 5 == 3 || p % 5 == 4) return (-600, 600); // CLAMM-family
        if (p % 5 == 1) return (-8, 8); // BIN ids
        return (0, 0); // STABLE (ignored)
    }

    function _one(StrictActor.Op memory o) internal pure returns (StrictActor.Op[] memory ops) {
        ops = new StrictActor.Op[](1);
        ops[0] = o;
    }

    function _op(uint8 kind, uint256 p, int256 amt, int256 amt1, bool z)
        internal
        view
        returns (StrictActor.Op memory o)
    {
        (int24 lo, int24 hi) = range(p);
        o = StrictActor.Op({kind: kind, key: keys[p % 5], lo: lo, hi: hi, amt: amt, amt1: amt1, zeroForOne: z});
    }

    // ------------------------------------------------------------ core ops
    function swap(uint256 poolSeed, bool z, uint256 amt) external {
        uint256 p = poolSeed % 5;
        amt = bound(amt, 1, 1e23);
        calls["swap"]++;
        try actor.exec(_one(_op(1, p, int256(amt), 0, z))) {}
        catch (bytes memory err) {
            _classify(err, ECON, "swap");
        }
    }

    /// T-2: 1-wei swaps, including the size that re-crossed a CLAMM tick (C-02).
    function dustSwap(uint256 poolSeed, bool z) external {
        uint256 p = poolSeed % 5;
        calls["dustSwap"]++;
        try actor.exec(_one(_op(1, p, int256(1), 0, z))) {}
        catch (bytes memory err) {
            _classify(err, ECON, "dustSwap");
        }
    }

    function addLiquidity(uint256 poolSeed, uint256 amt) external {
        uint256 p = poolSeed % 5;
        amt = bound(amt, p == 1 ? 1e15 : 1e18, p == 1 ? 1e22 : 1e24);
        calls["add"]++;
        bool firstStable = p == 2 && pm.getLiquidity(keys[2].toId()) == 0;
        try lp.exec(_one(_op(0, p, int256(amt), 0, false))) {
            liq[0][p] += firstStable ? amt - 1000 : amt;
        } catch (bytes memory err) {
            _classify(err, ECON, "addLiquidity");
        }
    }

    function removeLiquidity(uint256 poolSeed, uint256 pct) external {
        uint256 p = poolSeed % 5;
        uint256 held = liq[0][p];
        if (held == 0) return;
        uint256 amt = held * bound(pct, 1, 100) / 100;
        if (amt == 0) return;
        calls["remove"]++;
        try lp.exec(_one(_op(0, p, -int256(amt), 0, false))) {
            liq[0][p] = held - amt;
        } catch (bytes memory err) {
            _classify(err, ECON, "removeLiquidity");
        }
    }

    function donate(uint256 poolSeed, uint256 amt0, uint256 amt1) external {
        uint256 p = poolSeed % 5;
        amt0 = bound(amt0, 1, 1e21);
        amt1 = bound(amt1, 1, 1e21);
        calls["donate"]++;
        try actor.exec(_one(_op(2, p, int256(amt0), int256(amt1), false))) {}
        catch (bytes memory err) {
            _classify(err, ECON, "donate");
        }
    }

    // ------------------------------------------------------------ router ops
    function routerExactInput(uint256 poolSeed, bool z, uint256 amt) external {
        uint256 p = poolSeed % 3; // CLAMM / BIN / STABLE
        amt = bound(amt, 1_000, 1e22);
        address swapper = address(0x4444);
        JToken pay = z ? t0 : t1;
        // The router pulls from the swapper; fund + approve it (swapper is an EOA stand-in).
        // NOTE: pranked approvals below run as the swapper; the handler itself is never the payer.
        pay.mint(swapper, amt * 2);
        vm.startPrank(swapper);
        pay.approve(address(router), type(uint256).max);
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: keys[p],
            zeroForOne: z,
            recipient: swapper,
            amountIn: uint128(amt),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });
        calls["routerExactInput"]++;
        try router.exactInputSingle(params) {}
        catch (bytes memory err) {
            _classify(err, ECON, "routerExactInput");
        }
        vm.stopPrank();
    }

    function routerExactOutput(uint256 poolSeed, bool z, uint256 amtOut) external {
        uint256 p = poolSeed % 3;
        amtOut = bound(amtOut, 1_000, 1e21);
        address swapper = address(0x5555);
        JToken pay = z ? t0 : t1;
        pay.mint(swapper, amtOut * 100 + 1e24);
        vm.startPrank(swapper);
        pay.approve(address(router), type(uint256).max);
        ISupaRouter.ExactOutputSingleParams memory params = ISupaRouter.ExactOutputSingleParams({
            poolKey: keys[p],
            zeroForOne: z,
            recipient: swapper,
            amountOut: uint128(amtOut),
            amountInMaximum: type(uint128).max,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });
        calls["routerExactOutput"]++;
        try router.exactOutputSingle(params) {}
        catch (bytes memory err) {
            _classify(err, ECON, "routerExactOutput");
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------ position manager ops
    function positionMint(uint256 poolSeed, uint128 liquidity) external {
        uint256 p = poolSeed % 3;
        liquidity = uint128(bound(liquidity, 1_000, 1e22));
        ISupaPositionManager.MintParams memory params = ISupaPositionManager.MintParams({
            poolKey: keys[p],
            tickLower: -120,
            tickUpper: 120,
            liquidity: liquidity,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            recipient: address(this),
            deadline: block.timestamp + 100,
            hookData: "",
            payWithClaims: false
        });
        calls["positionMint"]++;
        try posManager.mint(params) returns (uint256 tokenId, uint128 mintedLiq, uint256, uint256) {
            positionIds.push(tokenId);
            positionLiq[tokenId] = mintedLiq;
            positionPool[tokenId] = p;
        } catch (bytes memory err) {
            _classify(err, ECON, "positionMint");
        }
    }

    function positionDecrease(uint256 idIdx, uint256 pct) external {
        if (positionIds.length == 0) return;
        uint256 tokenId = positionIds[idIdx % positionIds.length];
        uint128 held = positionLiq[tokenId];
        if (held == 0) return;
        uint128 sub = uint128(held * bound(pct, 1, 100) / 100);
        if (sub == 0) return;
        ISupaPositionManager.DecreaseLiquidityParams memory params = ISupaPositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: sub,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            hookData: "",
            recipient: address(0),
            receiveAsClaims: false
        });
        calls["positionDecrease"]++;
        try posManager.decreaseLiquidity(params) {
            positionLiq[tokenId] = held - sub;
        } catch (bytes memory err) {
            _classify(err, ECON, "positionDecrease");
        }
    }

    function positionCollect(uint256 idIdx) external {
        if (positionIds.length == 0) return;
        uint256 tokenId = positionIds[idIdx % positionIds.length];
        ISupaPositionManager.CollectParams memory params = ISupaPositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        calls["positionCollect"]++;
        try posManager.collect(params) {}
        catch (bytes memory err) {
            _classify(err, ECON, "positionCollect");
        }
    }

    function positionBurn(uint256 idIdx) external {
        if (positionIds.length == 0) return;
        uint256 tokenId = positionIds[idIdx % positionIds.length];
        if (positionLiq[tokenId] > 0) return;
        calls["positionBurn"]++;
        // SupaPositionManager.burn reverts Unauthorized() not only for non-owners
        // but also when tokensOwed0/1 != 0 (uncollected fees). Swaps in this suite
        // accrue fees, so collect first — otherwise a legitimate burn is misread
        // as an access-control failure.
        ISupaPositionManager.CollectParams memory cparams = ISupaPositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        try posManager.collect(cparams) {}
        catch (bytes memory err) {
            _classify(err, ECON, "positionBurnCollect");
            return;
        }
        try posManager.burn(tokenId) {}
        catch (bytes memory err) {
            _classify(err, ECON, "positionBurn");
        }
    }

    // ------------------------------------------------------------ claims ops
    function claimsDeposit(uint256 currencySeed, uint256 amt) external {
        Currency c = currencySeed % 2 == 0 ? Currency.wrap(address(t0)) : Currency.wrap(address(t1));
        amt = bound(amt, 1, 1e22);
        calls["claimsDeposit"]++;
        try claimsRouter.deposit(c, address(this), amt) {}
        catch (bytes memory err) {
            _classify(err, ECON, "claimsDeposit");
        }
    }

    function claimsWithdraw(uint256 currencySeed, uint256 amt) external {
        Currency c = currencySeed % 2 == 0 ? Currency.wrap(address(t0)) : Currency.wrap(address(t1));
        uint256 held = vault.balanceOf(address(this), c.toId());
        if (held == 0) return;
        // Per-call vault ops are int128-bounded by design (SupaVault.burn/take use
        // SafeCastLib.toInt128; "Larger settles must be split"). Cumulative holdings
        // can exceed int128.max (several in-range mints), so cap the single call.
        uint256 cap = held < uint256(int256(type(int128).max)) ? held : uint256(int256(type(int128).max));
        amt = bound(amt, 1, cap);
        calls["claimsWithdraw"]++;
        try claimsRouter.withdraw(c, address(this), amt) {}
        catch (bytes memory err) {
            _classify(err, ECON, "claimsWithdraw");
        }
    }

    // ------------------------------------------------------------ vault claims (mint/burn/take/settle)
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(vault), "only vault");
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        Currency c = Currency.wrap(address(t0));
        if (action == 0) {
            vault.sync(c);
            t0.mint(address(vault), amount);
            vault.settle(c);
            vault.mint(c, address(this), amount);
            cumulativeMinted += amount;
        } else {
            if (amount == 0) return "";
            vault.burn(c, amount);
            vault.take(c, address(this), amount);
            // Saturating: claims obtained via claimsDeposit were never counted in
            // cumulativeMinted, so never let this decrement underflow.
            cumulativeMinted -= amount > cumulativeMinted ? cumulativeMinted : amount;
        }
        return "";
    }

    function mintClaims(uint256 amount) external {
        // Full uint256 domain, incl. magnitudes that trip the C-01 guards. Only this op
        // grants CTX_EXTREME: SafeCastOverflow / DeltaOverflow are the fix working as designed.
        // The actual per-call guard threshold is int128.max, not int256.max: SupaVault
        // settle/mint/take/burn all use SafeCastLib.toInt128 ("Per-call deltas are
        // int128-bounded (Uniswap v4). Larger settles must be split."). Amounts above
        // int128.max therefore revert SafeCastOverflow — expected here, exercised by
        // this op only. burnClaims / claimsWithdraw cap per-call amounts at int128.max
        // so the success path is exercised there instead.
        // Headroom guards (see cumulativeMinted): stop once < int256.max headroom remains,
        // so cumulative accounting can never wrap and be misread as an unexpected Panic.
        // TWO headrooms matter: the ERC-6909 claims accounting (cumulativeMinted) AND the
        // mock token's totalSupply — JToken.mint does `totalSupply += amount`, and a mint
        // near 2^256 overflows totalSupply (and balanceOf[vault]) even when the claims
        // headroom is fine. The first strict fuzz run caught exactly this (seed
        // 0x1ef9af39…, mintClaims(≈2^256) -> Panic in JToken.mint, counted unexpected).
        if (cumulativeMinted > type(uint256).max - uint256(type(int256).max) - 1) return;
        uint256 tokenHeadroom = type(uint256).max - t0.totalSupply();
        if (tokenHeadroom <= 1) return;
        uint256 maxAmount = type(uint256).max - cumulativeMinted;
        if (tokenHeadroom < maxAmount) maxAmount = tokenHeadroom;
        amount = bound(amount, 1, maxAmount);
        calls["mintClaims"]++;
        try vault.unlock(abi.encode(uint8(0), amount)) {}
        catch (bytes memory err) {
            _classify(
                err,
                RevertClassifier.CTX_ECONOMIC | RevertClassifier.CTX_INPUT | RevertClassifier.CTX_EXTREME,
                "mintClaims"
            );
        }
    }

    function burnClaims(uint256 amount) external {
        // Bound by the handler's actual on-chain claims balance (incl. claims-router
        // deposits), never by a hand-rolled counter that could drift. Per-call vault
        // ops are int128-bounded by design (SupaVault.burn uses SafeCastLib.toInt128),
        // so cap the single call at int128.max even when holdings are larger.
        uint256 held = vault.balanceOf(address(this), Currency.wrap(address(t0)).toId());
        if (held == 0) return;
        uint256 cap = held < uint256(int256(type(int128).max)) ? held : uint256(int256(type(int128).max));
        amount = bound(amount, 1, cap);
        calls["burnClaims"]++;
        try vault.unlock(abi.encode(uint8(1), amount)) {}
        catch (bytes memory err) {
            _classify(err, ECON, "burnClaims");
        }
    }

    // ------------------------------------------------------------ unauthorized probe
    function unauthorized(address caller, uint256 which) external {
        if (caller == address(0) || caller == pm.owner() || caller == vault.owner() || caller == address(vault)) {
            return;
        }
        calls["unauthorized"]++;
        which = which % 7;
        vm.startPrank(caller);
        bool ok;
        bytes memory ret;
        if (which == 0) {
            (ok, ret) = address(pm).call(abi.encodeCall(SupaPoolManager.transferOwnership, (caller)));
        } else if (which == 1) {
            (ok, ret) = address(pm).call(abi.encodeCall(SupaPoolManager.setProtocolFee, (keys[0], 100)));
        } else if (which == 2) {
            (ok, ret) =
                address(vault).call(abi.encodeCall(SupaVault.sweepSurplus, (Currency.wrap(address(t0)), caller)));
        } else if (which == 3) {
            (ok, ret) = address(vault).call(abi.encodeCall(SupaVault.setPoolManager, (caller, true)));
        } else if (which == 4) {
            (ok, ret) = address(pm).call(abi.encodeCall(SupaPoolManager.setPluginWhitelist, (IPluginWhitelist(caller))));
        } else if (which == 5) {
            (ok, ret) = address(pm.stableEngine())
                .call(abi.encodeCall(StableAMMEngine.rampA, (keys[2], 200, block.timestamp + 2 days)));
        } else {
            (ok, ret) = address(vault).call(abi.encodeCall(SupaVault.transferOwnership, (caller)));
        }
        vm.stopPrank();
        if (ok) {
            unauthorizedSuccesses++;
        } else {
            // A revert IS the expected outcome here; classify it under CTX_ACCESS so a
            // denial for the wrong reason (e.g. a protocol bug) still fails the suite.
            _classify(ret, RevertClassifier.CTX_ACCESS, "unauthorized");
        }
    }
}

contract StrictRevertInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    SupaVault internal vault;
    SupaPoolManager internal pm;
    SupaRouter internal router;
    SupaPositionManager internal posManager;
    SupaClaimsRouter internal claimsRouter;
    JToken internal t0;
    JToken internal t1;
    StrictRevertHandler internal h;
    PoolKey[5] internal keys;

    function setUp() public {
        vault = new SupaVault(address(this));
        (pm,,,) = SecurityTestSetup.deployManagerWithEnginesBinEnabled(vault);
        vault.setPoolManager(address(pm), true);

        LVRShieldPlugin lvr = new LVRShieldPlugin(pm);
        AntiJITVestingPlugin jit = new AntiJITVestingPlugin(pm, 3);
        address[] memory plugins = new address[](2);
        plugins[0] = address(lvr);
        plugins[1] = address(jit);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(jit), true);
        pm.setPluginWhitelist(IPluginWhitelist(address(wl)));

        router = new SupaRouter(pm, vault);
        claimsRouter = new SupaClaimsRouter(vault);
        posManager = new SupaPositionManager(pm, vault, address(new PositionNFTDescriptor()));

        JToken a = new JToken("A");
        JToken b = new JToken("B");
        if (address(a) > address(b)) (a, b) = (b, a);
        t0 = a;
        t1 = b;
        Currency c0 = Currency.wrap(address(a));
        Currency c1 = Currency.wrap(address(b));
        keys[0] = PoolKey(c0, c1, 3000, 60, address(0), CurveType.CLAMM);
        keys[1] = PoolKey(c0, c1, 2000, 10, address(0), CurveType.BIN_AMM);
        keys[2] = PoolKey(c0, c1, 400, 1, address(0), CurveType.STABLE_AMM);
        keys[3] = PoolKey(c0, c1, 3000, 60, address(lvr), CurveType.CLAMM);
        keys[4] = PoolKey(c0, c1, 3000, 60, address(jit), CurveType.CLAMM);
        for (uint256 i; i < 5; i++) {
            if (i == 2) pm.initializeWithParams(keys[i], 1 << 96, abi.encode(uint256(100)), "");
            else pm.initialize(keys[i], 1 << 96, "");
        }
        PoolKey[5] memory km = [keys[0], keys[1], keys[2], keys[3], keys[4]];
        h = new StrictRevertHandler(vault, pm, router, posManager, claimsRouter, t0, t1, km);
        // The claims router pulls the handler's claims on withdraw: approve it as operator.
        vm.prank(address(h));
        vault.setOperator(address(claimsRouter), true);

        // Seed every pool so the run starts from a live state.
        h.addLiquidity(0, 1e24);
        h.addLiquidity(1, 1e22);
        h.addLiquidity(2, 1e24);
        h.addLiquidity(3, 1e22);
        h.addLiquidity(4, 1e22);
        assertEq(h.unexpectedReverts(), 0, "seed unexpected revert");
        targetContract(address(h));
        // The handler's unlockCallback is vault-only (onlyVault) and is only ever
        // invoked BY the vault during an unlock. A direct fuzz call to it reverts
        // `VaultErrors.Unauthorized` ("only vault") — correct access control, but
        // under [profile.strict] (fail_on_revert=true) ANY handler revert fails the
        // run, so the fuzzer must not call it directly. Exclude it from the fuzz
        // surface; the unauthorized-caller probe still exercises access control.
        bytes4[] memory excluded = new bytes4[](1);
        excluded[0] = StrictRevertHandler.unlockCallback.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: excluded}));
    }

    /// T-6 (strict): NO unexpected revert may occur in any handler operation. Under
    /// [profile.strict] (fail_on_revert = true) an uncaught handler revert additionally
    /// fails the run at the Foundry level, before this invariant is even evaluated.
    function invariant_noUnexpectedReverts() public view {
        assertEq(h.unexpectedReverts(), 0, "unexpected revert in strict handler");
    }

    /// Vault stays settled and solvent: no open lock, no open deltas, claims covered.
    function invariant_vaultSettledAndSolvent() public view {
        assertFalse(vault.isUnlocked());
        assertEq(vault.getCurrencyDelta(address(h.actor()), Currency.wrap(address(t0))), 0);
        assertEq(vault.getCurrencyDelta(address(h.actor()), Currency.wrap(address(t1))), 0);
        assertEq(vault.getCurrencyDelta(address(h.lp()), Currency.wrap(address(t0))), 0);
        assertEq(vault.getCurrencyDelta(address(h.lp()), Currency.wrap(address(t1))), 0);
        assertGe(vault.reservesOf(Currency.wrap(address(t0))), vault.claimSupplyOf(Currency.wrap(address(t0))));
        assertGe(vault.reservesOf(Currency.wrap(address(t1))), vault.claimSupplyOf(Currency.wrap(address(t1))));
    }

    /// Per-pool pots + protocol fees + claims are covered by vault reserves (T-4 shape).
    function invariant_perPoolReservesWithinVault() public view {
        _assertCurrencyIsolated(Currency.wrap(address(t0)));
        _assertCurrencyIsolated(Currency.wrap(address(t1)));
    }

    function _assertCurrencyIsolated(Currency currency) internal view {
        uint256 pots;
        for (uint256 i; i < 5; i++) pots += pm.poolReserves(keys[i].toId(), currency);
        uint256 owed = pots + pm.protocolFeesAccrued(currency) + vault.claimSupplyOf(currency);
        assertLe(owed, vault.reservesOf(currency), "pool pots + fees + claims exceed reserves");
        assertLe(vault.reservesOf(currency), currency.balanceOf(address(vault)), "reserves exceed balance");
    }

    /// ACCESS CONTROL: no privileged call ever succeeds from an unauthorized address.
    function invariant_accessControl() public view {
        assertEq(h.unauthorizedSuccesses(), 0);
        assertEq(pm.owner(), address(this));
        assertEq(vault.owner(), address(this));
    }

    /// Deterministic coverage proof (not fuzzed): every strict op runs once successfully
    /// classified, so the suite cannot pass vacuously with zero calls.
    function test_allOperationsCovered() public {
        h.swap(0, true, 1e18);
        h.dustSwap(0, true);
        h.swap(1, false, 1e18);
        h.swap(2, true, 1e18);
        h.swap(3, true, 1e18);
        h.swap(4, true, 1e18);
        h.addLiquidity(1, 1e18);
        h.removeLiquidity(1, 50);
        h.donate(0, 1e15, 1e15);
        h.routerExactInput(0, true, 1e18);
        h.routerExactOutput(0, true, 1e15);
        h.positionMint(0, 1e18);
        h.positionDecrease(0, 50);
        h.positionCollect(0);
        h.positionDecrease(0, 100);
        h.positionBurn(0);
        h.claimsDeposit(0, 1e18);
        h.claimsWithdraw(0, 1e18);
        h.mintClaims(1e18);
        h.burnClaims(1e18);
        h.unauthorized(address(0x9999), 0);
        assertEq(h.unexpectedReverts(), 0, "unexpected revert during coverage run");
        assertGt(h.calls("swap"), 0, "swap never called");
        assertGt(h.calls("dustSwap"), 0, "dustSwap never called");
        assertGt(h.calls("add"), 0, "add never called");
        assertGt(h.calls("remove"), 0, "remove never called");
        assertGt(h.calls("donate"), 0, "donate never called");
        assertGt(h.calls("routerExactInput"), 0, "routerExactInput never called");
        assertGt(h.calls("routerExactOutput"), 0, "routerExactOutput never called");
        assertGt(h.calls("positionMint"), 0, "positionMint never called");
        assertGt(h.calls("positionDecrease"), 0, "positionDecrease never called");
        assertGt(h.calls("positionCollect"), 0, "positionCollect never called");
        assertGt(h.calls("positionBurn"), 0, "positionBurn never called");
        assertGt(h.calls("claimsDeposit"), 0, "claimsDeposit never called");
        assertGt(h.calls("claimsWithdraw"), 0, "claimsWithdraw never called");
        assertGt(h.calls("mintClaims"), 0, "mintClaims never called");
        assertGt(h.calls("burnClaims"), 0, "burnClaims never called");
        assertGt(h.calls("unauthorized"), 0, "unauthorized never called");
    }

    function afterInvariant() external view {
        console2.log("expected reverts:", h.expectedReverts(), "unexpected:", h.unexpectedReverts());
        console2.log("last unexpected op:", h.lastUnexpectedOp());
        console2.log("last unexpected selector (uint32):", uint32(h.lastUnexpected()));
        console2.log("calls swap/dustSwap:", h.calls("swap"), h.calls("dustSwap"));
        console2.log("calls add/remove/donate:", h.calls("add"), h.calls("remove"), h.calls("donate"));
        console2.log("calls routerIn/routerOut:", h.calls("routerExactInput"), h.calls("routerExactOutput"));
        console2.log("calls posMint/posDecrease:", h.calls("positionMint"), h.calls("positionDecrease"));
        console2.log("calls claimsDep/claimsWdraw:", h.calls("claimsDeposit"), h.calls("claimsWithdraw"));
        console2.log("calls mintClaims/burnClaims:", h.calls("mintClaims"), h.calls("burnClaims"));
    }
}
