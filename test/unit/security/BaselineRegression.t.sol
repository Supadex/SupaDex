// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Regression tests for the 2026-10-21 baseline review (SDX-001..010).
// Each `test_PoCn_*` is the original proof-of-concept inverted: it now asserts the fixed behaviour.
import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../../contract/core/SupaPoolManager.sol";
import {StableAMMEngine} from "../../../contract/core/engines/StableAMMEngine.sol";
import {SupaRouter} from "../../../contract/periphery/SupaRouter.sol";
import {ISupaRouter} from "../../../contract/interfaces/ISupaRouter.sol";
import {IPoolManager} from "../../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../../contract/interfaces/IUnlockCallback.sol";
import {IPlugin} from "../../../contract/interfaces/IPlugin.sol";
import {IPluginWhitelist} from "../../../contract/interfaces/IPluginWhitelist.sol";
import {PluginWhitelist} from "../../../contract/governance/PluginWhitelist.sol";
import {SupaTimelock} from "../../../contract/governance/SupaTimelock.sol";
import {CircuitBreaker} from "../../../contract/security/CircuitBreaker.sol";
import {VolatilityTWAPOracle} from "../../../contract/plugins/native/VolatilityTWAPOracle.sol";
import {PoolKey, CurveType} from "../../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../../contract/types/PoolId.sol";
import {Currency} from "../../../contract/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../../../contract/types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../../contract/types/Slot0.sol";
import {PoolErrors} from "../../../contract/errors/PoolErrors.sol";
import {VaultErrors} from "../../../contract/errors/VaultErrors.sol";
import {GovernanceErrors} from "../../../contract/errors/GovernanceErrors.sol";
import {CircuitBreakerErrors} from "../../../contract/errors/CircuitBreakerErrors.sol";
import {SecurityTestSetup} from "../../helpers/SecurityTestSetup.sol";
import {MockRouterToken} from "../SupaRouter.t.sol";

/// @dev Rebasing token: balances are shares × index / 1e18.
contract RebasingToken {
    uint8 public constant decimals = 18;
    uint256 public index = 1e18;
    mapping(address => uint256) public shares;
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address a) external view returns (uint256) {
        return shares[a] * index / 1e18;
    }

    function rebase(uint256 newIndex) external {
        index = newIndex;
    }

    function mint(address to, uint256 amount) external {
        shares[to] += amount * 1e18 / index;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 s = amount * 1e18 / index;
        shares[from] -= s;
        shares[to] += s;
    }
}

/// @dev Performs modifyLiquidity ops inside one unlock and settles via sync → transfer → settle.
contract Actor is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    constructor(SupaVault v, SupaPoolManager m) {
        vault = v;
        manager = m;
    }

    function run(PoolKey memory key, int256[] memory liqDeltas, int24 lo, int24 hi) external {
        vault.unlock(abi.encode(key, liqDeltas, lo, hi));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int256[] memory d, int24 lo, int24 hi) =
            abi.decode(data, (PoolKey, int256[], int24, int24));
        for (uint256 i; i < d.length; i++) {
            manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: d[i], salt: 0}),
                ""
            );
        }
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(Currency c) internal {
        int256 delta = vault.getCurrencyDelta(address(this), c);
        if (delta < 0) {
            vault.sync(c);
            MockRouterToken(Currency.unwrap(c)).transfer(address(vault), uint256(-delta));
            vault.settle(c);
        } else if (delta > 0) {
            vault.take(c, address(this), uint256(delta));
        }
    }
}

/// @dev Plugin that reports no permissions at initialize, then tries to grant itself every hook.
contract FlippingPlugin is IPlugin {
    uint32 public perms;

    function setPerms(uint32 p) external {
        perms = p;
    }

    function getPluginPermissions() external view returns (uint32) {
        return perms;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert("hooked");
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert("hooked");
    }

    function beforeModifyLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert("hooked");
    }

    function afterModifyLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta, BalanceDelta) {
        revert("hooked");
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, uint24)
    {
        revert("hooked");
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert("hooked");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("hooked");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("hooked");
    }
}

contract RevertingPermissionsPlugin {
    function getPluginPermissions() external pure returns (uint32) {
        revert("no perms");
    }
}

contract BaselineRegressionTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    SupaVault vault;
    SupaPoolManager manager;
    SupaRouter router;
    MockRouterToken t0;
    MockRouterToken t1;
    Currency c0;
    Currency c1;
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        vault.setPoolManager(address(manager), true);
        SecurityTestSetup.installEmptyWhitelist(manager, address(this));
        router = new SupaRouter(manager, vault);
        MockRouterToken a = new MockRouterToken("A", "A");
        MockRouterToken b = new MockRouterToken("B", "B");
        if (address(a) > address(b)) (a, b) = (b, a);
        t0 = a;
        t1 = b;
        c0 = Currency.wrap(address(a));
        c1 = Currency.wrap(address(b));
        t0.mint(address(this), 1_000_000_000 ether);
        t1.mint(address(this), 1_000_000_000 ether);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _key(CurveType ct) internal view returns (PoolKey memory) {
        // STABLE: tickSpacing must be 1 and A (= 60, the A these baselines were written against) is an init param.
        int24 spacing = ct == CurveType.STABLE_AMM ? int24(1) : int24(60);
        return PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: spacing, plugin: address(0), curveType: ct});
    }

    function _initPool(PoolKey memory k) internal {
        if (k.curveType == CurveType.STABLE_AMM) manager.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(60)), "");
        else manager.initialize(k, SQRT_1_1, "");
    }

    function _actor(uint256 fund) internal returns (Actor act) {
        act = new Actor(vault, manager);
        t0.mint(address(act), fund);
        t1.mint(address(act), fund);
    }

    function _one(int256 x) internal pure returns (int256[] memory a) {
        a = new int256[](1);
        a[0] = x;
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint128 amountIn) internal returns (uint256) {
        return router.exactInputSingle(
            ISupaRouter.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: "",
                payWithClaims: false,
                receiveAsClaims: false,
                deadline: block.timestamp
            })
        );
    }

    function _stablePool(uint256 shares) internal returns (PoolKey memory key) {
        key = _key(CurveType.STABLE_AMM);
        key.fee = 400;
        _initPool(key);
        _actor(type(uint128).max).run(key, _one(int256(shares)), 0, 0);
    }

    // ------------------------------------------------------------------ SDX-003 vault sync/settle

    /// PoC-1 inverted: a stray 1-wei donation no longer bricks router swaps.
    function test_PoC1_strayDonationDoesNotBrickSwaps() public {
        PoolKey memory key = _key(CurveType.CLAMM);
        _initPool(key);
        _actor(1_000_000 ether).run(key, _one(int256(100_000 ether)), -1200, 1200);
        assertGt(_swap(key, true, 1 ether), 0);

        t0.transfer(address(vault), 1);
        assertGt(_swap(key, true, 1 ether), 0, "swap still works after donation");
        assertGt(_swap(key, false, 1 ether), 0);

        // The donation is surplus (not credited to anyone) and can be swept by the owner.
        uint256 swept = vault.sweepSurplus(c0, address(0xFEE));
        assertEq(swept, 1);
        assertEq(t0.balanceOf(address(0xFEE)), 1);
    }

    /// Settle without a prior sync reverts; native settle with ERC-20 currency rejects msg.value.
    function test_settleRequiresSync() public {
        vault.unlock(abi.encode(uint8(1)));
    }

    function test_sweepSurplusNotDuringUnlockAndOnlyOwner() public {
        t0.transfer(address(vault), 5);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        vault.sweepSurplus(c0, address(0xBAD));
        vm.expectRevert(VaultErrors.ZeroAmount.selector);
        vault.sweepSurplus(c1, address(this));
    }

    /// Positive and negative rebases of a vault-held token do not brick swaps; positive rebase is sweepable surplus.
    function test_rebasingTokenDoesNotBrickSwaps() public {
        RebasingToken rb = new RebasingToken();
        MockRouterToken other = new MockRouterToken("O", "O");
        (address a, address b) =
            address(rb) < address(other) ? (address(rb), address(other)) : (address(other), address(rb));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        _initPool(key);
        Actor act = new Actor(vault, manager);
        rb.mint(address(act), 1_000_000 ether);
        other.mint(address(act), 1_000_000 ether);
        act.run(key, _one(int256(100_000 ether)), -1200, 1200);

        rb.mint(address(this), 1_000 ether);
        other.mint(address(this), 1_000 ether);
        rb.approve(address(router), type(uint256).max);
        other.approve(address(router), type(uint256).max);
        bool rbIs0 = a == address(rb);
        Currency rbC = Currency.wrap(address(rb));

        // Positive rebase (index ×2): vault balance > reserves.
        rb.rebase(2e18);
        assertGt(_swap(key, rbIs0, 2 ether), 0, "swap paying rebasing token after +rebase");
        assertGt(_swap(key, !rbIs0, 2 ether), 0, "swap receiving rebasing token after +rebase");
        uint256 surplus = vault.sweepSurplus(rbC, address(0xFEE));
        assertGt(surplus, 0);

        // Negative rebase (index ÷2): settle still credits exactly what arrives, swaps paying in still work.
        rb.rebase(1e18);
        assertGt(_swap(key, rbIs0, 2 ether), 0, "swap paying rebasing token after -rebase");
        // Documented limitation: after a negative rebase the vault holds less than reservesOf (no surplus).
        vm.expectRevert(VaultErrors.ZeroAmount.selector);
        vault.sweepSurplus(rbC, address(0xFEE));
    }

    // ------------------------------------------------------------------ SDX-007 governance / authority

    /// PoC-3 inverted: the vault owner can no longer mint itself credit via accountDelta.
    function test_PoC3_ownerCannotAccountDelta() public {
        PoolKey memory key = _key(CurveType.CLAMM);
        _initPool(key);
        _actor(1_000_000 ether).run(key, _one(int256(100_000 ether)), -1200, 1200);
        uint256 lpFunds = vault.reservesOf(c0);
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        vault.unlock(abi.encode(uint8(0), lpFunds));
        assertEq(vault.reservesOf(c0), lpFunds);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint8 mode = abi.decode(data, (uint8));
        if (mode == 0) {
            (, uint256 amt) = abi.decode(data, (uint8, uint256));
            vault.accountDelta(address(this), c0, int256(amt));
            vault.take(c0, address(0xBEEF), amt);
        } else {
            t0.transfer(address(vault), 1 ether);
            vm.expectRevert(abi.encodeWithSelector(VaultErrors.CurrencyNotSynced.selector, c0));
            vault.settle(c0);
            vault.sync(c0);
            vm.expectRevert(VaultErrors.NonZeroNativeValue.selector);
            vault.settle{value: 1}(c0);
            vm.expectRevert(VaultErrors.ZeroAmount.selector);
            vault.settle(c0); // balance unchanged since sync
            // clean up: surplus stays in the vault, unlock has no open deltas
        }
        return "";
    }

    /// Timelock role changes only through a scheduled + delayed self-call.
    function test_timelockRoleChangesRequireDelay() public {
        address[] memory list = new address[](1);
        list[0] = address(this);
        address[] memory ex = new address[](1);
        ex[0] = address(0xE1); // ADR-0010: separate executor
        SupaTimelock tl = new SupaTimelock(1 days, address(this), list, ex, list);

        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setProposer(address(0xBAD), true);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setAdmin(address(0xBAD));

        bytes memory data = abi.encodeWithSelector(SupaTimelock.setProposer.selector, address(0xA1), true);
        tl.schedule(address(tl), 0, data, bytes32(0), bytes32(0), 1 days);
        vm.prank(ex[0]);
        vm.expectRevert(GovernanceErrors.ExecutionDelayNotMet.selector);
        tl.execute(address(tl), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, true, address(tl));
        emit SupaTimelock.ProposerSet(address(0xA1), true);
        vm.prank(ex[0]);
        tl.execute(address(tl), 0, data, bytes32(0), bytes32(0));
        assertTrue(tl.isProposer(address(0xA1)));
    }

    function test_adminSettersEmitEvents() public {
        vm.expectEmit(true, true, false, false, address(manager));
        emit SupaPoolManager.OwnershipTransferred(address(this), address(0xB0B));
        manager.transferOwnership(address(0xB0B));
    }

    // ------------------------------------------------------------------ SDX-008 withdraw-only pause

    function test_pauseBlocksSwapsAndAddsButNotWithdrawals() public {
        address[] memory guardians = new address[](1);
        guardians[0] = address(this);
        CircuitBreaker cb = new CircuitBreaker(address(this), guardians);
        manager.setCircuitBreaker(cb);
        vault.setCircuitBreaker(cb);

        PoolKey memory key = _key(CurveType.CLAMM);
        _initPool(key);
        Actor lp = _actor(1_000_000 ether);
        lp.run(key, _one(int256(100_000 ether)), -1200, 1200);
        _swap(key, true, 1 ether);

        cb.pausePool(key.toId());
        vm.expectRevert(CircuitBreakerErrors.PoolPaused.selector);
        _swap(key, true, 1 ether);
        vm.expectRevert(CircuitBreakerErrors.PoolPaused.selector);
        lp.run(key, _one(int256(1 ether)), -1200, 1200);

        cb.pauseVault();
        uint256 before0 = t0.balanceOf(address(lp));
        lp.run(key, _one(-int256(100_000 ether)), -1200, 1200); // full exit while vault + pool paused
        assertGt(t0.balanceOf(address(lp)), before0, "LP can exit during pause");
    }

    // ------------------------------------------------------------------ SDX-009 plugin permission cache

    function test_pluginCannotChangeOwnPermissions() public {
        FlippingPlugin p = new FlippingPlugin();
        address[] memory plugins = new address[](1);
        plugins[0] = address(p);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory key = _key(CurveType.CLAMM);
        key.plugin = address(p);
        _initPool(key);
        assertEq(manager.pluginPermissions(key.toId()), 0);

        p.setPerms(0xFF); // every hook now reverts if dispatched
        _actor(1_000_000 ether).run(key, _one(int256(100_000 ether)), -1200, 1200);
        assertGt(_swap(key, true, 1 ether), 0, "cached (empty) permissions still used");
    }

    function test_pluginPermissionReadFailsClosed() public {
        RevertingPermissionsPlugin p = new RevertingPermissionsPlugin();
        address[] memory plugins = new address[](1);
        plugins[0] = address(p);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));
        PoolKey memory key = _key(CurveType.CLAMM);
        key.plugin = address(p);
        vm.expectRevert();
        _initPool(key);
    }

    // ------------------------------------------------------------------ SDX-004 CLAMM gap crossing

    /// PoC-4 inverted: price crosses an empty range to reach out-of-range liquidity.
    function test_PoC4_clammCrossesLiquidityGap() public {
        PoolKey memory key = _key(CurveType.CLAMM);
        _initPool(key);
        _actor(1_000_000 ether).run(key, _one(int256(100_000 ether)), 600, 1200);
        uint256 out = _swap(key, false, 1 ether);
        assertGt(out, 0, "swap fills from liquidity above the gap");
        int24 tick = Slot0Library.tick(manager.getSlot0(key.toId()));
        assertGe(tick, 600);
    }

    /// Gap on both sides: liquidity below and above, empty middle; swaps in both directions fill.
    function test_clammGapCrossingBothDirections() public {
        PoolKey memory key = _key(CurveType.CLAMM);
        _initPool(key);
        _actor(10_000_000 ether).run(key, _one(int256(100_000 ether)), 600, 1200);
        _actor(10_000_000 ether).run(key, _one(int256(100_000 ether)), -1200, -600);
        assertGt(_swap(key, false, 1 ether), 0);
        assertGt(_swap(key, true, 10 ether), 0, "crosses back over the gap into the lower range");
        assertLt(Slot0Library.tick(manager.getSlot0(key.toId())), -600);
    }

    // ------------------------------------------------------------------ SDX-006 BIN gate

    /// PoC-5 (frozen single-bin price) fixed for real by ADR-0006: BIN_AMM pools are enabled on the production
    /// manager AND the price now moves bin to bin under a swap (the old gate was only a mitigation).
    function test_PoC5_binPriceMovesAcrossBins() public {
        assertTrue(manager.binAmmEnabled());
        PoolKey memory key = _key(CurveType.BIN_AMM); // tickSpacing 60 = 0.6% bin step
        _initPool(key);
        _actor(10_000_000 ether).run(key, _one(int256(1000 ether)), -10, 10);
        uint160 p0 = Slot0Library.sqrtPriceX96(manager.getSlot0(key.toId()));
        assertGt(_swap(key, true, 3000 ether), 0);
        int24 active = Slot0Library.tick(manager.getSlot0(key.toId()));
        assertLt(active, -1, "active bin moved down");
        assertLt(Slot0Library.sqrtPriceX96(manager.getSlot0(key.toId())), p0, "price moved");
    }

    // ------------------------------------------------------------------ SDX-001 / 002 StableAMM

    /// PoC-6 inverted: computeY(x, x, y) == y within 1 wei.
    function test_PoC6_computeYSelfConsistent() public {
        StableAMMEngine eng = StableAMMEngine(address(manager.stableEngine()));
        uint256[4] memory xs = [uint256(100 ether), 100 ether, 150 ether, 1000 ether];
        uint256[4] memory ys = [uint256(100 ether), 50 ether, 40 ether, 10 ether];
        for (uint256 i; i < 4; i++) {
            uint256 y2 = eng.computeY(xs[i], xs[i], ys[i], 100);
            assertApproxEqAbs(y2, ys[i], 1);
        }
    }

    function testFuzz_computeYSelfConsistent(uint256 x, uint256 y) public {
        StableAMMEngine eng = StableAMMEngine(address(manager.stableEngine()));
        x = bound(x, 1e6, 1e30);
        y = bound(y, x / 50 + 1, x * 50); // within a 50:1 imbalance
        uint256 y2 = eng.computeY(x, x, y, 100);
        assertApproxEqAbs(y2, y, 2);
    }

    /// PoC-6b inverted: on the PoC's imbalanced pool, tiny swaps through the engine never pay out more than
    /// they take in (raw computeY carries ±2 wei integer error; the engine measures from the solved baseline
    /// and subtracts 1 wei).
    function test_PoC6b_tinySwapNoProfit() public {
        PoolKey memory key = _stablePool(100 ether);
        _swap(key, true, 60 ether); // skew the pool (token1 scarce), like the PoC reserves
        for (uint128 amt = 2; amt < 2000; amt *= 3) {
            uint256 b0 = t0.balanceOf(address(this));
            uint256 b1 = t1.balanceOf(address(this));
            try this.swapExt(key, true, amt) {}
            catch (bytes memory err) {
                _assertDustRevert(err); // only the documented dust errors; state unchanged on revert
            }
            assertLe(t1.balanceOf(address(this)) - b1, b0 - t0.balanceOf(address(this)), "tiny 0->1");
        }
    }

    /// PoC-8 inverted: dust swaps cannot drain the stable pool. Jexi 018: the dust swap must revert with a
    /// documented error (no blanket catch), state must be unchanged, and a positive control must fill.
    function test_PoC8_stableDustSwapsNoDrain() public {
        PoolKey memory key = _stablePool(100 ether);
        uint256 b1 = t1.balanceOf(address(this));
        uint256 b0 = t0.balanceOf(address(this));
        for (uint256 i; i < 10; i++) {
            vm.expectRevert(PoolErrors.InsufficientLiquidity.selector);
            this.swapExt(key, true, 2);
        }
        assertEq(t0.balanceOf(address(this)), b0, "nothing spent");
        assertEq(t1.balanceOf(address(this)), b1, "nothing received");
        // positive control: same path, normal size, fills below 1:1
        uint256 out = this.swapExt(key, true, 1e15);
        assertGt(out, 0.99e15);
        assertLt(out, 1e15);
    }

    function _assertDustRevert(bytes memory err) internal pure {
        bytes4 sel = bytes4(err);
        assertTrue(
            sel == PoolErrors.InsufficientLiquidity.selector || sel == PoolErrors.ZeroSwapAmount.selector,
            "unexpected revert on dust swap"
        );
    }

    function swapExt(PoolKey memory key, bool zeroForOne, uint128 amountIn) external returns (uint256) {
        return _swap(key, zeroForOne, amountIn);
    }

    /// Stable round trip (A→B→A) never returns more than was put in.
    function testFuzz_stableRoundTripNotProfitable(uint128 amountIn, uint128 skew) public {
        PoolKey memory key = _stablePool(1_000_000 ether);
        skew = uint128(bound(skew, 0, 900_000 ether));
        if (skew > 0) {
            try this.swapExt(key, true, skew) {} catch {}
        }
        // Values here are near 1:1, so token0 units are a fair proxy for value on the round trip.
        amountIn = uint128(bound(amountIn, 1, 500_000 ether));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 out1;
        try this.swapExt(key, true, amountIn) returns (uint256 o) {
            out1 = o;
        } catch {
            return; // dust amounts revert (fee >= amountIn or zero output)
        }
        if (out1 == 0) return;
        try this.swapExt(key, false, uint128(out1)) {} catch {}
        assertLe(t0.balanceOf(address(this)), b0, "round trip must not profit");
    }

    /// PoC-2 inverted: an atomic deposit+withdraw after reserves drift extracts nothing from existing LPs.
    function test_PoC2_stableSharesFair() public {
        PoolKey memory key = _stablePool(100 ether);
        _swap(key, true, 60 ether);
        Actor attacker = _actor(1_000_000 ether);
        uint256 b0 = t0.balanceOf(address(attacker));
        uint256 b1 = t1.balanceOf(address(attacker));
        int256[] memory ops = new int256[](2);
        ops[0] = int256(100 ether);
        ops[1] = -int256(100 ether);
        attacker.run(key, ops, 0, 0);
        assertLe(t0.balanceOf(address(attacker)), b0);
        assertLe(t1.balanceOf(address(attacker)), b1);
    }

    function testFuzz_stableLpFairness(uint128 seedShares, uint128 swapIn, bool dir, uint128 shares) public {
        seedShares = uint128(bound(seedShares, 10_000, 1_000_000 ether));
        PoolKey memory key = _stablePool(seedShares);
        swapIn = uint128(bound(swapIn, 0, seedShares / 2));
        if (swapIn > 0) {
            try this.swapExt(key, dir, swapIn) {} catch {}
        }
        shares = uint128(bound(shares, 1, 1_000_000 ether));
        Actor attacker = _actor(type(uint128).max);
        uint256 b0 = t0.balanceOf(address(attacker));
        uint256 b1 = t1.balanceOf(address(attacker));
        int256[] memory ops = new int256[](2);
        ops[0] = int256(uint256(shares));
        ops[1] = -int256(uint256(shares));
        attacker.run(key, ops, 0, 0);
        assertLe(t0.balanceOf(address(attacker)), b0, "token0 gained");
        assertLe(t1.balanceOf(address(attacker)), b1, "token1 gained");
    }

    function test_stableFirstDepositLocksMinimumLiquidity() public {
        PoolKey memory key = _key(CurveType.STABLE_AMM);
        _initPool(key);
        Actor a = _actor(1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(PoolErrors.InsufficientInitialLiquidity.selector, uint256(1000), uint256(1000))
        );
        a.run(key, _one(int256(1000)), 0, 0);
        a.run(key, _one(int256(1001)), 0, 0);
        assertEq(manager.getLiquidity(key.toId()), 1001);
    }

    // ------------------------------------------------------------------ SDX-005 oracle / LVR

    /// PoC-7 inverted: a constant tick yields zero volatility regardless of idle time.
    function test_PoC7_constantTickZeroVolatility() public {
        VolatilityTWAPOracle o = new VolatilityTWAPOracle(address(this));
        PoolId id = PoolId.wrap(bytes32(uint256(1)));
        // Literal timestamps: under via-IR `block.timestamp` is cached within a test frame after vm.warp.
        vm.warp(1_000_000);
        o.initialize(id, 1_000_000, 20_000);
        o.grow(id, 64);
        vm.warp(1_000_001);
        o.write(id, 1_000_001, 20_000, 1e18);
        uint32[3] memory idles = [uint32(12), 36, 600];
        for (uint256 i; i < 3; i++) {
            vm.warp(1_000_001 + idles[i]);
            assertEq(o.getInstantaneousVolatility(id, 12), 0, "constant tick => 0");
        }
    }

    function test_oracleVolatilityTracksTickMove() public {
        VolatilityTWAPOracle o = new VolatilityTWAPOracle(address(this));
        PoolId id = PoolId.wrap(bytes32(uint256(2)));
        vm.warp(1_000_000);
        o.initialize(id, 1_000_000, 0);
        o.grow(id, 64);
        vm.warp(1_000_100);
        o.write(id, 1_000_100, 300, 1e18); // tick jumps 0 -> 300
        vm.warp(1_000_105);
        assertEq(o.getInstantaneousVolatility(id, 12), 300, "|dtick| = 300 within the 12s window");
        vm.warp(1_000_200);
        assertEq(o.getInstantaneousVolatility(id, 12), 0, "no move inside the trailing window");
    }

    function test_oracleExtrapolatesPastNewestObservation() public {
        VolatilityTWAPOracle o = new VolatilityTWAPOracle(address(this));
        PoolId id = PoolId.wrap(bytes32(uint256(3)));
        vm.warp(1_000_000);
        o.initialize(id, 1_000_000, 100);
        o.grow(id, 8);
        vm.warp(1_000_010);
        o.write(id, 1_000_010, 100, 1e18);
        vm.warp(1_000_050);
        uint32[] memory ago = new uint32[](2);
        ago[0] = 0;
        ago[1] = 40;
        (int56[] memory cums,) = o.observe(id, ago);
        assertEq(cums[0] - cums[1], int56(100) * 40, "TWAP over idle window equals the prevailing tick");
    }
}
