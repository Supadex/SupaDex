// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IPlugin} from "../../contract/interfaces/IPlugin.sol";
import {IPoolEvents} from "../../contract/events/IPoolEvents.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {BaseHook} from "../../contract/plugins/external/BaseHook.sol";
import {PluginDispatcher} from "../../contract/core/PluginDispatcher.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";

contract DeltaTok {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev afterSwap hook returning a configurable delta, recording every call.
/// Whitelisted with `canReturnDelta` by the test; the manager decides whether
/// the returned value is a permitted haircut (I-01 redesign, 2026-11-27).
contract ConfigurableDeltaHook is BaseHook {
    int128 public hookDelta;
    bool public shouldRevert;
    uint256 public callCount;
    int128 public lastAmount0;
    int128 public lastAmount1;
    bool public lastZeroForOne;
    int256 public lastAmountSpecified;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function setDelta(int128 d) external {
        hookDelta = d;
    }

    function setShouldRevert(bool b) external {
        shouldRevert = b;
    }

    function getPluginPermissions() public pure override returns (uint32) {
        return PluginDispatcher.AFTER_SWAP_FLAG;
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (shouldRevert) revert("ConfigurableDeltaHook: forced revert");
        callCount += 1;
        lastAmount0 = delta.amount0();
        lastAmount1 = delta.amount1();
        lastZeroForOne = params.zeroForOne;
        lastAmountSpecified = params.amountSpecified;
        return (this.afterSwap.selector, hookDelta);
    }
}

/// @dev Unlock-callback actor: swaps, adds/removes/pokes liquidity, and
/// collects protocol / hook fees, recording the manager's return values in
/// storage so the test can read them after the (transient) unlock ends.
contract HookDeltaActor is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    BalanceDelta public lastSwapDelta;
    BalanceDelta public lastModifyCallerDelta;
    BalanceDelta public lastModifyFees;
    uint256 public lastCollected;

    constructor(SupaVault _vault, SupaPoolManager _manager) {
        vault = _vault;
        manager = _manager;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external {
        vault.unlock(abi.encode(uint8(0), key, zeroForOne, amountSpecified));
    }

    function modify(PoolKey memory key, int24 lo, int24 hi, int256 liq, bytes32 salt) external {
        vault.unlock(abi.encode(uint8(1), key, lo, hi, liq, salt));
    }

    function collectProtocol(Currency currency, address recipient, uint256 amount) external {
        vault.unlock(abi.encode(uint8(2), currency, recipient, amount));
    }

    function collectHook(Currency currency, address recipient, uint256 amount) external {
        vault.unlock(abi.encode(uint8(3), currency, recipient, amount));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        uint8 op = abi.decode(data[:32], (uint8));
        if (op == 0) {
            (, PoolKey memory key, bool z, int256 amt) = abi.decode(data, (uint8, PoolKey, bool, int256));
            uint160 limit = z ? TickMathLib.MIN_SQRT_RATIO + 1 : TickMathLib.MAX_SQRT_RATIO - 1;
            lastSwapDelta = manager.swap(
                key, IPoolManager.SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: limit}), ""
            );
            _resolve(key.currency0);
            _resolve(key.currency1);
        } else if (op == 1) {
            (, PoolKey memory key, int24 lo, int24 hi, int256 liq, bytes32 salt) =
                abi.decode(data, (uint8, PoolKey, int24, int24, int256, bytes32));
            (BalanceDelta cd, BalanceDelta fa) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: salt}),
                ""
            );
            lastModifyCallerDelta = cd;
            lastModifyFees = fa;
            _resolve(key.currency0);
            _resolve(key.currency1);
        } else if (op == 2) {
            (, Currency c, address recipient, uint256 amount) = abi.decode(data, (uint8, Currency, address, uint256));
            lastCollected = manager.collectProtocolFees(c, recipient, amount);
            _resolve(c);
        } else {
            (, Currency c, address recipient, uint256 amount) = abi.decode(data, (uint8, Currency, address, uint256));
            lastCollected = manager.collectHookFees(c, recipient, amount);
            _resolve(c);
        }
        return "";
    }

    function _resolve(Currency c) internal {
        int256 d = vault.getCurrencyDelta(address(this), c);
        if (d < 0) {
            vault.sync(c);
            DeltaTok(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}

/// @title I-01 redesign: permitted afterSwap hook-delta (haircut) path
/// @notice The redesign (2026-11-27) takes the haircut from the UNSPECIFIED
/// leg only — the specified leg is sacred — caps it per pool config, and
/// routes it to in-range LPs, the protocol treasury and/or the configured
/// beneficiary. These tests pin the permitted path (§9.1–§9.3 of the design
/// doc); the still-rejecting cases live in HookDeltaAfterSwapRejection.t.sol.
contract HookDeltaAfterSwapTest is Test {
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;

    SupaVault internal vault;
    SupaPoolManager internal manager;
    CLAMMEngine internal clamm;
    DeltaTok internal t0;
    DeltaTok internal t1;
    PoolKey internal key;
    PoolKey internal hookedKey;
    PoolKey internal controlKey;
    ConfigurableDeltaHook internal hook;
    HookDeltaActor internal victim;
    HookDeltaActor internal swapper;
    HookDeltaActor internal beneficiary;
    HookDeltaActor internal controller;
    IPoolManager.HookDeltaConfig internal cfg;

    uint16 internal constant MAX_HAIRCUT_BPS = 500;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        clamm = CLAMMEngine(address(manager.clammEngine()));
        vault.setPoolManager(address(manager), true);

        DeltaTok a = new DeltaTok();
        DeltaTok b = new DeltaTok();
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);

        hook = new ConfigurableDeltaHook(manager);
        address[] memory plugins = new address[](1);
        plugins[0] = address(hook);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(hook), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 0,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        controlKey = key;
        hookedKey = key;
        hookedKey.plugin = address(hook);

        beneficiary = new HookDeltaActor(vault, manager);
        controller = new HookDeltaActor(vault, manager);
        manager.setProtocolFeeController(address(controller));

        // 500 bps cap (5%); split 50% LP / 30% protocol / 20% beneficiary.
        cfg = IPoolManager.HookDeltaConfig({
            maxHaircutBps: MAX_HAIRCUT_BPS,
            lpBps: 5000,
            protocolBps: 3000,
            beneficiaryBps: 2000,
            beneficiary: address(beneficiary)
        });
        manager.setHookDeltaConfig(hookedKey, cfg);

        manager.initialize(controlKey, 1 << 96, "");
        manager.initialize(hookedKey, 1 << 96, "");

        victim = new HookDeltaActor(vault, manager);
        swapper = new HookDeltaActor(vault, manager);
        t0.mint(address(victim), 1_000_000 ether);
        t1.mint(address(victim), 1_000_000 ether);
        t0.mint(address(swapper), 1_000_000 ether);
        t1.mint(address(swapper), 1_000_000 ether);
        // Wide range ([-60000, 60000]) so the swaps stay inside seeded liquidity.
        victim.modify(hookedKey, -60000, 60000, 10_000_000, bytes32(0));
        victim.modify(controlKey, -60000, 60000, 10_000_000, bytes32(0));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev The unspecified leg of the engine delta: output leg for exactInput,
    /// input leg for exactOutput. Mirrors the manager's leg selection.
    function _unspecifiedLeg(BalanceDelta d, bool zeroForOne, bool exactInput) internal pure returns (int128) {
        if (exactInput) return zeroForOne ? d.amount1() : d.amount0();
        return zeroForOne ? d.amount0() : d.amount1();
    }

    function _unspecifiedCurrency(bool zeroForOne, bool exactInput) internal view returns (Currency) {
        if (exactInput) return zeroForOne ? hookedKey.currency1 : hookedKey.currency0;
        return zeroForOne ? hookedKey.currency0 : hookedKey.currency1;
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return uint256(uint128(x < 0 ? -x : x));
    }

    /// @dev Runs the control swap (no hook) then the hooked swap with a 1%
    /// haircut of the unspecified leg, returning both deltas and the haircut.
    /// The two pools start identical, so the engine deltas would be identical
    /// without the hook.
    function _runMatrixCase(bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta controlDelta, BalanceDelta hookedDelta, uint256 haircut)
    {
        bool exactInput = amountSpecified > 0;
        swapper.swap(controlKey, zeroForOne, amountSpecified);
        controlDelta = swapper.lastSwapDelta();
        uint256 absUnspecified = _abs(_unspecifiedLeg(controlDelta, zeroForOne, exactInput));
        haircut = absUnspecified / 100; // 1% — well inside the 5% cap.
        assertGt(haircut, 0, "matrix case: haircut must be non-zero");
        hook.setDelta(int128(uint128(haircut)));

        uint256 callsBefore = hook.callCount();
        swapper.swap(hookedKey, zeroForOne, amountSpecified);
        hookedDelta = swapper.lastSwapDelta();
        assertEq(hook.callCount(), callsBefore + 1, "afterSwap must run exactly once per swap");
        assertEq(hook.lastAmountSpecified(), amountSpecified, "hook must see the swap params");
        assertEq(hook.lastZeroForOne(), zeroForOne, "hook must see the direction");
    }

    /// @dev Specified leg identical, unspecified leg moved by exactly H.
    function _assertMatrixDeltas(
        BalanceDelta controlDelta,
        BalanceDelta hookedDelta,
        uint256 haircut,
        bool zeroForOne,
        bool exactInput
    ) internal pure {
        int128 h = int128(uint128(haircut));
        if (exactInput) {
            if (zeroForOne) {
                assertEq(hookedDelta.amount0(), controlDelta.amount0(), "specified leg (input) must be exact");
                assertEq(hookedDelta.amount1(), controlDelta.amount1() + h, "output leg must shrink by exactly H");
            } else {
                assertEq(hookedDelta.amount1(), controlDelta.amount1(), "specified leg (input) must be exact");
                assertEq(hookedDelta.amount0(), controlDelta.amount0() + h, "output leg must shrink by exactly H");
            }
        } else {
            if (zeroForOne) {
                assertEq(hookedDelta.amount1(), controlDelta.amount1(), "specified leg (output) must be exact");
                assertEq(hookedDelta.amount0(), controlDelta.amount0() + h, "input leg must grow by exactly H");
            } else {
                assertEq(hookedDelta.amount0(), controlDelta.amount0(), "specified leg (output) must be exact");
                assertEq(hookedDelta.amount1(), controlDelta.amount1() + h, "input leg must grow by exactly H");
            }
        }
    }

    /// @dev Asserts the post-swap distribution for one matrix case: protocol
    /// and beneficiary accruals, and the LP share via a zero-delta fee poke
    /// (fee-0 pool, so the only LP accrual is the haircut share).
    function _assertDistribution(uint256 haircut, Currency haircutCurrency) internal {
        (uint256 lpShare, uint256 protocolShare, uint256 beneficiaryShare) = manager._splitHookHaircut(haircut, cfg);
        assertEq(manager.protocolFeesAccrued(haircutCurrency), protocolShare, "protocol share must accrue");
        assertEq(
            manager.hookBeneficiaryFees(address(beneficiary), haircutCurrency),
            beneficiaryShare,
            "beneficiary share must accrue"
        );
        // LP share: poke the victim's position (liquidityDelta 0) and read fees.
        victim.modify(hookedKey, -60000, 60000, 0, bytes32(0));
        BalanceDelta fees = victim.lastModifyFees();
        Currency other = Currency.unwrap(haircutCurrency) == Currency.unwrap(hookedKey.currency0)
            ? hookedKey.currency1
            : hookedKey.currency0;
        // Donate rounding (design §5.3): fee growth is floored twice
        // (donate, then accrual), so the collectable LP share can be 1 wei
        // below the split share. The dust stays in the pot; never strandable.
        if (Currency.unwrap(haircutCurrency) == Currency.unwrap(hookedKey.currency0)) {
            uint256 got = uint256(uint128(fees.amount0()));
            assertLe(got, lpShare, "poke must not exceed the LP share");
            assertGe(got, lpShare - 1, "poke must be within 1 wei of the LP share (donate rounding)");
            assertEq(fees.amount1(), 0, "no LP share in the other currency");
        } else {
            uint256 got = uint256(uint128(fees.amount1()));
            assertLe(got, lpShare, "poke must not exceed the LP share");
            assertGe(got, lpShare - 1, "poke must be within 1 wei of the LP share (donate rounding)");
            assertEq(fees.amount0(), 0, "no LP share in the other currency");
        }
        assertEq(manager.protocolFeesAccrued(other), 0, "no protocol accrual in the other currency");
        assertEq(
            manager.hookBeneficiaryFees(address(beneficiary), other), 0, "no beneficiary accrual in the other currency"
        );
    }

    // ------------------------------------------------------------- §9.1 matrix

    function test_matrix_zeroForOne_exactInput() public {
        (BalanceDelta c, BalanceDelta h, uint256 haircut) = _runMatrixCase(true, 1_000_000);
        _assertMatrixDeltas(c, h, haircut, true, true);
        _assertDistribution(haircut, _unspecifiedCurrency(true, true));
    }

    function test_matrix_oneForZero_exactInput() public {
        (BalanceDelta c, BalanceDelta h, uint256 haircut) = _runMatrixCase(false, 1_000_000);
        _assertMatrixDeltas(c, h, haircut, false, true);
        _assertDistribution(haircut, _unspecifiedCurrency(false, true));
    }

    function test_matrix_zeroForOne_exactOutput() public {
        (BalanceDelta c, BalanceDelta h, uint256 haircut) = _runMatrixCase(true, -1_000);
        _assertMatrixDeltas(c, h, haircut, true, false);
        _assertDistribution(haircut, _unspecifiedCurrency(true, false));
        // Exact output stays exact: the swapper received exactly 1_000.
        assertEq(h.amount1(), -1_000, "exactOutput must deliver exactly the specified amount");
    }

    function test_matrix_oneForZero_exactOutput() public {
        (BalanceDelta c, BalanceDelta h, uint256 haircut) = _runMatrixCase(false, -1_000);
        _assertMatrixDeltas(c, h, haircut, false, false);
        _assertDistribution(haircut, _unspecifiedCurrency(false, false));
        assertEq(h.amount0(), -1_000, "exactOutput must deliver exactly the specified amount");
    }

    /// @notice The HookDeltaApplied event carries the exact split.
    function test_hookDeltaAppliedEvent() public {
        swapper.swap(controlKey, true, 1_000_000);
        BalanceDelta c = swapper.lastSwapDelta();
        uint256 haircut = _abs(c.amount1()) / 100;
        (uint256 lpShare, uint256 protocolShare, uint256 beneficiaryShare) = manager._splitHookHaircut(haircut, cfg);
        hook.setDelta(int128(uint128(haircut)));
        vm.expectEmit(true, true, false, true, address(manager));
        emit IPoolEvents.HookDeltaApplied(
            hookedKey.toId(), hookedKey.currency1, haircut, lpShare, protocolShare, beneficiaryShare
        );
        swapper.swap(hookedKey, true, 1_000_000);
    }

    /// @notice End-to-end: protocol share is collected by the controller.
    function test_collectProtocolShareEndToEnd() public {
        (,, uint256 haircut) = _runMatrixCase(true, 1_000_000);
        Currency hc = _unspecifiedCurrency(true, true);
        (, uint256 protocolShare,) = manager._splitHookHaircut(haircut, cfg);
        assertGt(protocolShare, 0, "protocol share must be non-zero");
        uint256 before = DeltaTok(Currency.unwrap(hc)).balanceOf(address(controller));
        controller.collectProtocol(hc, address(controller), protocolShare);
        assertEq(controller.lastCollected(), protocolShare, "controller must collect the full protocol share");
        assertEq(
            DeltaTok(Currency.unwrap(hc)).balanceOf(address(controller)),
            before + protocolShare,
            "protocol share must land in the controller wallet"
        );
        assertEq(manager.protocolFeesAccrued(hc), 0, "protocol accrual must be drained");
    }

    /// @notice End-to-end: beneficiary share is collected by the beneficiary.
    function test_collectBeneficiaryShareEndToEnd() public {
        (,, uint256 haircut) = _runMatrixCase(true, 1_000_000);
        Currency hc = _unspecifiedCurrency(true, true);
        (,, uint256 beneficiaryShare) = manager._splitHookHaircut(haircut, cfg);
        assertGt(beneficiaryShare, 0, "beneficiary share must be non-zero");
        uint256 before = DeltaTok(Currency.unwrap(hc)).balanceOf(address(beneficiary));
        beneficiary.collectHook(hc, address(beneficiary), beneficiaryShare);
        assertEq(beneficiary.lastCollected(), beneficiaryShare, "beneficiary must collect the full share");
        assertEq(
            DeltaTok(Currency.unwrap(hc)).balanceOf(address(beneficiary)),
            before + beneficiaryShare,
            "beneficiary share must land in the beneficiary wallet"
        );
        assertEq(manager.hookBeneficiaryFees(address(beneficiary), hc), 0, "beneficiary accrual must be drained");
    }

    /// @notice End-to-end: LP share is collected by removing liquidity.
    function test_collectLpShareViaRemovalEndToEnd() public {
        (,, uint256 haircut) = _runMatrixCase(true, 1_000_000);
        (uint256 lpShare,,) = manager._splitHookHaircut(haircut, cfg);
        assertGt(lpShare, 0, "LP share must be non-zero");
        // Poke first: the LP share is the fee accrual; the poke settles it to
        // the victim, so the victim's balance grows by exactly the LP share
        // (fee-0 pool: no other fee accrual exists).
        Currency hc = _unspecifiedCurrency(true, true);
        uint256 before = DeltaTok(Currency.unwrap(hc)).balanceOf(address(victim));
        victim.modify(hookedKey, -60000, 60000, 0, bytes32(0));
        uint256 got = DeltaTok(Currency.unwrap(hc)).balanceOf(address(victim)) - before;
        assertLe(got, lpShare, "poke must not pay more than the LP share");
        assertGe(got, lpShare - 1, "poke must pay the LP share within 1 wei (donate rounding)");
    }

    // ------------------------------------------------------------- §9.2 rounding

    /// @notice Split rounding: haircuts of 1, 2, 3 wei across several split
    /// configs — shares sum exactly to H, zero-bps recipients get exactly zero.
    function test_splitRounding_dustHaircuts() public {
        address ben = address(0xBEEF);
        IPoolManager.HookDeltaConfig memory c3333 = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 3333, protocolBps: 3333, beneficiaryBps: 3334, beneficiary: ben
        });
        // H=1: both floors are 0, remainder 1 goes to the beneficiary.
        (uint256 lp, uint256 pr, uint256 be) = manager._splitHookHaircut(1, c3333);
        assertEq(lp, 0);
        assertEq(pr, 0);
        assertEq(be, 1);
        (lp, pr, be) = manager._splitHookHaircut(2, c3333);
        assertEq(lp + pr + be, 2);
        assertEq(be, 2);
        (lp, pr, be) = manager._splitHookHaircut(3, c3333);
        assertEq(lp + pr + be, 3);
        assertEq(be, 3);

        // 5000/5000/0: the remainder folds to the LP share.
        IPoolManager.HookDeltaConfig memory c5050 = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 5000, protocolBps: 5000, beneficiaryBps: 0, beneficiary: address(0)
        });
        (lp, pr, be) = manager._splitHookHaircut(1, c5050);
        assertEq(lp, 1);
        assertEq(pr, 0);
        assertEq(be, 0);
        (lp, pr, be) = manager._splitHookHaircut(3, c5050);
        assertEq(lp, 2);
        assertEq(pr, 1);
        assertEq(be, 0);

        // 0/0/10000: the beneficiary takes everything.
        IPoolManager.HookDeltaConfig memory cBen = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 0, protocolBps: 0, beneficiaryBps: 10000, beneficiary: ben
        });
        (lp, pr, be) = manager._splitHookHaircut(1, cBen);
        assertEq(lp, 0);
        assertEq(pr, 0);
        assertEq(be, 1);

        // 0/5000/5000: zero-bps LP gets exactly zero.
        IPoolManager.HookDeltaConfig memory cNoLp = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 0, protocolBps: 5000, beneficiaryBps: 5000, beneficiary: ben
        });
        (lp, pr, be) = manager._splitHookHaircut(2, cNoLp);
        assertEq(lp, 0);
        assertEq(pr, 1);
        assertEq(be, 1);
    }

    /// @notice Split conservation fuzz: for any haircut and any valid split,
    /// the shares sum exactly to the haircut, each is <= the haircut, and a
    /// zero-bps recipient receives exactly zero.
    function testFuzz_splitConservation(uint256 haircutRaw, uint16 lpBpsRaw, uint16 protocolBpsRaw) public {
        uint256 haircut = bound(haircutRaw, 0, uint256(uint128(type(int128).max)));
        uint256 lpBps = bound(lpBpsRaw, 0, 10_000);
        uint256 protocolBps = bound(protocolBpsRaw, 0, 10_000 - lpBps);
        uint256 beneficiaryBps = 10_000 - lpBps - protocolBps;
        address ben = beneficiaryBps > 0 ? address(0xBEEF) : address(0);
        IPoolManager.HookDeltaConfig memory c = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500,
            lpBps: uint16(lpBps),
            protocolBps: uint16(protocolBps),
            beneficiaryBps: uint16(beneficiaryBps),
            beneficiary: ben
        });
        (uint256 lp, uint256 pr, uint256 be) = manager._splitHookHaircut(haircut, c);
        assertEq(lp + pr + be, haircut, "shares must sum exactly to the haircut");
        assertLe(lp, haircut);
        assertLe(pr, haircut);
        assertLe(be, haircut);
        if (lpBps == 0) assertEq(lp, 0, "zero-bps LP must receive exactly zero");
        if (protocolBps == 0) assertEq(pr, 0, "zero-bps protocol must receive exactly zero");
        if (beneficiaryBps == 0) assertEq(be, 0, "zero-bps beneficiary must receive exactly zero");
        if (lpBps == 10_000) assertEq(lp, haircut, "100% LP must receive the whole haircut");
        if (protocolBps == 10_000) assertEq(pr, haircut, "100% protocol must receive the whole haircut");
        if (beneficiaryBps == 10_000) assertEq(be, haircut, "100% beneficiary must receive the whole haircut");
    }

    /// @notice Dust output: a 1-wei exact-output swap has a 0 cap (the cap
    /// floors to 0), so any non-zero hook reverts; a zero hook still succeeds.
    function test_dustOutput_anyNonZeroHookReverts() public {
        hook.setDelta(1);
        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        swapper.swap(hookedKey, true, -1);
        hook.setDelta(0);
        swapper.swap(hookedKey, true, -1);
        assertEq(swapper.lastSwapDelta().amount1(), -1, "dust exactOutput must still deliver exactly 1 wei");
    }

    /// @notice Donate dust: a 1-wei LP share donates with zero collectable fee
    /// growth (pre-existing donate rounding over 10M liquidity) — the swap
    /// still succeeds, the pot still balances, nothing reverts.
    function test_donateDust_oneWeiLpShareRoundsToZeroGrowth() public {
        IPoolManager.HookDeltaConfig memory lpOnly = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 10000, protocolBps: 0, beneficiaryBps: 0, beneficiary: address(0)
        });
        manager.setHookDeltaConfig(hookedKey, lpOnly);
        hook.setDelta(1);
        // exactOutput: unspecified leg is the input (~1_001 wei); cap is ~50,
        // so H=1 is permitted.
        swapper.swap(hookedKey, true, -1_000);
        assertEq(swapper.lastSwapDelta().amount1(), -1_000, "exactOutput must stay exact");
        victim.modify(hookedKey, -60000, 60000, 0, bytes32(0));
        BalanceDelta fees = victim.lastModifyFees();
        assertEq(fees.amount0(), 0, "1-wei LP share must round to zero collectable growth (donate dust)");
        assertEq(fees.amount1(), 0);
        assertEq(manager.protocolFeesAccrued(hookedKey.currency0), 0, "no protocol accrual for an LP-only split");
    }

    // ------------------------------------------------------- §9.3 edges + reverts

    /// @notice A zero hook still succeeds with the config set: no haircut, no
    /// accruals, no HookDeltaApplied event (fast path).
    function test_zeroHookSucceedsWithConfig() public {
        hook.setDelta(0);
        swapper.swap(hookedKey, true, 1_000_000);
        assertGt(_abs(swapper.lastSwapDelta().amount1()), 0, "zero-hook swap must produce output");
        assertEq(manager.protocolFeesAccrued(hookedKey.currency1), 0, "no protocol accrual for a zero haircut");
        assertEq(manager.hookBeneficiaryFees(address(beneficiary), hookedKey.currency1), 0);
    }

    /// @notice Hook returning type(int128).max reverts on the cap, not on overflow.
    function test_hookReturnsInt128Max_revertsOnCap() public {
        hook.setDelta(type(int128).max);
        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        swapper.swap(hookedKey, true, 1_000_000);
    }

    /// @notice Negative delta reverts in both modes (hooks only take, never give).
    function test_negativeDeltaReverts_bothModes() public {
        hook.setDelta(-1);
        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        swapper.swap(hookedKey, true, 1_000_000);
        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        swapper.swap(hookedKey, true, -1_000);
    }

    /// @notice Haircut equal to the unspecified leg (100%) reverts via the cap.
    function test_haircutEqualToUnspecifiedLeg_reverts() public {
        swapper.swap(controlKey, true, 1_000_000);
        int128 unspecified = swapper.lastSwapDelta().amount1();
        hook.setDelta(-unspecified); // H == |S| (100% of the leg).
        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        swapper.swap(hookedKey, true, 1_000_000);
    }

    /// @notice Whitelisted but without canReturnDelta: HookDeltaNotAllowed.
    function test_unpermissionedHook_reverts() public {
        ConfigurableDeltaHook hook2 = new ConfigurableDeltaHook(manager);
        address[] memory plugins = new address[](2);
        plugins[0] = address(hook);
        plugins[1] = address(hook2);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(hook), true);
        // hook2 deliberately left without the flag.
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory key2 = hookedKey;
        key2.plugin = address(hook2);
        manager.setHookDeltaConfig(key2, cfg);
        manager.initialize(key2, 1 << 96, "");
        victim.modify(key2, -60000, 60000, 10_000_000, bytes32(0));
        hook2.setDelta(1_000);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.HookDeltaNotAllowed.selector, address(hook2)));
        swapper.swap(key2, true, 1_000_000);
    }

    /// @notice Delisted plugin: the swap reverts at the whitelist gate before
    /// the hook ever runs (PluginNotWhitelisted, not HookDeltaNotAllowed).
    function test_delistedHook_revertsAtWhitelistGate() public {
        address[] memory plugins = new address[](1);
        plugins[0] = address(hook);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(hook), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));
        hook.setDelta(1_000);
        wl.setPluginWhitelisted(address(hook), false);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PluginNotWhitelisted.selector, address(hook)));
        swapper.swap(hookedKey, true, 1_000_000);
    }

    /// @notice Pool with no config (maxHaircutBps == 0) + non-zero hook:
    /// HookDeltaNotEnabled.
    function test_unconfiguredPool_reverts() public {
        PoolKey memory key2 = hookedKey;
        key2.fee = 3000; // distinct pool, never configured.
        manager.initialize(key2, 1 << 96, "");
        victim.modify(key2, -60000, 60000, 10_000_000, bytes32(0));
        hook.setDelta(1_000);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.HookDeltaNotEnabled.selector, key2.toId()));
        swapper.swap(key2, true, 1_000_000);
    }

    /// @notice Exactly at the cap succeeds; cap + 1 reverts.
    function test_capBoundary() public {
        swapper.swap(controlKey, true, 1_000_000);
        uint256 absUnspecified = _abs(swapper.lastSwapDelta().amount1());
        uint256 cap = absUnspecified * MAX_HAIRCUT_BPS / 10_000;
        assertGt(cap, 0, "cap must be non-zero for the boundary test");

        hook.setDelta(int128(uint128(cap + 1)));
        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        swapper.swap(hookedKey, true, 1_000_000);

        hook.setDelta(int128(uint128(cap)));
        swapper.swap(hookedKey, true, 1_000_000);
        // The output leg shrank by exactly the cap vs the engine delta the
        // hook observed (recorded by the hook before the haircut was applied).
        BalanceDelta h = swapper.lastSwapDelta();
        assertEq(
            hook.lastAmount1() + int128(uint128(cap)), h.amount1(), "at-cap haircut must shrink output by exactly cap"
        );
    }

    /// @notice A reverting hook fails the whole swap atomically (PluginCallFailed)
    /// and pool state is unchanged.
    function test_revertingHook_revertsWholeSwap() public {
        hook.setShouldRevert(true);
        int24 tickBefore = clamm.getSlot0(hookedKey.toId()).tick();
        uint128 liqBefore = clamm.getLiquidity(hookedKey.toId());
        uint256 potBefore = manager.poolReserves(hookedKey.toId(), hookedKey.currency0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PluginErrors.PluginCallFailed.selector,
                address(hook),
                IPlugin.afterSwap.selector,
                abi.encodeWithSignature("Error(string)", "ConfigurableDeltaHook: forced revert")
            )
        );
        swapper.swap(hookedKey, true, 1_000_000);
        assertEq(clamm.getSlot0(hookedKey.toId()).tick(), tickBefore, "reverted swap moved the tick");
        assertEq(clamm.getLiquidity(hookedKey.toId()), liqBefore, "reverted swap moved liquidity");
        assertEq(manager.poolReserves(hookedKey.toId(), hookedKey.currency0), potBefore, "reverted swap moved the pot");
    }

    // ------------------------------------------------------- §9.3 config validation

    function test_configValidation() public {
        PoolKey memory k = hookedKey;
        // Splits not exhaustive.
        IPoolManager.HookDeltaConfig memory badSum = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 5000, protocolBps: 3000, beneficiaryBps: 1000, beneficiary: address(beneficiary)
        });
        vm.expectRevert(PoolErrors.InvalidHookDeltaConfig.selector);
        manager.setHookDeltaConfig(k, badSum);
        // Hard cap exceeded.
        IPoolManager.HookDeltaConfig memory overCap = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 1001, lpBps: 10000, protocolBps: 0, beneficiaryBps: 0, beneficiary: address(0)
        });
        vm.expectRevert(PoolErrors.InvalidHookDeltaConfig.selector);
        manager.setHookDeltaConfig(k, overCap);
        // Beneficiary share with zero address.
        IPoolManager.HookDeltaConfig memory noBen = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 8000, protocolBps: 0, beneficiaryBps: 2000, beneficiary: address(0)
        });
        vm.expectRevert(PoolErrors.InvalidHookDeltaConfig.selector);
        manager.setHookDeltaConfig(k, noBen);
        // Beneficiary with zero share.
        IPoolManager.HookDeltaConfig memory benNoShare = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 8000, protocolBps: 2000, beneficiaryBps: 0, beneficiary: address(beneficiary)
        });
        vm.expectRevert(PoolErrors.InvalidHookDeltaConfig.selector);
        manager.setHookDeltaConfig(k, benNoShare);
        // Non-owner caller.
        vm.prank(address(0xBAD));
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        manager.setHookDeltaConfig(k, cfg);
        // Boundary: exactly the 10% hard cap is accepted.
        IPoolManager.HookDeltaConfig memory atCap = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 1000, lpBps: 10000, protocolBps: 0, beneficiaryBps: 0, beneficiary: address(0)
        });
        manager.setHookDeltaConfig(k, atCap);
        assertEq(manager.hookDeltaConfigs(k.toId()).maxHaircutBps, 1000, "hard-cap config must be accepted");
        // Switching off (maxHaircutBps == 0) is accepted.
        IPoolManager.HookDeltaConfig memory off = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 0, lpBps: 10000, protocolBps: 0, beneficiaryBps: 0, beneficiary: address(0)
        });
        manager.setHookDeltaConfig(k, off);
        assertEq(manager.hookDeltaConfigs(k.toId()).maxHaircutBps, 0, "switching off must be accepted");
    }

    /// @notice Setting a config emits HookDeltaConfigSet.
    function test_configSetEvent() public {
        vm.expectEmit(true, false, false, true, address(manager));
        emit IPoolEvents.HookDeltaConfigSet(
            hookedKey.toId(), cfg.maxHaircutBps, cfg.lpBps, cfg.protocolBps, cfg.beneficiaryBps, cfg.beneficiary
        );
        manager.setHookDeltaConfig(hookedKey, cfg);
    }

    // ------------------------------------------------------- §9.3 collectHookFees

    /// @notice A non-beneficiary (no accrual) cannot collect.
    function test_collectHookFees_nonBeneficiaryReverts() public {
        (BalanceDelta ignoredC, BalanceDelta ignoredH, uint256 ignoredHaircut) = _runMatrixCase(true, 1_000_000);
        ignoredC;
        ignoredH;
        ignoredHaircut;
        Currency hc = _unspecifiedCurrency(true, true);
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        swapper.collectHook(hc, address(swapper), 1);
    }

    /// @notice Over-collection clamps to the accrual; a second collection
    /// after draining reverts (empty accrual).
    function test_collectHookFees_overCollectionClamps() public {
        (,, uint256 haircut) = _runMatrixCase(true, 1_000_000);
        Currency hc = _unspecifiedCurrency(true, true);
        (,, uint256 beneficiaryShare) = manager._splitHookHaircut(haircut, cfg);
        beneficiary.collectHook(hc, address(beneficiary), beneficiaryShare + 1_000_000);
        assertEq(beneficiary.lastCollected(), beneficiaryShare, "over-collection must clamp to the accrual");
        assertEq(manager.hookBeneficiaryFees(address(beneficiary), hc), 0, "accrual must be drained");
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        beneficiary.collectHook(hc, address(beneficiary), 1);
    }

    /// @notice Partial collection leaves the remainder collectable.
    function test_collectHookFees_partialCollection() public {
        (,, uint256 haircut) = _runMatrixCase(true, 1_000_000);
        Currency hc = _unspecifiedCurrency(true, true);
        (,, uint256 beneficiaryShare) = manager._splitHookHaircut(haircut, cfg);
        assertGe(beneficiaryShare, 2, "beneficiary share must allow a split collection");
        uint256 first = beneficiaryShare / 2;
        beneficiary.collectHook(hc, address(beneficiary), first);
        assertEq(beneficiary.lastCollected(), first);
        assertEq(manager.hookBeneficiaryFees(address(beneficiary), hc), beneficiaryShare - first);
        beneficiary.collectHook(hc, address(beneficiary), beneficiaryShare - first);
        assertEq(manager.hookBeneficiaryFees(address(beneficiary), hc), 0);
    }

    /// @notice A third-party recipient's credited delta cannot be settled by
    /// the beneficiary inside the beneficiary's unlock (only the locker can
    /// settle its own delta), so the unlock reverts CurrencyNotSettled. In
    /// practice the beneficiary collects to itself (like SupaFeeCollector
    /// does for protocol fees) and pays onward with a normal transfer. This
    /// mirrors collectProtocolFees, which has the same settlement rule.
    function test_collectHookFees_thirdPartyRecipientCannotSettle() public {
        (,, uint256 haircut) = _runMatrixCase(true, 1_000_000);
        Currency hc = _unspecifiedCurrency(true, true);
        (,, uint256 beneficiaryShare) = manager._splitHookHaircut(haircut, cfg);
        vm.expectRevert(abi.encodeWithSelector(VaultErrors.CurrencyNotSettled.selector, hc, int256(beneficiaryShare)));
        beneficiary.collectHook(hc, address(0x1234), beneficiaryShare);
        // The accrual is untouched: the revert rolled the collection back.
        assertEq(manager.hookBeneficiaryFees(address(beneficiary), hc), beneficiaryShare);
    }
}
