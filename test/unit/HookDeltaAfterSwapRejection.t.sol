// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {BaseHook} from "../../contract/plugins/external/BaseHook.sol";
import {PluginDispatcher} from "../../contract/core/PluginDispatcher.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";

contract SwapTok {
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

/// @dev afterSwap hook that always returns a configurable non-zero delta.
/// I-01 REDESIGN (2026-11-27): non-negative haircuts inside the pool's
/// configured cap are now PERMITTED (see HookDeltaAfterSwap.t.sol). This
/// mock is kept for the cases that still reject: unpermissioned hooks,
/// unconfigured pools, over-cap and negative deltas, and dust legs.
contract RejectSwapHook is BaseHook {
    int128 public steal;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function setSteal(int128 s) external {
        steal = s;
    }

    function getPluginPermissions() public pure override returns (uint32) {
        return PluginDispatcher.AFTER_SWAP_FLAG;
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, steal);
    }
}

contract SwapActor is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    constructor(SupaVault _vault, SupaPoolManager _manager) {
        vault = _vault;
        manager = _manager;
    }

    /// @dev amountSpecified > 0 is exact-input; < 0 is exact-output.
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external {
        vault.unlock(abi.encode(uint8(0), key, zeroForOne, amountSpecified));
    }

    function modify(PoolKey memory key, int24 lo, int24 hi, int256 liq, bytes32 salt) external {
        vault.unlock(abi.encode(uint8(1), key, lo, hi, liq, salt));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        uint8 op = abi.decode(data[:32], (uint8));
        if (op == 0) {
            (, PoolKey memory key, bool z, int256 amt) = abi.decode(data, (uint8, PoolKey, bool, int256));
            uint160 limit = z ? TickMathLib.MIN_SQRT_RATIO + 1 : TickMathLib.MAX_SQRT_RATIO - 1;
            manager.swap(
                key, IPoolManager.SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: limit}), ""
            );
            _resolve(key.currency0);
            _resolve(key.currency1);
        } else {
            (, PoolKey memory key, int24 lo, int24 hi, int256 liq, bytes32 salt) =
                abi.decode(data, (uint8, PoolKey, int24, int24, int256, bytes32));
            manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: salt}),
                ""
            );
            _resolve(key.currency0);
            _resolve(key.currency1);
        }
        return "";
    }

    function _resolve(Currency c) internal {
        int256 d = vault.getCurrencyDelta(address(this), c);
        if (d < 0) {
            vault.sync(c);
            SwapTok(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}

/// @title T-8 (I-01 redesign): afterSwap hook deltas that still reject
/// @notice I-01 was REDESIGNED on 2026-11-27 (founder decision, Option B):
/// a non-negative haircut on the unspecified leg, inside the pool's
/// configured cap, is now PERMITTED — the positive path lives in
/// `test/unit/HookDeltaAfterSwap.t.sol`. This suite is KEPT for the cases
/// that still revert: unpermissioned hooks, unconfigured pools, over-cap
/// and negative deltas, and dust legs (cap floors to 0). The old
/// "every non-zero delta reverts" behaviour is gone by design; these tests
/// pin the new rejection boundaries instead.
contract HookDeltaAfterSwapRejectionTest is Test {
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;

    SupaVault internal vault;
    SupaPoolManager internal manager;
    CLAMMEngine internal clamm;
    SwapTok internal t0;
    SwapTok internal t1;
    PoolKey internal key;
    PoolKey internal hookedKey;
    RejectSwapHook internal hook;
    PluginWhitelist internal wl;
    SwapActor internal victim;
    SwapActor internal attacker;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        clamm = CLAMMEngine(address(manager.clammEngine()));
        vault.setPoolManager(address(manager), true);

        SwapTok a = new SwapTok();
        SwapTok b = new SwapTok();
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });

        hook = new RejectSwapHook(manager);
        address[] memory plugins = new address[](1);
        plugins[0] = address(hook);
        wl = new PluginWhitelist(address(this), plugins);
        // Grant canReturnDelta so the rejection comes from the cap/config
        // rules themselves, not from the permission gate (that gate is covered
        // by test_afterSwapDeltaRejected_unpermissioned).
        wl.setPluginCanReturnDelta(address(hook), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        hookedKey = key;
        hookedKey.plugin = address(hook);
        hookedKey.fee = 500;
        manager.initialize(hookedKey, 1 << 96, "");

        victim = new SwapActor(vault, manager);
        attacker = new SwapActor(vault, manager);
        t0.mint(address(victim), 1_000_000 ether);
        t1.mint(address(victim), 1_000_000 ether);
        t0.mint(address(attacker), 1_000_000 ether);
        t1.mint(address(attacker), 1_000_000 ether);
        // Wide range ([-1200, 1200]) so the 1e6-wei exact-in swaps stay
        // inside seeded liquidity: with a narrow range the swaps would
        // partially fill at the range edge and exact-output delivery would
        // come up short for liquidity reasons, not hook reasons.
        victim.modify(hookedKey, -1200, 1200, 10_000_000, bytes32(0));
    }

    function _assertPoolUnchanged(int24 tickBefore, uint128 liqBefore) internal view {
        assertEq(clamm.getSlot0(hookedKey.toId()).tick(), tickBefore, "reverted swap moved the tick");
        assertEq(clamm.getLiquidity(hookedKey.toId()), liqBefore, "reverted swap moved liquidity");
    }

    /// @dev Configures the hooked pool: 500 bps cap, 100% of the haircut to LPs.
    function _configurePool() internal {
        manager.setHookDeltaConfig(
            hookedKey,
            IPoolManager.HookDeltaConfig({
                maxHaircutBps: 500, lpBps: 10000, protocolBps: 0, beneficiaryBps: 0, beneficiary: address(0)
            })
        );
    }

    function _expectSwapRevert(bytes memory expected, bool zeroForOne, int256 amountSpecified) internal {
        int24 tickBefore = clamm.getSlot0(hookedKey.toId()).tick();
        uint128 liqBefore = clamm.getLiquidity(hookedKey.toId());
        vm.expectRevert(expected);
        attacker.swap(hookedKey, zeroForOne, amountSpecified);
        _assertPoolUnchanged(tickBefore, liqBefore);
    }

    /// @notice Disabled pool (never configured) + positive hook delta, in all
    /// 8 direction/mode/sign combinations that reach the config gate: the
    /// feature is off by default, so the swap reverts HookDeltaNotEnabled.
    /// (Negative deltas hit the take-only rule first — see the negative tests.)
    function test_afterSwapDeltaRejected_disabledPool_zeroForOne_exactIn_positiveDelta() public {
        hook.setSteal(int128(1e6));
        _expectSwapRevert(
            abi.encodeWithSelector(PoolErrors.HookDeltaNotEnabled.selector, hookedKey.toId()), true, 1_000_000
        );
    }

    function test_afterSwapDeltaRejected_disabledPool_zeroForOne_exactOut_positiveDelta() public {
        hook.setSteal(int128(1e6));
        _expectSwapRevert(
            abi.encodeWithSelector(PoolErrors.HookDeltaNotEnabled.selector, hookedKey.toId()), true, -1_000
        );
    }

    function test_afterSwapDeltaRejected_disabledPool_oneForZero_exactIn_positiveDelta() public {
        hook.setSteal(int128(1e6));
        _expectSwapRevert(
            abi.encodeWithSelector(PoolErrors.HookDeltaNotEnabled.selector, hookedKey.toId()), false, 1_000_000
        );
    }

    function test_afterSwapDeltaRejected_disabledPool_oneForZero_exactOut_positiveDelta() public {
        hook.setSteal(int128(1e6));
        _expectSwapRevert(
            abi.encodeWithSelector(PoolErrors.HookDeltaNotEnabled.selector, hookedKey.toId()), false, -1_000
        );
    }

    /// @notice Negative delta on a disabled pool: the take-only rule (rule 3)
    /// fires before the config gate (rule 4), so the error is CapExceeded.
    function test_afterSwapDeltaRejected_disabledPool_negativeDelta() public {
        hook.setSteal(-int128(1e5));
        _expectSwapRevert(abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector), true, 1_000_000);
        hook.setSteal(-int128(1e5));
        _expectSwapRevert(abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector), false, -1_000);
    }

    /// @notice Over-cap on a configured pool: a 1e9 haircut dwarfs the 5% cap
    /// on any leg these swaps produce. The exact cap boundary (cap vs cap+1)
    /// is pinned in HookDeltaAfterSwap.t.sol (test_capBoundary).
    function test_afterSwapDeltaRejected_overCap() public {
        _configurePool();
        hook.setSteal(int128(1_000_000_000));
        _expectSwapRevert(abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector), true, 1_000_000);
        hook.setSteal(int128(1_000_000_000));
        _expectSwapRevert(abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector), true, -1_000);
    }

    /// @notice Negative delta on a configured pool reverts in both modes.
    function test_afterSwapDeltaRejected_negativeDelta() public {
        _configurePool();
        hook.setSteal(-int128(1e5));
        _expectSwapRevert(abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector), true, 1_000_000);
        hook.setSteal(-int128(1e5));
        _expectSwapRevert(abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector), false, -1_000);
    }

    /// @notice Unpermissioned hook (whitelisted but canReturnDelta cleared):
    /// HookDeltaNotAllowed.
    function test_afterSwapDeltaRejected_unpermissioned() public {
        wl.setPluginCanReturnDelta(address(hook), false);
        hook.setSteal(int128(1e6));
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.HookDeltaNotAllowed.selector, address(hook)));
        attacker.swap(hookedKey, true, 1_000_000);
    }

    /// @notice Dust output: a 1-wei exact-output swap has a 0 cap, so even a
    /// 1-wei hook reverts; a zero hook still succeeds.
    function test_afterSwapDeltaRejected_dustOutput() public {
        _configurePool();
        hook.setSteal(int128(1));
        _expectSwapRevert(abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector), true, -1);
        hook.setSteal(0);
        attacker.swap(hookedKey, true, -1);
    }

    /// @notice Fuzz over both directions, both modes, and the negative delta
    /// range: every negative afterSwap delta must revert (take-only rule).
    function testFuzz_afterSwapNegativeDeltaAlwaysRejected(bool zeroForOne, bool exactOut, int128 stealRaw) public {
        uint256 mag = bound(uint256(uint128(stealRaw)), 1, uint256(uint128(type(int128).max)));
        int128 steal = -int128(uint128(mag));
        hook.setSteal(steal);
        int256 amountSpecified = exactOut ? int256(-1_000) : int256(1_000_000);
        _expectSwapRevert(abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector), zeroForOne, amountSpecified);
    }

    /// @notice Control: with a zero hook delta the same four swaps succeed.
    /// Exact-output amounts are asserted exact; the seeded range is wide
    /// ([-1200, 1200]) so no swap partially fills at a liquidity edge.
    function test_afterSwapZeroDeltaSwapsSucceed() public {
        hook.setSteal(0);

        uint256 t1Before = t1.balanceOf(address(attacker));
        attacker.swap(hookedKey, true, -1_000);
        assertEq(t1.balanceOf(address(attacker)), t1Before + 1_000, "zeroForOne exactOut must deliver exactly 1000");

        uint256 t0Before = t0.balanceOf(address(attacker));
        attacker.swap(hookedKey, false, -1_000);
        assertEq(t0.balanceOf(address(attacker)), t0Before + 1_000, "oneForZero exactOut must deliver exactly 1000");

        t1Before = t1.balanceOf(address(attacker));
        attacker.swap(hookedKey, true, 1_000_000);
        assertGt(t1.balanceOf(address(attacker)), t1Before, "zeroForOne exactIn produced no output");

        t0Before = t0.balanceOf(address(attacker));
        attacker.swap(hookedKey, false, 1_000_000);
        assertGt(t0.balanceOf(address(attacker)), t0Before, "oneForZero exactIn produced no output");

        // Exact-out after price-moving swaps: still exact while inside
        // seeded liquidity.
        t1Before = t1.balanceOf(address(attacker));
        attacker.swap(hookedKey, true, -1_000);
        assertEq(t1.balanceOf(address(attacker)), t1Before + 1_000, "zeroForOne exactOut after swaps must deliver 1000");
    }
}
