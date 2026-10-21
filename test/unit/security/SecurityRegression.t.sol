// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../../contract/core/engines/StableAMMEngine.sol";
import {IPoolManager} from "../../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../../contract/types/PoolId.sol";
import {Currency} from "../../../contract/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../../../contract/types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../../contract/types/Slot0.sol";
import {BaseHook} from "../../../contract/plugins/external/BaseHook.sol";
import {PluginDispatcher} from "../../../contract/core/PluginDispatcher.sol";
import {SupaClaimsRouter} from "../../../contract/periphery/SupaClaimsRouter.sol";
import {IVault} from "../../../contract/interfaces/IVault.sol";
import {VolatilityTWAPOracle} from "../../../contract/plugins/native/VolatilityTWAPOracle.sol";
import {LVRShieldPlugin} from "../../../contract/plugins/native/LVRShieldPlugin.sol";
import {AntiJITVestingPlugin} from "../../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {PoolErrors} from "../../../contract/errors/PoolErrors.sol";
import {PluginErrors} from "../../../contract/errors/PluginErrors.sol";
import {TickMathLib} from "../../../contract/libraries/TickMathLib.sol";
import {SecurityTestSetup} from "../../helpers/SecurityTestSetup.sol";
import {PluginWhitelist} from "../../../contract/governance/PluginWhitelist.sol";
import {IPluginWhitelist} from "../../../contract/interfaces/IPluginWhitelist.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Tok {
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

contract Actor is IUnlockCallback {
    SupaVault vault;
    SupaPoolManager manager;

    enum Op {
        MODIFY,
        SWAP,
        DONATE
    }

    constructor(SupaVault v, SupaPoolManager m) {
        vault = v;
        manager = m;
    }

    function modify(PoolKey memory key, int24 lo, int24 hi, int256 liq, bytes32 salt) external {
        vault.unlock(abi.encode(Op.MODIFY, key, lo, hi, liq, salt, false, int256(0)));
    }

    function swap(PoolKey memory key, bool z, int256 amt) external {
        vault.unlock(abi.encode(Op.SWAP, key, int24(0), int24(0), int256(0), bytes32(0), z, amt));
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        vault.unlock(
            abi.encode(Op.DONATE, key, int24(0), int24(0), int256(amount0), bytes32(uint256(amount1)), false, int256(0))
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Op op, PoolKey memory key, int24 lo, int24 hi, int256 liq, bytes32 salt, bool z, int256 amt) =
            abi.decode(data, (Op, PoolKey, int24, int24, int256, bytes32, bool, int256));
        if (op == Op.MODIFY) {
            manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: salt}),
                ""
            );
        } else if (op == Op.SWAP) {
            uint160 limit = z ? TickMathLib.MIN_SQRT_RATIO + 1 : TickMathLib.MAX_SQRT_RATIO - 1;
            manager.swap(
                key, IPoolManager.SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: limit}), ""
            );
        } else {
            manager.donate(key, uint256(liq), uint256(uint256(salt)), "");
        }
        _resolve(key.currency0);
        _resolve(key.currency1);
        return "";
    }

    function _resolve(Currency c) internal {
        int256 d = vault.getCurrencyDelta(address(this), c);
        if (d < 0) {
            vault.sync(c);
            Tok(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}

contract EvilHook is BaseHook {
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

/// @dev Minimal no-op hook used to exercise live whitelist re-checks after delisting.
contract BenignHook is BaseHook {
    constructor(IPoolManager pm) BaseHook(pm) {}

    function getPluginPermissions() public pure override returns (uint32) {
        return
            PluginDispatcher.AFTER_SWAP_FLAG | PluginDispatcher.BEFORE_DONATE_FLAG | PluginDispatcher.AFTER_DONATE_FLAG;
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return this.afterDonate.selector;
    }
}

/// @dev beforeSwap returns a 100% fee to exercise the PoolManager fee ceiling.
contract MaxFeeHook is BaseHook {
    constructor(IPoolManager pm) BaseHook(pm) {}

    function getPluginPermissions() public pure override returns (uint32) {
        return PluginDispatcher.BEFORE_SWAP_FLAG;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, uint24)
    {
        return (this.beforeSwap.selector, 1_000_000);
    }
}

/// @dev Captures getSlot0 tick during afterSwap to prove manager syncs before hooks.
contract SyncProbeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    int24 public observedTick;
    uint128 public observedLiquidity;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function getPluginPermissions() public pure override returns (uint32) {
        return PluginDispatcher.AFTER_SWAP_FLAG;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        observedTick = poolManager.getSlot0(id).tick();
        observedLiquidity = poolManager.getLiquidity(id);
        return (this.afterSwap.selector, 0);
    }
}

/// @dev Returns a non-zero feesHookDelta on removes to exercise canReturnDelta / cap checks.
contract EvilFeeHook is BaseHook {
    int128 public feeSteal;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function setFeeSteal(int128 s) external {
        feeSteal = s;
    }

    function getPluginPermissions() public pure override returns (uint32) {
        return PluginDispatcher.AFTER_MODIFY_LIQUIDITY_FLAG;
    }

    function afterModifyLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta, BalanceDelta) {
        BalanceDelta feesHook = params.liquidityDelta < 0 ? toBalanceDelta(feeSteal, 0) : BalanceDelta.wrap(0);
        return (this.afterModifyLiquidity.selector, BalanceDelta.wrap(0), feesHook);
    }
}

/// @notice Flipped audit PoCs: attacks must fail after the security hardening patches.
contract SecurityRegressionTest is Test {
    using Slot0Library for Slot0;
    using PoolIdLibrary for PoolKey;

    SupaVault vault;
    SupaPoolManager manager;
    CLAMMEngine clamm;
    BinAMMEngine bin;
    StableAMMEngine stable;
    Tok t0;
    Tok t1;
    PoolKey key;
    Actor victim;
    Actor attacker;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        clamm = CLAMMEngine(address(manager.clammEngine()));
        bin = BinAMMEngine(address(manager.binEngine()));
        stable = StableAMMEngine(address(manager.stableEngine()));
        vault.setPoolManager(address(manager), true);
        SecurityTestSetup.installEmptyWhitelist(manager, address(this));

        Tok a = new Tok();
        Tok b = new Tok();
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        victim = new Actor(vault, manager);
        attacker = new Actor(vault, manager);
        t0.mint(address(victim), 1_000_000 ether);
        t1.mint(address(victim), 1_000_000 ether);
        t0.mint(address(attacker), 1_000_000 ether);
        t1.mint(address(attacker), 1_000_000 ether);
        manager.initialize(key, 1 << 96, "");
    }

    /// F1: ownerless position theft blocked
    function test_F1_ownerBoundPositions() public {
        victim.modify(key, -120, 120, 1_000_000, bytes32(uint256(1)));
        uint256 before0 = t0.balanceOf(address(attacker));

        vm.expectRevert();
        attacker.modify(key, -120, 120, -1_000_000, bytes32(uint256(1)));

        assertEq(t0.balanceOf(address(attacker)), before0);
        // Victim can still exit their own position
        victim.modify(key, -120, 120, -1_000_000, bytes32(uint256(1)));
    }

    /// F2: direct engine calls rejected
    function test_F2_engineOnlyPoolManager() public {
        vm.expectRevert(PoolErrors.NotPoolManager.selector);
        clamm.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            address(attacker)
        );

        vm.expectRevert(PoolErrors.NotPoolManager.selector);
        clamm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: TickMathLib.MIN_SQRT_RATIO + 1
            }),
            3000,
            0
        );

        PoolKey memory other = key;
        other.fee = 500;
        // Direct initialize grief blocked
        vm.expectRevert(PoolErrors.NotPoolManager.selector);
        clamm.initialize(other, 1 << 96);
    }

    /// F3: protocol fee survives modifyLiquidity
    function test_F3_protocolFeePreserved() public {
        manager.setProtocolFee(key, 100_000);
        assertEq(uint256(manager.getSlot0(key.toId()).protocolFee()), 100_000);
        victim.modify(key, -120, 120, 1_000_000, bytes32(0));
        assertEq(uint256(manager.getSlot0(key.toId()).protocolFee()), 100_000);
    }

    /// F4: uncapped malicious hook delta blocked
    function test_F4_hookDeltaCappedAndPermissioned() public {
        EvilHook evil = new EvilHook(manager);
        evil.setSteal(-int128(5e18));

        address[] memory plugins = new address[](1);
        plugins[0] = address(evil);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        // Intentionally do NOT grant canReturnDelta
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory evilKey = key;
        evilKey.plugin = address(evil);
        evilKey.fee = 500;
        manager.initialize(evilKey, 1 << 96, "");

        // Seed unrelated liquidity in original pool so vault has tokens
        victim.modify(key, -120, 120, 10_000_000, bytes32(0));

        uint256 before = t0.balanceOf(address(attacker));
        vm.expectRevert();
        attacker.swap(evilKey, true, 1);
        assertEq(t0.balanceOf(address(attacker)), before);
    }

    /// F5: ETH refund goes to the outer msg.sender (not a self-call trap)
    function test_F5_ethRefundToUser() public {
        SupaClaimsRouter claims = new SupaClaimsRouter(IVault(address(vault)));
        address user = address(0xBEEF);
        vm.deal(address(claims), 1 ether);
        uint256 before = user.balance;
        vm.prank(user);
        claims.refundETH();
        assertEq(user.balance, before + 1 ether);
        assertEq(address(claims).balance, 0);
    }

    /// F6: atomic proxy init prevents frontrun ownership
    function test_F6_atomicVaultInit() public {
        SupaVault impl = new SupaVault(address(this));
        address owner_ = address(0xA11CE);
        bytes memory initData = abi.encodeCall(SupaVault.initialize, (owner_));
        SupaVault proxy = SupaVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        assertEq(proxy.owner(), owner_);
        vm.expectRevert();
        proxy.initialize(address(attacker));
    }

    /// F7: oracle unauthenticated writes blocked
    function test_F7_oracleWriterGated() public {
        VolatilityTWAPOracle o = new VolatilityTWAPOracle(address(this));
        PoolId id = key.toId();
        o.initialize(id, uint32(block.timestamp), 0);

        vm.prank(address(attacker));
        vm.expectRevert(PluginErrors.NotOracleWriter.selector);
        o.write(id, uint32(block.timestamp + 1), 100, 1e18);
    }

    /// F8: fresh position withdraw after swap does not underflow
    function test_F8_feeGrowthInsideNoUnderflow() public {
        victim.modify(key, -60, 60, 5_000_000, bytes32(0));
        attacker.swap(key, true, 10_000);
        // Fresh ticks after fee growth
        victim.modify(key, -120, 120, 1_000_000, bytes32(uint256(2)));
        victim.modify(key, -120, 120, -1_000_000, bytes32(uint256(2)));
    }

    /// F9: last Bin LP can exit after skew
    function test_F9_binProRataExit() public {
        PoolKey memory binKey = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 10,
            plugin: address(0),
            curveType: CurveType.BIN_AMM
        });
        // ADR-0006: BIN_AMM is enabled on the production manager (multi-bin). F9 restored to its original intent:
        // the last LP exits fully after the pool was skewed across several bins.
        manager.initialize(binKey, 1 << 96, "");
        victim.modify(binKey, -5, 5, 10 ether, bytes32(0));
        uint256 v0 = t0.balanceOf(address(victim));
        uint256 v1 = t1.balanceOf(address(victim));
        attacker.swap(binKey, true, 40 ether); // drains token1 from several bins
        assertLt(BinAMMEngine(address(manager.binEngine())).getActiveBinId(binKey.toId()), 0, "price moved down");
        victim.modify(binKey, -5, 5, -10 ether, bytes32(0));
        assertGt(t0.balanceOf(address(victim)), v0, "LP receives the token0 the attacker paid in");
        assertGt(t1.balanceOf(address(victim)), v1, "and the remaining token1");
        (uint128 r0, uint128 r1) = BinAMMEngine(address(manager.binEngine())).getBinReserves(binKey.toId(), 0);
        assertEq(r0, 0);
        assertEq(r1, 0);
    }

    /// M1: delisting a plugin disables modify/swap on already-initialized pools
    function test_M1_delistedPluginBlocksLiveOps() public {
        BenignHook hook = new BenignHook(manager);
        address[] memory plugins = new address[](1);
        plugins[0] = address(hook);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory hooked = key;
        hooked.plugin = address(hook);
        hooked.fee = 500;
        manager.initialize(hooked, 1 << 96, "");
        victim.modify(hooked, -120, 120, 5_000_000, bytes32(0));

        wl.setPluginWhitelisted(address(hook), false);

        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PluginNotWhitelisted.selector, address(hook)));
        victim.modify(hooked, -120, 120, 1_000_000, bytes32(uint256(1)));

        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PluginNotWhitelisted.selector, address(hook)));
        attacker.swap(hooked, true, 1_000);
    }

    /// M2: engines + LVR oracle writer are immutably bound at construction
    function test_M2_constructorBoundWriters() public {
        assertEq(clamm.poolManager(), address(manager));
        assertEq(bin.poolManager(), address(manager));
        assertEq(stable.poolManager(), address(manager));

        LVRShieldPlugin lvr = new LVRShieldPlugin(manager);
        VolatilityTWAPOracle o = VolatilityTWAPOracle(address(lvr.oracle()));
        assertEq(o.writer(), address(lvr));

        vm.prank(address(attacker));
        vm.expectRevert(PluginErrors.NotOracleWriter.selector);
        o.write(key.toId(), uint32(block.timestamp + 1), 0, 1e18);
    }

    /// M3: same-sign / debit-amplifying hook deltas revert even when canReturnDelta is granted
    function test_M3_sameSignHookDeltaRejected() public {
        EvilHook evil = new EvilHook(manager);
        // Same sign as a zeroForOne exact-input swap's amount0 (positive debt to vault).
        evil.setSteal(int128(1e6));

        address[] memory plugins = new address[](1);
        plugins[0] = address(evil);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(evil), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory evilKey = key;
        evilKey.plugin = address(evil);
        evilKey.fee = 500;
        manager.initialize(evilKey, 1 << 96, "");
        victim.modify(evilKey, -120, 120, 10_000_000, bytes32(0));

        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        attacker.swap(evilKey, true, 1_000_000);
    }

    /// H1: opposite-sign hook on positive (debit) reference underpays while engine advances — blocked
    function test_H1_hookCannotReduceUserDebit() public {
        EvilHook evil = new EvilHook(manager);
        // Negative hook on positive amount0 → would reduce what the swapper must pay.
        evil.setSteal(-int128(1e5));

        address[] memory plugins = new address[](1);
        plugins[0] = address(evil);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(evil), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory evilKey = key;
        evilKey.plugin = address(evil);
        evilKey.fee = 500;
        manager.initialize(evilKey, 1 << 96, "");
        victim.modify(evilKey, -120, 120, 10_000_000, bytes32(0));

        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        attacker.swap(evilKey, true, 1_000_000);
    }

    /// M: delisting blocks donate hooks on initialized pools
    function test_M_delistedPluginBlocksDonate() public {
        BenignHook hook = new BenignHook(manager);
        address[] memory plugins = new address[](1);
        plugins[0] = address(hook);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory hooked = key;
        hooked.plugin = address(hook);
        hooked.fee = 500;
        manager.initialize(hooked, 1 << 96, "");
        wl.setPluginWhitelisted(address(hook), false);

        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PluginNotWhitelisted.selector, address(hook)));
        victim.donate(hooked, 1, 1);
    }

    /// M: plugin override fee of 100% is rejected before engines DoS
    function test_M_maxFeePipsRejected() public {
        MaxFeeHook hook = new MaxFeeHook(manager);
        address[] memory plugins = new address[](1);
        plugins[0] = address(hook);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory hooked = key;
        hooked.plugin = address(hook);
        hooked.fee = 500;
        manager.initialize(hooked, 1 << 96, "");
        victim.modify(hooked, -120, 120, 5_000_000, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(PoolErrors.InvalidFee.selector, uint24(1_000_000)));
        attacker.swap(hooked, true, 1_000);
    }

    /// LVR prod: afterSwap sees post-swap tick/liquidity (manager syncs before hooks)
    function test_LVR_afterSwapSeesSyncedSlot0() public {
        SyncProbeHook hook = new SyncProbeHook(manager);
        address[] memory plugins = new address[](1);
        plugins[0] = address(hook);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory hooked = key;
        hooked.plugin = address(hook);
        hooked.fee = 500;
        manager.initialize(hooked, 1 << 96, "");
        victim.modify(hooked, -120, 120, 10_000_000, bytes32(0));

        attacker.swap(hooked, true, 1_000_000);

        PoolId id = hooked.toId();
        int24 engineTick = clamm.getSlot0(id).tick();
        uint128 engineLiq = clamm.getLiquidity(id);
        assertEq(hook.observedTick(), engineTick, "afterSwap must observe post-swap tick");
        assertEq(hook.observedLiquidity(), engineLiq, "afterSwap must observe post-swap liquidity");
        assertEq(manager.getSlot0(id).tick(), engineTick);
    }

    /// Anti-JIT: feesHookDelta requires canReturnDelta
    function test_AntiJIT_feesHookRequiresCanReturnDelta() public {
        EvilFeeHook evil = new EvilFeeHook(manager);
        evil.setFeeSteal(1);

        address[] memory plugins = new address[](1);
        plugins[0] = address(evil);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        // Intentionally do NOT grant canReturnDelta
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory evilKey = key;
        evilKey.plugin = address(evil);
        evilKey.fee = 500;
        manager.initialize(evilKey, 1 << 96, "");

        // First add succeeds (no feesHook). Accrue fees then remove → feesHook non-zero → revert.
        victim.modify(evilKey, -120, 120, 5_000_000, bytes32(0));
        attacker.swap(evilKey, true, 100_000);
        vm.expectRevert();
        victim.modify(evilKey, -120, 120, -5_000_000, bytes32(0));
    }

    /// Anti-JIT: feesHookDelta cannot exceed feesAccrued
    function test_AntiJIT_feesHookCappedByAccrued() public {
        EvilFeeHook evil = new EvilFeeHook(manager);
        evil.setFeeSteal(type(int128).max); // absurd overshoot

        address[] memory plugins = new address[](1);
        plugins[0] = address(evil);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(evil), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory evilKey = key;
        evilKey.plugin = address(evil);
        evilKey.fee = 500;
        manager.initialize(evilKey, 1 << 96, "");
        victim.modify(evilKey, -120, 120, 5_000_000, bytes32(0));
        attacker.swap(evilKey, true, 100_000);

        vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
        victim.modify(evilKey, -120, 120, -1_000_000, bytes32(0));
    }

    /// Anti-JIT: same-block exit haircuts fees not principal; solo exit → protocolFeesAccrued fallback
    function test_AntiJIT_feeVestNotPrincipal_protocolFallback() public {
        AntiJITVestingPlugin jit = new AntiJITVestingPlugin(manager, 3);
        address[] memory plugins = new address[](1);
        plugins[0] = address(jit);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(jit), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        PoolKey memory jitKey = key;
        jitKey.plugin = address(jit);
        jitKey.fee = 500;
        manager.initialize(jitKey, 1 << 96, "");

        victim.modify(jitKey, -120, 120, 5_000_000, bytes32(0));
        attacker.swap(jitKey, true, 200_000);

        uint256 proto0Before = manager.protocolFeesAccrued(key.currency0);
        uint256 proto1Before = manager.protocolFeesAccrued(key.currency1);

        // Full exit → active liquidity 0 → confiscated fees fall back to protocol accrual
        victim.modify(jitKey, -120, 120, -5_000_000, bytes32(0));

        uint256 proto0After = manager.protocolFeesAccrued(key.currency0);
        uint256 proto1After = manager.protocolFeesAccrued(key.currency1);
        assertTrue(
            proto0After > proto0Before || proto1After > proto1Before,
            "solo JIT exit must route unvested fees to protocolFeesAccrued"
        );
    }
}
