// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Jexi (Apus Security Auditor) independent PoCs for SupaDex @ 68791f6.
// LOCAL ONLY. Run from a clone: copy to test/_jexi/ and `forge test --match-path 'test/_jexi/*' -vv`.
// Independent of Ultron's harness: own ERC20 mock, own flash actor, production-like wiring
// (ERC1967 proxy vault, SupaTimelock as owner, CircuitBreaker, PluginWhitelist with real plugins).
//
// Ported into the repo by remediation-2 (Jexi 018) as the shared base of JexiPR1VerifyTest.
// The original file asserted that each baseline exploit SUCCEEDS; on fixed code those PoCs fail by design, so the
// exploit-positive tests are not carried here (the verbatim original is archived at
// apus-ops/projects/supadex/remediation-2/jexi-port-baseline/JexiSupaDex.t.sol). Each is covered by an inverted
// regression that asserts the fix:
//   test_C1_computeD_wrongAtBalance_and_computeY_inconsistent      -> JexiRegression.test_001_computeDCorrectAtBalance_andComputeYConsistent, BaselineRegression.test_PoC6_*
//   test_C1_dustSwapsDrainStablePool                               -> JexiRegression.test_001_dustSwapsCannotDrainStablePool, JexiPR1Verify.test_stable_originalDustDrainNowReverts
//   test_C2_zeroCapitalAddRemoveStealsFromLPs                      -> JexiRegression.test_002_zeroCapitalAddRemoveExtractsNothing
//   test_H1_oneWeiDonationBricksRouterAndClaims_anyoneCanUnstick   -> JexiRegression.test_006_oneWeiDonationDoesNotBrickRouterOrClaims
//   test_H1b_negativeRebaseBricksSettle                            -> JexiRegression 006b / vault sync-settle tests
//   test_H2_lvrMaxFeeWithZeroVolatility                            -> JexiRegression 003 + JexiPR1Verify.test_lvr_surchargeOnRealMove_andCapped
//   test_H2b_lvrRealisticTickOneSkippedBlock                       -> JexiRegression 003
//   test_H3_clammFreezesAfterPriceLeavesOnlyRange                  -> JexiRegression 004, JexiPR1Verify.test_clamm_disjointRangesCrossGapBothWays
//   test_H4_binFixedPriceDrain                                     -> JexiRegression.test_005_binPoolsMultiBinPriceDiscovery, JexiPR1Verify.test_bin_priceMovesAcrossBins_noStalePriceDrain
//   test_H5_timelockOwnerCanDrainVaultAfterDelay                   -> JexiRegression.test_007_governanceCannotDrainOrInstantlyChangeRoles, SupaTimelockTest (ADR-0010)
//   test_NEW_antiJIT_bypassViaPlusOneIncrease                      -> JexiRegression.test_008_antiJIT_plusOneIncreaseDoesNotBypass, JexiPR1Verify.test_antiJIT_haircutActuallyApplies
//   test_NEW_lvrOperatorCanSetNear100PctFeeInstantly               -> JexiRegression 009 (governance-only LVR params)
//   test_M1_guardianPauseFreezesWithdrawals                        -> BaselineRegression.test_pauseBlocksSwapsAndAddsButNotWithdrawals, JexiPR1Verify.test_pause_poolAndCurve_removalsStillWork
//   test_NEW_pluginDelistFreezesLPExits                            -> JexiRegression 011 (delisted plugin: exits stay open)
// Kept: helpers, production-like setUp, and the still-valid property tests (fuzz round trips / solvency, INFO).
// PORT: setUp uses a separate timelock executor (ADR-0010 forbids proposer == executor).

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {ICurveEngine} from "../../contract/interfaces/ICurveEngine.sol";
import {IVault} from "../../contract/interfaces/IVault.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {ISupaRoles} from "../../contract/interfaces/ISupaRoles.sol";
import {ICircuitBreaker} from "../../contract/interfaces/ICircuitBreaker.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {SupaClaimsRouter} from "../../contract/periphery/SupaClaimsRouter.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";
import {SupaRoles} from "../../contract/governance/SupaRoles.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {CircuitBreaker} from "../../contract/security/CircuitBreaker.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {AntiJITVestingPlugin} from "../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";
import {CircuitBreakerErrors} from "../../contract/errors/CircuitBreakerErrors.sol";
import {GovernanceErrors} from "../../contract/errors/GovernanceErrors.sol";

/// Minimal independent ERC20 (no hooks). `rebaseDown` simulates a negative rebase/slash on a holder.
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
                    o.key, IPoolManager.ModifyLiquidityParams({tickLower: o.lo, tickUpper: o.hi, liquidityDelta: o.amt, salt: 0}), ""
                );
            } else {
                pm.swap(o.key, IPoolManager.SwapParams({zeroForOne: o.zeroForOne, amountSpecified: o.amt, sqrtPriceLimitX96: 0}), "");
            }
        }
        _net(ops[0].key.currency0);
        _net(ops[0].key.currency1);
        return "";
    }

    function _net(Currency c) internal {
        int256 d = vault.getCurrencyDelta(address(this), c);
        if (d < 0) {
            vault.sync(c); // PR1 ADAPTATION A1: settle() now requires a prior sync() (ADR-0002)
            JToken(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}

/// Anyone can sweep the vault surplus (balance - reserves) to themselves.
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

/// Helper that, once made executor (instantly, by the timelock admin), lets two queued timelock
/// ops drain the vault through the owner branch of accountDelta.
contract JTimelockDrainHelper is IUnlockCallback {
    SupaVault public immutable vault;
    SupaTimelock public immutable tl;
    Currency public c;
    uint256 public amt;
    address public sink;
    bytes32 public saltB;

    constructor(SupaVault v, SupaTimelock t) {
        vault = v;
        tl = t;
    }

    function configure(Currency c_, uint256 amt_, address sink_, bytes32 saltB_) external {
        c = c_;
        amt = amt_;
        sink = sink_;
        saltB = saltB_;
    }

    function run() external {
        vault.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        tl.execute(address(vault), 0, abi.encodeCall(SupaVault.accountDelta, (address(this), c, int256(amt))), bytes32(0), saltB);
        vault.take(c, sink, amt);
        return "";
    }
}

contract JexiSupaDexTest is Test {
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

    address constant GOV = address(0x6007); // timelock proposer + canceller
    address constant EXEC = address(0xE7EC); // remediation-2 port: ADR-0010 requires a separate executor
    address constant GUARD = address(0x6A2D);
    address constant OPERATOR = address(0x0FE2);
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    function setUp() public {
        address[] memory g = new address[](1);
        g[0] = GOV;
        address[] memory ex = new address[](1);
        ex[0] = EXEC;
        timelock = new SupaTimelock(1 days, GOV, g, ex, g);
        address[] memory gs = new address[](1);
        gs[0] = GUARD;
        cb = new CircuitBreaker(address(timelock), gs);

        SupaVault impl = new SupaVault(address(this));
        vault = SupaVault(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(SupaVault.initialize, (address(this)))))));
        vault.setCircuitBreaker(ICircuitBreaker(address(cb)));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        clamm = new CLAMMEngine(predicted);
        bin = new BinAMMEngine(predicted);
        stable = new StableAMMEngine(predicted);
        pm = new SupaPoolManager(IVault(address(vault)), ICurveEngine(address(clamm)), ICurveEngine(address(bin)), ICurveEngine(address(stable)));
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

    // ================================================================== C1




    // ================================================================== C2


    /// Property that SHOULD hold for any AMM: an atomic add->remove round trip is never profitable.
    /// Expected to FAIL on 68791f6 (fuzzer finds counterexamples) - documents C2.
    function test_fuzz_prop_stableAddRemoveNotProfitable(uint96 tradeIn, uint96 dep) public {
        tradeIn = uint96(bound(tradeIn, 1e15, 400e18));
        dep = uint96(bound(dep, 1e15, 1e24));
        PoolKey memory k = _key(CurveType.STABLE_AMM, 500, 100, address(0)); // PORT: A = 100 (tickSpacing carries A)
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e26).exec(_one(_op(0, k, 0, 0, int256(1000e18), false)));
        _swap(k, true, tradeIn);
        JFlashActor attacker = _actor(1e26);
        uint256 b = t0.balanceOf(address(attacker)) + t1.balanceOf(address(attacker));
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](2);
        ops[0] = _op(0, k, 0, 0, int256(uint256(dep)), false);
        ops[1] = _op(0, k, 0, 0, -int256(uint256(dep)), false);
        attacker.exec(ops);
        uint256 a = t0.balanceOf(address(attacker)) + t1.balanceOf(address(attacker));
        assertLe(a, b, "round trip profitable");
    }

    // ================================================================== H1
    function _clammPool(address plugin, int24 lo, int24 hi, uint160 sqrtP, int256 liq) internal returns (PoolKey memory k) {
        k = _key(CurveType.CLAMM, 3000, 60, plugin);
        pm.initialize(k, sqrtP, "");
        _actor(1e27).exec(_one(_op(0, k, lo, hi, liq, false)));
    }




    // ================================================================== H2
    function _fee(PoolKey memory k) internal view returns (uint24 lastFee) {
        (, lastFee,,,,,,,) = lvr.poolLVRStates(k.toId());
    }





    // ================================================================== H3


    // ================================================================== H4


    // ================================================================== H5


    // ================================================================== NEW: AntiJIT bypass


    function _measureJit(bool bypass) internal returns (uint256 fees0, uint256 fees1) {
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
        fees0 = t0.balanceOf(address(j)) - afterAdd0;
        fees1 = t1.balanceOf(address(j)) - afterAdd1;
    }

    // ================================================================== NEW: LVR operator fee


    // ================================================================== M1 (Ultron) confirm




    /// BinAMM mints shares == amount0 just like StableAMM (C2 pattern) but, because the bin price
    /// is fixed and swaps conserve value at that price, an atomic add/remove is value-neutral today.
    /// Becomes exploitable as soon as the bin price can move (i.e. when H4 is "fixed").
    function test_INFO_binShareFormulaNeutralAtFixedPrice() public {
        PoolKey memory k = _key(CurveType.BIN_AMM, 3000, 10, address(0));
        pm.initialize(k, SQRT_1_1, "");
        _actor(1e24).exec(_one(_op(0, k, 0, 0, int256(1000e18), false)));
        _swap(k, true, 300e18);
        JFlashActor a = _actor(1e24);
        uint256 b = t0.balanceOf(address(a)) + t1.balanceOf(address(a));
        JFlashActor.Op[] memory ops = new JFlashActor.Op[](2);
        ops[0] = _op(0, k, 0, 0, int256(1000e18), false);
        ops[1] = _op(0, k, 0, 0, -int256(1000e18), false);
        a.exec(ops);
        uint256 after_ = t0.balanceOf(address(a)) + t1.balanceOf(address(a));
        console2.log("bin add/remove round trip: before, after (t0+t1 at p=1)", b, after_);
        assertLe(after_, b + 1);
    }

    // ================================================================== CLAMM accounting fuzz
    /// Two overlapping LPs, a random sequence of swaps that cross their ticks, then both exit.
    /// Property: exits never revert and the vault's real token balance always covers reservesOf.
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
        // after all LPs exit only protocol fees (0 here) + rounding dust may remain
        assertLt(vault.reservesOf(c0), 1e6, "dust only");
        assertLt(vault.reservesOf(c1), 1e6, "dust only");
    }
}
