// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {ISupaPositionManager} from "../../contract/interfaces/ISupaPositionManager.sol";
import {SupaPositionManager} from "../../contract/periphery/SupaPositionManager.sol";
import {PositionNFTDescriptor} from "../../contract/periphery/PositionNFTDescriptor.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";
import {PeripheryErrors} from "../../contract/errors/PeripheryErrors.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";
import {JToken} from "../unit/security/JexiRegression.t.sol";
import {StrictActor} from "./StrictRevertInvariant.t.sol";
import {RevertClassifier, RevertClassifyingHandler} from "./RevertClassifier.sol";

/// @notice A deliberately broken callback: reverts with an unknown custom error, and
///         with an arithmetic Panic (0x11 — the C-02 mirror-direction underflow shape).
contract BrokenCallback is IUnlockCallback {
    error Boom();

    SupaVault public immutable vault;
    uint8 public mode; // 0 = unknown custom error, 1 = arithmetic panic

    constructor(SupaVault v) {
        vault = v;
    }

    function run(uint8 m) external {
        mode = m;
        vault.unlock("");
    }

    function unlockCallback(bytes calldata) external view override returns (bytes memory) {
        if (mode == 0) revert Boom();
        uint256 x = 1;
        uint256 y = 2;
        // Checked arithmetic underflow -> Panic(0x11) (the C-02 mirror-direction shape).
        uint256 z = x - y;
        return abi.encode(z);
    }
}

/// @notice Minimal harness exposing the shared classifier's counting choke point.
contract ClassifierHarness is Test, RevertClassifyingHandler {
    function probe(bytes memory err, uint8 ctx) external {
        _classify(err, ctx, "probe");
    }
}

/// @notice T-6 regression tests: the classifier must DETECT unexpected reverts (never
///         swallow them) and must NOT false-positive on classified expected reverts.
contract StrictRevertRegressionTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint8 internal constant ECON = RevertClassifier.CTX_ECONOMIC | RevertClassifier.CTX_INPUT;
    uint8 internal constant EXTREME =
        RevertClassifier.CTX_ECONOMIC | RevertClassifier.CTX_INPUT | RevertClassifier.CTX_EXTREME;

    SupaVault internal vault;
    SupaPoolManager internal pm;
    JToken internal t0;
    JToken internal t1;
    PoolKey internal key;
    StrictActor internal actor;

    function setUp() public {
        vault = new SupaVault(address(this));
        (pm,,,) = SecurityTestSetup.deployManagerWithEnginesBinEnabled(vault);
        vault.setPoolManager(address(pm), true);
        SecurityTestSetup.installEmptyWhitelist(pm, address(this));
        JToken a = new JToken("A");
        JToken b = new JToken("B");
        if (address(a) > address(b)) (a, b) = (b, a);
        t0 = a;
        t1 = b;
        key = PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 3000, 60, address(0), CurveType.CLAMM);
        pm.initialize(key, 1 << 96, "");
        actor = new StrictActor(vault, pm);
        t0.mint(address(actor), 1e30);
        t1.mint(address(actor), 1e30);
        // Seed liquidity via the actor so swaps have something to price against.
        StrictActor.Op[] memory ops = new StrictActor.Op[](1);
        ops[0] = StrictActor.Op({kind: 0, key: key, lo: -600, hi: 600, amt: int256(1e24), amt1: 0, zeroForOne: false});
        actor.exec(ops);
    }

    // ---------------------------------------------------------- end-to-end detection
    function test_unexpectedRevertDetected_uninitializedPool() public {
        // A swap on a never-initialized pool reverts PoolNotInitialized. The strict
        // handler path must COUNT it as unexpected, not swallow it.
        ClassifierHarness h = new ClassifierHarness();
        PoolKey memory bad =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, address(0), CurveType.CLAMM);
        // Use a different fee so the pool id differs from the initialized pool.
        bad.fee = 500;
        StrictActor.Op[] memory ops = new StrictActor.Op[](1);
        ops[0] = StrictActor.Op({kind: 1, key: bad, lo: 0, hi: 0, amt: int256(1e18), amt1: 0, zeroForOne: true});
        try actor.exec(ops) {
            assertTrue(false, "uninitialized-pool swap must revert");
        } catch (bytes memory err) {
            h.probe(err, ECON);
        }
        assertEq(h.unexpectedReverts(), 1, "PoolNotInitialized must be counted unexpected");
        assertEq(h.lastUnexpected(), PoolErrors.PoolNotInitialized.selector, "wrong selector recorded");
        assertEq(h.expectedReverts(), 0, "no expected reverts here");
    }

    function test_unexpectedRevertDetected_brokenCallback() public {
        ClassifierHarness h = new ClassifierHarness();
        BrokenCallback broken = new BrokenCallback(vault);
        // Unknown custom error.
        try broken.run(0) {}
        catch (bytes memory err) {
            h.probe(err, ECON);
        }
        assertEq(h.unexpectedReverts(), 1, "unknown custom error must be unexpected");
        // Arithmetic Panic(0x11) — the C-02 mirror-direction shape.
        try broken.run(1) {}
        catch (bytes memory err) {
            h.probe(err, ECON);
        }
        assertEq(h.unexpectedReverts(), 2, "Panic(0x11) must be unexpected");
        assertEq(h.lastUnexpected(), bytes4(0x4e487b71), "panic selector must be recorded");
    }

    // ---------------------------------------------------------- no false positives
    function test_expectedRevertNotFlagged_zeroSwapAmount() public {
        ClassifierHarness h = new ClassifierHarness();
        StrictActor.Op[] memory ops = new StrictActor.Op[](1);
        ops[0] = StrictActor.Op({kind: 1, key: key, lo: 0, hi: 0, amt: int256(0), amt1: 0, zeroForOne: true});
        try actor.exec(ops) {
            assertTrue(false, "zero-amount swap must revert");
        } catch (bytes memory err) {
            h.probe(err, ECON);
        }
        assertEq(h.unexpectedReverts(), 0, "ZeroSwapAmount must not be unexpected");
        assertEq(h.expectedReverts(), 1, "ZeroSwapAmount must be counted expected");
        assertEq(h.lastUnexpected(), bytes4(0), "no unexpected selector");
    }

    function test_expectedRevertNotFlagged_routerSlippage() public {
        SupaRouter router = new SupaRouter(pm, vault);
        address swapper = address(0x4444);
        t0.mint(swapper, 1e24);
        vm.startPrank(swapper);
        t0.approve(address(router), type(uint256).max);
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: key,
            zeroForOne: true,
            recipient: swapper,
            amountIn: uint128(1e18),
            amountOutMinimum: type(uint128).max, // impossible minimum -> slippage guard
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });
        ClassifierHarness h = new ClassifierHarness();
        try router.exactInputSingle(params) {
            assertTrue(false, "impossible-minimum swap must revert");
        } catch (bytes memory err) {
            h.probe(err, ECON);
        }
        vm.stopPrank();
        assertEq(h.unexpectedReverts(), 0, "SlippageExceeded must not be unexpected");
        assertEq(h.expectedReverts(), 1, "SlippageExceeded must be counted expected");
    }

    function test_expectedRevertNotFlagged_positionDeadline() public {
        SupaPositionManager posManager = new SupaPositionManager(pm, vault, address(new PositionNFTDescriptor()));
        address owner = address(0x2222);
        t0.mint(owner, 1e24);
        t1.mint(owner, 1e24);
        vm.startPrank(owner);
        t0.approve(address(posManager), type(uint256).max);
        t1.approve(address(posManager), type(uint256).max);
        ISupaPositionManager.MintParams memory params = ISupaPositionManager.MintParams({
            poolKey: key,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 1e18,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            recipient: owner,
            deadline: block.timestamp - 1, // already past
            hookData: "",
            payWithClaims: false
        });
        ClassifierHarness h = new ClassifierHarness();
        try posManager.mint(params) {
            assertTrue(false, "past-deadline mint must revert");
        } catch (bytes memory err) {
            h.probe(err, ECON);
        }
        vm.stopPrank();
        assertEq(h.unexpectedReverts(), 0, "DeadlinePassed must not be unexpected");
        assertEq(h.expectedReverts(), 1, "DeadlinePassed must be counted expected");
    }

    function test_unexpectedRevertDetected_overRemovalPanics() public {
        // FINDING (T-6, 26 Nov 2026): removing more CLAMM liquidity than the tick's
        // gross holds reverts with Panic 0x11, NOT with the named
        // PoolErrors.LiquidityOverflow the code intends. In
        // CLAMMEngine.modifyLiquidity, _applyLiquidityDelta -> _updateTick subtracts
        // |delta| from the tick's liquidityGross BEFORE _updatePosition's guard
        // (`if (liquidityBefore < uint128(-delta128)) revert LiquidityOverflow()`,
        // CLAMMEngine.sol:274) ever runs. The seeded position holds 1e24 at
        // [-600, 600]; removing 1e26 underflows the tick gross (1e24 - 1e26) first.
        // The revert is safe (whole call reverts, no state change) but opaque, and
        // under fail_on_revert=false it would have been silently discarded — exactly
        // the T-6 concern. BIN (BinAMMEngine.sol:186) and STABLE
        // (StableAMMEngine.sol:272) check BEFORE subtracting, so they return the
        // named error. The classifier must therefore count this Panic UNEXPECTED;
        // it must NOT be bucketed as expected economics.
        ClassifierHarness h = new ClassifierHarness();
        StrictActor.Op[] memory ops = new StrictActor.Op[](1);
        ops[0] = StrictActor.Op({kind: 0, key: key, lo: -600, hi: 600, amt: -int256(1e26), amt1: 0, zeroForOne: false});
        try actor.exec(ops) {
            assertTrue(false, "over-removal must revert");
        } catch (bytes memory err) {
            h.probe(err, ECON);
        }
        assertEq(h.unexpectedReverts(), 1, "over-removal Panic must be unexpected");
        assertEq(h.expectedReverts(), 0, "over-removal Panic must not be expected");
        assertEq(h.lastUnexpected(), bytes4(0x4e487b71), "revert must be Panic(0x11)");
    }

    function test_expectedRevertNotFlagged_removeMoreThanHeldNamed() public {
        // Same over-removal, but with a second position at the same ticks so the
        // tick gross (2e24) covers the removal while the caller's own position
        // (1e24) does not: _updateTick passes and _updatePosition's guard fires
        // the NAMED PoolErrors.LiquidityOverflow, which IS expected economics.
        StrictActor actor2 = new StrictActor(vault, pm);
        t0.mint(address(actor2), 1e30);
        t1.mint(address(actor2), 1e30);
        StrictActor.Op[] memory seed = new StrictActor.Op[](1);
        seed[0] = StrictActor.Op({kind: 0, key: key, lo: -600, hi: 600, amt: int256(1e24), amt1: 0, zeroForOne: false});
        actor2.exec(seed);

        ClassifierHarness h = new ClassifierHarness();
        StrictActor.Op[] memory ops = new StrictActor.Op[](1);
        ops[0] =
            StrictActor.Op({kind: 0, key: key, lo: -600, hi: 600, amt: -int256(1e24 + 1), amt1: 0, zeroForOne: false});
        try actor.exec(ops) {
            assertTrue(false, "over-removal must revert");
        } catch (bytes memory err) {
            h.probe(err, ECON);
        }
        assertEq(h.unexpectedReverts(), 0, "named LiquidityOverflow must not be unexpected");
        assertEq(h.expectedReverts(), 1, "named LiquidityOverflow must be counted expected");
    }
}
