// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Regression ports of Jexi's independent review tests (security-findings/supadex/tests/JexiSupaDex.t.sol,
// APUS-SUPADEX-001..014). Harness and wiring are Jexi's (production-like: ERC1967 vault proxy, timelock owner,
// circuit breaker, whitelist with the real LVR + AntiJIT plugins). Assertions are inverted to the FIXED behaviour.
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SupaVault} from "../../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../../contract/core/engines/StableAMMEngine.sol";
import {ICurveEngine} from "../../../contract/interfaces/ICurveEngine.sol";
import {IVault} from "../../../contract/interfaces/IVault.sol";
import {IPoolManager} from "../../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../../contract/interfaces/IUnlockCallback.sol";
import {IPluginWhitelist} from "../../../contract/interfaces/IPluginWhitelist.sol";
import {ISupaRoles} from "../../../contract/interfaces/ISupaRoles.sol";
import {ICircuitBreaker} from "../../../contract/interfaces/ICircuitBreaker.sol";
import {ISupaRouter} from "../../../contract/interfaces/ISupaRouter.sol";
import {SupaRouter} from "../../../contract/periphery/SupaRouter.sol";
import {SupaClaimsRouter} from "../../../contract/periphery/SupaClaimsRouter.sol";
import {PluginWhitelist} from "../../../contract/governance/PluginWhitelist.sol";
import {SupaRoles} from "../../../contract/governance/SupaRoles.sol";
import {SupaTimelock} from "../../../contract/governance/SupaTimelock.sol";
import {CircuitBreaker} from "../../../contract/security/CircuitBreaker.sol";
import {LVRShieldPlugin} from "../../../contract/plugins/native/LVRShieldPlugin.sol";
import {AntiJITVestingPlugin} from "../../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {PoolKey, CurveType} from "../../../contract/types/PoolKey.sol";
import {PoolId} from "../../../contract/types/PoolId.sol";
import {Currency} from "../../../contract/types/Currency.sol";
import {BalanceDelta} from "../../../contract/types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../../contract/types/Slot0.sol";
import {TickMathLib} from "../../../contract/libraries/TickMathLib.sol";
import {VaultErrors} from "../../../contract/errors/VaultErrors.sol";
import {PoolErrors} from "../../../contract/errors/PoolErrors.sol";
import {PluginErrors} from "../../../contract/errors/PluginErrors.sol";
import {GovernanceErrors} from "../../../contract/errors/GovernanceErrors.sol";

contract JToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
        symbol = n;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function rebaseDown(address who, uint256 a) external {
        balanceOf[who] -= a;
        totalSupply -= a;
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

/// Executes an arbitrary list of PoolManager ops inside ONE unlock, then nets out deltas
/// (pays debts from its own balance, takes credits). With zero balance it can only end
/// non-reverting if every delta is >= 0 (i.e. a zero-capital flash attack).
contract JFlashActor is IUnlockCallback {
    struct Op {
        uint8 kind; // 0 = modifyLiquidity, 1 = swap
        PoolKey key;
        int24 lo;
        int24 hi;
        int256 amt; // liquidityDelta or amountSpecified
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
            JToken(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}

/// Inside one unlock: settle WITHOUT a prior sync (the old surplus-sweep trick) — must now revert.
contract JSweeper is IUnlockCallback {
    SupaVault public immutable vault;

    constructor(SupaVault v) {
        vault = v;
    }

    function sweep(Currency c) external {
        vault.unlock(abi.encode(c));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        Currency c = abi.decode(data, (Currency));
        uint256 paid = vault.settle(c);
        vault.take(c, address(this), paid);
        return "";
    }
}

/// Tries to execute a queued timelock `accountDelta` op from inside an unlock (owner-drain path).
contract JTimelockDrainHelper is IUnlockCallback {
    SupaVault public immutable vault;
    SupaTimelock public immutable tl;
    bytes public opData;

    constructor(SupaVault v, SupaTimelock t) {
        vault = v;
        tl = t;
    }

    function run(bytes calldata data) external {
        opData = data;
        vault.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        tl.execute(address(vault), 0, opData, bytes32(0), bytes32("B"));
        return "";
    }
}

contract JexiRegressionTest is Test {
    SupaVault vault;
    SupaPoolManager pm;
    StableAMMEngine stable;
    BinAMMEngine bin;
    CLAMMEngine clamm;
    SupaRouter router;
    SupaClaimsRouter claims;
    SupaTimelock timelock;
    CircuitBreaker cb;
    SupaRoles roles;
    PluginWhitelist wl;
    LVRShieldPlugin lvr;
    AntiJITVestingPlugin jit;
    JToken t0;
    JToken t1;
    Currency c0;
    Currency c1;

    address constant GOV = address(0x6007);
    address constant GUARD = address(0x6A2D);
    address constant OPERATOR = address(0x0FE2);
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    function setUp() public {
        address[] memory g = new address[](1);
        g[0] = GOV;
        timelock = new SupaTimelock(1 days, GOV, g, g, g);
        address[] memory gs = new address[](1);
        gs[0] = GUARD;
        cb = new CircuitBreaker(address(timelock), gs);

        SupaVault impl = new SupaVault(address(this));
        vault = SupaVault(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(SupaVault.initialize, (address(this))))))
        );
        vault.setCircuitBreaker(ICircuitBreaker(address(cb)));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        clamm = new CLAMMEngine(predicted);
        bin = new BinAMMEngine(predicted);
        stable = new StableAMMEngine(predicted);
        pm = new SupaPoolManager(
            IVault(address(vault)),
            ICurveEngine(address(clamm)),
            ICurveEngine(address(bin)),
            ICurveEngine(address(stable))
        );
        require(address(pm) == predicted, "pm addr");
        pm.setCircuitBreaker(ICircuitBreaker(address(cb)));

        roles = new SupaRoles(address(this), OPERATOR);
        lvr = new LVRShieldPlugin(pm);
        lvr.setRoles(ISupaRoles(address(roles)));
        jit = new AntiJITVestingPlugin(pm, 10);
        address[] memory plugins = new address[](2);
        plugins[0] = address(lvr);
        plugins[1] = address(jit);
        wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(jit), true);
        pm.setPluginWhitelist(IPluginWhitelist(address(wl)));

        router = new SupaRouter(pm, IVault(address(vault)));
        claims = new SupaClaimsRouter(IVault(address(vault)));

        vault.setPoolManager(address(pm), true);
        vault.transferOwnership(address(timelock));
        pm.transferOwnership(address(timelock));
        roles.transferOwnership(address(timelock));
        wl.transferOwnership(address(timelock));

        JToken a = new JToken("A");
        JToken b = new JToken("B");
        if (address(a) > address(b)) (a, b) = (b, a);
        t0 = a;
        t1 = b;
        c0 = Currency.wrap(address(a));
        c1 = Currency.wrap(address(b));
        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        t0.approve(address(claims), type(uint256).max);
        t1.approve(address(claims), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers
    function _key(CurveType ct, uint24 fee, int24 spacing, address plugin) internal view returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, plugin: plugin, curveType: ct});
    }

    function _actor(uint256 fund) internal returns (JFlashActor a) {
        a = new JFlashActor(vault, pm);
        if (fund > 0) {
            t0.mint(address(a), fund);
            t1.mint(address(a), fund);
        }
    }

    function _op(uint8 kind, PoolKey memory k, int24 lo, int24 hi, int256 amt, bool z)
        internal
        pure
        returns (JFlashActor.Op memory)
    {
        return JFlashActor.Op({kind: kind, key: k, lo: lo, hi: hi, amt: amt, zeroForOne: z});
    }

    function _one(JFlashActor.Op memory o) internal pure returns (JFlashActor.Op[] memory ops) {
        ops = new JFlashActor.Op[](1);
        ops[0] = o;
    }

    function _swap(PoolKey memory k, bool z, uint128 amountIn) internal returns (uint256) {
        return router.exactInputSingle(
            ISupaRouter.ExactInputSingleParams({
                poolKey: k,
                zeroForOne: z,
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

    // ================================================================== 001 (C1)
    function test_001_computeDCorrectAtBalance_andComputeYConsistent() public view {
        uint256 x = 100e18;
        assertApproxEqAbs(stable.computeD(x, x, 100), 2 * x, 1, "D == x+y at balance");
        assertApproxEqAbs(stable.computeY(x, x, x, 100), x, 1, "computeY(x,x,y) == y");
    }

    function test_001_dustSwapsCannotDrainStablePool() public {
        PoolKey memory k = _key(CurveType.STABLE_AMM, 500, 1, address(0));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e24).exec(_one(_op(0, k, 0, 0, int256(1000e18), false)));
        JFlashActor attacker = new JFlashActor(vault, pm);
        t0.mint(address(attacker), 1e18);
        uint256 n = 60;
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](n);
        for (uint256 i; i < n; i++) {
            ops[i] = _op(1, k, 0, 0, int256(2), true);
        }
        try attacker.exec(ops) {} catch {}
        uint256 spent0 = 1e18 - t0.balanceOf(address(attacker));
        assertLe(t1.balanceOf(address(attacker)), spent0, "no free output from dust swaps");
    }

    // ================================================================== 002 (C2)
    function test_002_zeroCapitalAddRemoveExtractsNothing() public {
        PoolKey memory k = _key(CurveType.STABLE_AMM, 500, 1, address(0));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e24).exec(_one(_op(0, k, 0, 0, int256(1000e18), false)));
        _swap(k, true, 100e18);
        JFlashActor attacker = new JFlashActor(vault, pm); // zero balance
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](2);
        ops[0] = _op(0, k, 0, 0, int256(1_000_000e18), false);
        ops[1] = _op(0, k, 0, 0, -int256(1_000_000e18), false);
        // Either the round trip nets a rounding debt the attacker cannot pay (revert) or it nets exactly zero.
        try attacker.exec(ops) {} catch {}
        assertEq(t0.balanceOf(address(attacker)), 0, "no token0 extracted");
        assertEq(t1.balanceOf(address(attacker)), 0, "no token1 extracted");
    }

    /// Jexi's property (failed on 68791f6): an atomic add->remove round trip is never profitable.
    function test_fuzz_prop_stableAddRemoveNotProfitable(uint96 tradeIn, uint96 dep) public {
        tradeIn = uint96(bound(tradeIn, 1e15, 400e18));
        dep = uint96(bound(dep, 1e15, 1e24));
        PoolKey memory k = _key(CurveType.STABLE_AMM, 500, 1, address(0));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e26).exec(_one(_op(0, k, 0, 0, int256(1000e18), false)));
        _swap(k, true, tradeIn);
        JFlashActor attacker = _actor(1e26);
        uint256 b0 = t0.balanceOf(address(attacker));
        uint256 b1 = t1.balanceOf(address(attacker));
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](2);
        ops[0] = _op(0, k, 0, 0, int256(uint256(dep)), false);
        ops[1] = _op(0, k, 0, 0, -int256(uint256(dep)), false);
        attacker.exec(ops);
        assertLe(t0.balanceOf(address(attacker)), b0, "token0 round trip profitable");
        assertLe(t1.balanceOf(address(attacker)), b1, "token1 round trip profitable");
    }

    // ================================================================== 006 (H1)
    function _clammPool(address plugin, int24 lo, int24 hi, uint160 sqrtP, int256 liq)
        internal
        returns (PoolKey memory k)
    {
        k = _key(CurveType.CLAMM, 3000, 60, plugin);
        pm.initialize(k, sqrtP, "");
        _actor(1e27).exec(_one(_op(0, k, lo, hi, liq, false)));
    }

    function test_006_oneWeiDonationDoesNotBrickRouterOrClaims() public {
        PoolKey memory k = _clammPool(address(0), -1200, 1200, SQRT_1_1, 1e24);
        assertGt(_swap(k, true, 1e18), 0);
        t0.transfer(address(vault), 1);
        assertGt(_swap(k, true, 1e18), 0);
        claims.deposit(c0, address(this), 1e18);
        assertEq(vault.balanceOf(address(this), c0.toId()), 1e18);
        // third parties can no longer claim the surplus via an unsynced settle
        JSweeper s = new JSweeper(vault);
        vm.expectRevert(abi.encodeWithSelector(VaultErrors.CurrencyNotSynced.selector, c0));
        s.sweep(c0);
    }

    function test_006_negativeRebaseDoesNotBrickSettle() public {
        PoolKey memory k = _clammPool(address(0), -1200, 1200, SQRT_1_1, 1e24);
        t0.rebaseDown(address(vault), 1);
        assertGt(_swap(k, true, 1e18), 0);
    }

    // ================================================================== 003 (H2)
    function _fee(PoolKey memory k) internal view returns (uint24 lastFee) {
        (, lastFee,,,,,,,) = lvr.poolLVRStates(k.toId());
    }

    function test_003_lvrNoSurchargeWithZeroVolatility() public {
        uint160 sp =
            uint160((uint256(TickMathLib.getSqrtRatioAtTick(20_000)) + TickMathLib.getSqrtRatioAtTick(20_001)) / 2);
        PoolKey memory k = _clammPool(address(lvr), 19_800, 20_220, sp, 1e26);
        int24 tickBefore = Slot0Library.tick(pm.getSlot0(k.toId()));
        uint32[5] memory idles = [uint32(12), 12, 13, 24, 600];
        uint256 ts = block.timestamp;
        for (uint256 i; i < idles.length; i++) {
            ts += idles[i];
            vm.warp(ts);
            vm.roll(block.number + 1);
            _swap(k, i % 2 == 0, 1e9);
            assertEq(_fee(k), 3000, "base fee only while the tick is constant");
        }
        assertEq(tickBefore, Slot0Library.tick(pm.getSlot0(k.toId())), "tick did not move");
    }

    /// Jexi: on 68791f6 12s idle gave no surcharge but 13s+ pinned the 10% cap.
    function test_003_lvrRealisticTickSkippedBlocksNoSurcharge() public {
        PoolKey memory k = _key(CurveType.CLAMM, 500, 10, address(lvr));
        uint160 sp =
            uint160((uint256(TickMathLib.getSqrtRatioAtTick(-197_000)) + TickMathLib.getSqrtRatioAtTick(-196_999)) / 2);
        pm.initialize(k, sp, "");
        _actor(1e30).exec(_one(_op(0, k, -197_200, -196_800, 1e20, false)));
        uint256 ts = block.timestamp;
        uint32[4] memory idles = [uint32(12), 13, 25, 600];
        for (uint256 i; i < idles.length; i++) {
            ts += idles[i];
            vm.warp(ts);
            _swap(k, i % 2 == 0, 1e3);
            assertEq(_fee(k), 500, "no surcharge from idle time");
        }
    }

    // ================================================================== 004 (H3)
    /// Single-range pool must not freeze once price leaves the range (both directions).
    function test_004_clammSingleRangeDoesNotFreeze() public {
        PoolKey memory k = _clammPool(address(0), -600, 600, SQRT_1_1, 1e21);
        uint256 o1 = _swap(k, true, 1e24); // sells through the range and out of it
        assertGt(o1, 0);
        assertLt(Slot0Library.tick(pm.getSlot0(k.toId())), -600, "price left the range");
        uint256 o2 = _swap(k, false, 1e18); // buy back: crosses the gap into the range
        assertGt(o2, 0, "buy-back fills after crossing back");
        uint256 o3 = _swap(k, true, 1e15);
        assertGt(o3, 0, "sell side still works");
        // and the mirror image: buy out of the range upwards, then sell back
        uint256 o4 = _swap(k, false, 1e24);
        assertGt(o4, 0);
        assertGt(Slot0Library.tick(pm.getSlot0(k.toId())), 600);
        assertGt(_swap(k, true, 1e18), 0, "sell-back fills after crossing down");
    }

    // ================================================================== 005 (H4)
    function test_005_binPoolsDisabled() public {
        PoolKey memory k = _key(CurveType.BIN_AMM, 3000, 10, address(0));
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.CurveDisabled.selector, uint8(CurveType.BIN_AMM)));
        pm.initialize(k, SQRT_1_1, "");
    }

    // ================================================================== 007 (H5)
    function test_007_governanceCannotDrainOrInstantlyChangeRoles() public {
        PoolKey memory k = _clammPool(address(0), -1200, 1200, SQRT_1_1, 1e24);
        k;
        uint256 res0 = vault.reservesOf(c0);
        JTimelockDrainHelper h = new JTimelockDrainHelper(vault, timelock);

        vm.startPrank(GOV);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        timelock.setExecutor(address(h), true); // no longer instant

        // Even through the full delay, the timelock (vault owner) cannot accountDelta.
        bytes memory setExec = abi.encodeCall(SupaTimelock.setExecutor, (address(h), true));
        timelock.schedule(address(timelock), 0, setExec, bytes32(0), bytes32("A"), 1 days);
        bytes memory dataB = abi.encodeCall(SupaVault.accountDelta, (address(h), c0, int256(res0)));
        timelock.schedule(address(vault), 0, dataB, bytes32(0), bytes32("B"), 1 days);
        vm.warp(block.timestamp + 1 days);
        timelock.execute(address(timelock), 0, setExec, bytes32(0), bytes32("A"));
        vm.stopPrank();
        assertTrue(timelock.isExecutor(address(h)));

        vm.expectRevert(VaultErrors.Unauthorized.selector);
        h.run(dataB);
        assertEq(vault.reservesOf(c0), res0);
    }

    // ================================================================== 008 AntiJIT +1 bypass
    function test_008_antiJIT_plusOneIncreaseDoesNotBypass() public {
        uint256 snap = vm.snapshotState();
        (uint256 a0, uint256 a1) = _measureJit(false);
        vm.revertToState(snap);
        (uint256 b0, uint256 b1) = _measureJit(true);
        assertApproxEqAbs(b0, a0, 2, "bypass receives the same token0 as control");
        assertApproxEqAbs(b1, a1, 2, "bypass receives the same token1 as control");
    }

    function _measureJit(bool bypass) internal returns (uint256 got0, uint256 got1) {
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(jit));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e27).exec(_one(_op(0, k, -600, 600, 1e22, false)));
        vm.roll(block.number + 100);
        JFlashActor j = _actor(1e27);
        j.exec(_one(_op(0, k, -600, 600, 9e22, false)));
        uint256 afterAdd0 = t0.balanceOf(address(j));
        uint256 afterAdd1 = t1.balanceOf(address(j));
        _swap(k, true, 100e18);
        if (bypass) {
            JFlashActor.Op[] memory ops = new JFlashActor.Op[](2);
            ops[0] = _op(0, k, -600, 600, 1, false);
            ops[1] = _op(0, k, -600, 600, -int256(9e22 + 1), false);
            j.exec(ops);
        } else {
            j.exec(_one(_op(0, k, -600, 600, -int256(9e22), false)));
        }
        got0 = t0.balanceOf(address(j)) - afterAdd0;
        got1 = t1.balanceOf(address(j)) - afterAdd1;
    }

    // ================================================================== 014 AntiJIT residency dilution
    /// A resident seed position that is topped up in the same block as a trade cannot collect the
    /// post-top-up fees (clock restarts for the whole position).
    function test_014_residentSeedDoesNotShieldJitTopUp() public {
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(jit));
        pm.initialize(k, SQRT_1_1, "");
        JFlashActor lp = _actor(1e27);
        lp.exec(_one(_op(0, k, -600, 600, 1e22, false)));
        vm.roll(block.number + 1000); // seed fully vested (>> 2 * minResidencyBlocks)
        lp.exec(_one(_op(0, k, -600, 600, 1e22, false))); // same-size JIT top-up
        _swap(k, true, 100e18);
        uint256 b0 = t0.balanceOf(address(lp));
        uint256 b1 = t1.balanceOf(address(lp));
        lp.exec(_one(_op(0, k, -600, 600, 0, false))); // fee poke, same block
        assertEq(t0.balanceOf(address(lp)) - b0, 0, "post-top-up fees fully unvested");
        assertEq(t1.balanceOf(address(lp)) - b1, 0);
    }

    // ================================================================== 009 LVR operator fee power
    function test_009_lvrFeeParamsGovernanceOnlyAndCapped() public {
        PoolKey memory k = _clammPool(address(lvr), -1200, 1200, SQRT_1_1, 1e24);
        vm.startPrank(OPERATOR);
        vm.expectRevert();
        lvr.setMaxFeePips(k, 50_000);
        vm.expectRevert();
        lvr.setMinFeePips(k, 50_000);
        vm.stopPrank();

        vm.startPrank(address(timelock)); // roles owner = timelock (stands in for an executed proposal)
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidFeeParameter.selector, uint24(990_000)));
        lvr.setMaxFeePips(k, 990_000);
        lvr.setMaxFeePips(k, 100_000);
        lvr.setMinFeePips(k, 100_000);
        vm.stopPrank();
        _swap(k, true, 1e18);
        assertLe(_fee(k), 100_000, "fee never above the 10% cap");
    }

    // ================================================================== 010 (M1)
    function test_010_guardianPauseDoesNotFreezeWithdrawals() public {
        claims.deposit(c0, address(this), 10e18);
        vault.setOperator(address(claims), true);
        vm.prank(GUARD);
        cb.pauseVault();
        uint256 before = t0.balanceOf(address(this));
        claims.withdraw(c0, address(this), 10e18);
        assertEq(t0.balanceOf(address(this)) - before, 10e18);
    }

    // ================================================================== 011 delisting
    function test_011_pluginDelistDoesNotFreezeLPExits() public {
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(jit));
        pm.initialize(k, SQRT_1_1, "");
        JFlashActor lp = _actor(1e27);
        lp.exec(_one(_op(0, k, -600, 600, 1e21, false)));
        uint256 b0 = t0.balanceOf(address(lp));
        vm.prank(address(timelock));
        wl.setPluginWhitelisted(address(jit), false);
        lp.exec(_one(_op(0, k, -600, 600, -1e21, false))); // exits with hooks skipped
        assertGt(t0.balanceOf(address(lp)), b0, "principal returned");
        vm.expectRevert(); // adds and swaps stay blocked
        lp.exec(_one(_op(0, k, -600, 600, 1e21, false)));
    }

    // ================================================================== 012 BinAMM share math
    /// Engine-level (bin pools are gated at the PoolManager): after a trade moves the bin's
    /// reserve mix, an atomic add->remove returns no more of either token than was paid.
    function test_012_binSharesProportionalRoundTrip() public {
        BinAMMEngine e = new BinAMMEngine(address(this));
        PoolKey memory k = _key(CurveType.BIN_AMM, 3000, 10, address(0));
        e.initialize(k, SQRT_1_1);
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, int256(1000e18), bytes32(0)), address(1));
        e.swap(k, IPoolManager.SwapParams(true, 300e18, 0), 3000, 0);
        (BalanceDelta add,) =
            e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, int256(1000e18), bytes32(0)), address(2));
        (BalanceDelta rem,) =
            e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, -int256(1000e18), bytes32(0)), address(2));
        assertLe(uint256(int256(-rem.amount0())), uint256(int256(add.amount0())));
        assertLe(uint256(int256(-rem.amount1())), uint256(int256(add.amount1())));
    }

    function testFuzz_012_binSharesRoundTrip(uint96 seed, uint96 tradeIn, bool z, uint96 dep) public {
        seed = uint96(bound(seed, 1e6, 1e24));
        BinAMMEngine e = new BinAMMEngine(address(this));
        PoolKey memory k = _key(CurveType.BIN_AMM, 3000, 10, address(0));
        e.initialize(k, SQRT_1_1);
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, int256(uint256(seed)), bytes32(0)), address(1));
        tradeIn = uint96(bound(tradeIn, 0, seed / 2));
        if (tradeIn > 1000) {
            try e.swap(k, IPoolManager.SwapParams(z, int256(uint256(tradeIn)), 0), 3000, 0) {} catch {}
        }
        dep = uint96(bound(dep, 1, 1e24));
        (BalanceDelta add,) =
            e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, int256(uint256(dep)), bytes32(0)), address(2));
        (BalanceDelta rem,) = e.modifyLiquidity(
            k, IPoolManager.ModifyLiquidityParams(0, 0, -int256(uint256(dep)), bytes32(0)), address(2)
        );
        assertLe(-int256(rem.amount0()), int256(add.amount0()));
        assertLe(-int256(rem.amount1()), int256(add.amount1()));
    }

    // ================================================================== 013 LVR setRoles front-run
    function test_013_lvrSetRolesOnlyDeployer() public {
        LVRShieldPlugin fresh = new LVRShieldPlugin(pm);
        vm.prank(address(0xA77AC4E2));
        vm.expectRevert();
        fresh.setRoles(ISupaRoles(address(roles)));
        fresh.setRoles(ISupaRoles(address(roles))); // deployer (this) succeeds
        assertEq(address(fresh.roles()), address(roles));
    }

    // ================================================================== CLAMM accounting fuzz (Jexi)
    function test_fuzz_clammSolvencyAcrossCrossings(uint256 seed) public {
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(0));
        pm.initialize(k, SQRT_1_1, "");
        JFlashActor lpA = _actor(1e27);
        JFlashActor lpB = _actor(1e27);
        lpA.exec(_one(_op(0, k, -1200, 1200, 1e22, false)));
        lpB.exec(_one(_op(0, k, -300, 600, 3e22, false)));
        for (uint256 i; i < 8; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool z = r & 1 == 0;
            uint128 amt = uint128(bound(r >> 8, 1e15, 2e20));
            _swap(k, z, amt);
        }
        lpA.exec(_one(_op(0, k, -1200, 1200, -1e22, false)));
        lpB.exec(_one(_op(0, k, -300, 600, -3e22, false)));
        assertGe(t0.balanceOf(address(vault)), vault.reservesOf(c0));
        assertGe(t1.balanceOf(address(vault)), vault.reservesOf(c1));
        assertLt(vault.reservesOf(c0), 1e6, "dust only");
        assertLt(vault.reservesOf(c1), 1e6, "dust only");
    }
}
