// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
import {PoolKey, CurveType} from "../../../contract/types/PoolKey.sol";
import {PoolId} from "../../../contract/types/PoolId.sol";
import {Currency} from "../../../contract/types/Currency.sol";
import {BalanceDelta} from "../../../contract/types/BalanceDelta.sol";
import {JToken} from "./JexiRegression.t.sol";
import {PluginWhitelist} from "../../../contract/governance/PluginWhitelist.sol";
import {IPluginWhitelist} from "../../../contract/interfaces/IPluginWhitelist.sol";

/// Flash actor: 0 = modifyLiquidity, 1 = swap, 2 = donate(amt, amt). Settles net deltas at the end of the unlock.
contract FGActor is IUnlockCallback {
    struct Op {
        uint8 kind;
        int24 lo;
        int24 hi;
        int256 amt;
        bool zeroForOne;
    }

    SupaVault public immutable vault;
    SupaPoolManager public immutable pm;
    PoolKey internal key;

    constructor(SupaVault v, SupaPoolManager m) {
        vault = v;
        pm = m;
    }

    function exec(PoolKey memory k, Op[] memory ops) external {
        key = k;
        vault.unlock(abi.encode(ops));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault), "only vault");
        Op[] memory ops = abi.decode(data, (Op[]));
        for (uint256 i; i < ops.length; i++) {
            Op memory o = ops[i];
            if (o.kind == 0) {
                pm.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(o.lo, o.hi, o.amt, 0), "");
            } else if (o.kind == 1) {
                pm.swap(key, IPoolManager.SwapParams(o.zeroForOne, o.amt, 0), "");
            } else {
                pm.donate(key, uint256(o.amt), uint256(o.amt), "");
            }
        }
        _net(key.currency0);
        _net(key.currency1);
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

/// @notice Remediation-3 condition 2 (Edith E-1 / G-2): fee growth is a mod-2^256 accumulator in BIN, CLAMM and
///         Stable. A saturated accumulator must never block swaps, and fee accounting stays correct across a wrap.
contract FeeGrowthWrapTest is Test {
    uint160 internal constant SQRT_1_1 = uint160(1 << 96);
    uint256 internal constant INT128_MAX = uint256(uint128(type(int128).max));

    // ------------------------------------------------------------------ engine-level (test = pool manager)

    function _binKey() internal pure returns (PoolKey memory) {
        return
            PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), 3000, 10, address(0), CurveType.BIN_AMM);
    }

    function extBinSwap(BinAMMEngine e, bool z, int256 a) external returns (BalanceDelta d) {
        (d,) = e.swap(_binKey(), IPoolManager.SwapParams(z, a, 0), 3000, 0);
    }

    function _poisonBin(BinAMMEngine e, PoolKey memory k) internal returns (uint256 g0) {
        for (uint256 i; i < 4; i++) {
            (,,, uint256 c0,) = e.getBin(k.toId(), 0);
            uint256 room = (type(uint256).max - c0) >> 128;
            if (room == 0) break;
            uint256 amt = room > INT128_MAX ? INT128_MAX : room;
            e.donate(k, amt, amt);
        }
        (,,, g0,) = e.getBin(k.toId(), 0);
    }

    /// Edith's test_poisonActiveBinFeeGrowth, inverted: after the attacker saturates bin 0's growth, swaps through
    /// the poisoned bin SUCCEED (previously both reverted with panic 0x11).
    function test_bin_poisonedActiveBin_swapsStillSucceed() public {
        BinAMMEngine e = new BinAMMEngine(address(this));
        PoolKey memory k = _binKey();
        e.initialize(k, SQRT_1_1, "");
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, 1, bytes32("atk")), address(this));
        uint256 g0 = _poisonBin(e, k);
        assertGt(g0, type(uint256).max - (uint256(1) << 128), "growth saturated (within 2^128 of 2^256)");
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(-64, -1, 1e24, bytes32("lp")), address(this));

        BalanceDelta d = this.extBinSwap(e, true, 1e18);
        assertEq(d.amount0(), 1e18, "exact-in fully consumed");
        assertGt(-d.amount1(), 0);
        d = this.extBinSwap(e, true, 1e22);
        assertGt(-d.amount1(), 0, "large swap crosses the poisoned bin");
        (,,, uint256 g0After,) = e.getBin(k.toId(), 0);
        assertLt(g0After, g0, "accumulator wrapped through 2^256 (mod arithmetic)");
        // the honest LP can still exit and collect its fees
        (BalanceDelta out, BalanceDelta fees) =
            e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(-64, -1, -1e24, bytes32("lp")), address(this));
        assertLt(out.amount1() + out.amount0(), 0);
        assertGt(fees.amount0(), 0, "LP fees accrued in the bins below");
    }

    /// Accounting control: an LP that joins the poisoned bin (checkpoint within 2^128 of 2^256) receives exactly its
    /// pro-rata fee. (Passes with checked or unchecked math; the wrap itself is exercised by the other tests.)
    function test_bin_lpJoiningPoisonedBin_getsProRataFees() public {
        BinAMMEngine e = new BinAMMEngine(address(this));
        PoolKey memory k = _binKey();
        e.initialize(k, SQRT_1_1, "");
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, 1, bytes32("atk")), address(this));
        _poisonBin(e, k);
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, 1e24, bytes32("lp")), address(this));
        // swap 1e18 token0 in: fee 0.3% stays inside bin 0 (active, deep) => growth increment crosses 2^256
        this.extBinSwap(e, true, 1e18);
        (, BalanceDelta fees) =
            e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, -1e23, bytes32("lp")), address(this));
        // fee = ceil(1e18 * 0.003); LP owns ~1e24 of 1e24+1 shares
        uint256 expected = uint256(1e18) * 3000 / 1e6;
        assertApproxEqAbs(uint256(int256(fees.amount0())), expected, 2, "pro-rata fee across the wrap");
    }

    function _clammKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0x1)), Currency.wrap(address(0x2)), 3000, 60, address(0), CurveType.CLAMM);
    }

    function extClammSwap(CLAMMEngine e, bool z, int256 a) external returns (BalanceDelta d) {
        (d,) = e.swap(_clammKey(), IPoolManager.SwapParams(z, a, 0), 3000, 0);
    }

    /// Donation-to-max on CLAMM: the attacker is the sole LP of the active range [-60, 60] (L = 1) and parks the
    /// global growth at 2^256 - 2^128; honest liquidity sits outside. The first swap step inside the L = 1 range
    /// adds >= 2^128 of growth (overflowed under checked math); it must now succeed and fees stay correct.
    function test_clamm_donationToMax_swapsAndFeesWork() public {
        CLAMMEngine e = new CLAMMEngine(address(this));
        PoolKey memory k = _clammKey();
        e.initialize(k, SQRT_1_1, "");
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(-60, 60, 1, bytes32("atk")), address(this));
        e.donate(k, INT128_MAX, INT128_MAX);
        e.donate(k, INT128_MAX, INT128_MAX); // growth = 2^256 - 2^129
        e.donate(k, 1, 1); // growth = 2^256 - 2^128
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(-6000, -60, 1e24, bytes32("lpL")), address(this));
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(60, 6000, 1e24, bytes32("lpU")), address(this));
        BalanceDelta d = this.extClammSwap(e, true, 1e18);
        assertEq(d.amount0(), 1e18, "swap through the saturated range succeeds");
        d = this.extClammSwap(e, false, 3e18);
        assertEq(d.amount1(), 3e18);
        (, BalanceDelta feesL) =
            e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(-6000, -60, -1e24, bytes32("lpL")), address(this));
        // lower LP earned (almost) the whole token0 fee of the first swap (all but the tiny step in [-60,60])
        assertApproxEqRel(uint256(int256(feesL.amount0())), 3e15, 1e15, "fees across a wrapped global");
        assertLe(uint256(int256(feesL.amount0())), 3e15);
    }

    // Stable engine-level: the test is also the engine's PoolManager admin surface.
    address public owner = address(this);
    address public circuitBreaker = address(0);

    function extStableSwap(StableAMMEngine e, PoolKey memory k, bool z, int256 a) external returns (BalanceDelta d) {
        (d,) = e.swap(k, IPoolManager.SwapParams(z, a, 0), k.fee, 0);
    }

    function test_stable_donationToMax_swapsAndFeesWork() public {
        StableAMMEngine e = new StableAMMEngine(address(this));
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0x2)), 400, 1, address(0), CurveType.STABLE_AMM);
        vm.mockCall(address(0x2), abi.encodeWithSignature("decimals()"), abi.encode(uint256(18)));
        e.initialize(k, SQRT_1_1, abi.encode(uint256(100)));
        // smallest first deposit: 1001 shares, 1000 locked; attacker owns 1
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, 1001, bytes32("atk")), address(this));
        // each donation adds ~2^255 / 1001: 2,010 of them pass 2^256 (checked math reverted at ~#2,003)
        for (uint256 i; i < 2010; i++) {
            e.donate(k, INT128_MAX, INT128_MAX);
        }
        e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, 1e24, bytes32("lp")), address(this));
        uint256 checkpoint = e.getPosition(k.toId(), address(this), 0, 0, bytes32("lp")).feeGrowthInside0LastX128;
        assertLt(checkpoint, type(uint256).max / 100, "global growth wrapped past 2^256");
        BalanceDelta d = this.extStableSwap(e, k, true, 1e18);
        assertEq(d.amount0(), 1e18);
        (, BalanceDelta fees) =
            e.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(0, 0, -1e23, bytes32("lp")), address(this));
        // fee 4 bp of 1e18 = 4e14, LP owns ~all shares
        assertApproxEqAbs(uint256(int256(fees.amount0())), 4e14, 2);
    }

    // ------------------------------------------------------------------ PoolManager-level (Edith Q3)

    SupaVault internal sv;
    SupaPoolManager internal spm;
    JToken internal t0;
    JToken internal t1;

    function _deployStack() internal {
        SupaVault impl = new SupaVault(address(this));
        sv = SupaVault(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(SupaVault.initialize, (address(this))))))
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        CLAMMEngine clamm = new CLAMMEngine(predicted);
        BinAMMEngine bin = new BinAMMEngine(predicted);
        StableAMMEngine stable = new StableAMMEngine(predicted);
        spm = new SupaPoolManager(
            IVault(address(sv)), ICurveEngine(address(clamm)), ICurveEngine(address(bin)), ICurveEngine(address(stable))
        );
        require(address(spm) == predicted, "pm addr");
        sv.setPoolManager(address(spm), true);
        JToken a = new JToken("A");
        JToken b = new JToken("B");
        if (address(a) > address(b)) (a, b) = (b, a);
        (t0, t1) = (a, b);
    }

    function _attack(PoolKey memory k) internal returns (uint256 spent) {
        FGActor attacker = new FGActor(sv, spm);
        t0.mint(address(attacker), 10);
        t1.mint(address(attacker), 10);
        uint256 donation = 2 ** 126; // the fee credit back must fit int128
        FGActor.Op[] memory ops = new FGActor.Op[](13);
        uint256 n;
        for (uint256 i; i < 4; i++) {
            // last round 1 wei short so the accumulator lands at 2^256 - 2^128 (the wall), not exactly 0
            uint256 amt = i == 3 ? donation - 1 : donation;
            ops[n++] = FGActor.Op(0, 0, 0, 1, false); // add 1 share (seeds 1 wei token1)
            ops[n++] = FGActor.Op(2, 0, 0, int256(amt), false); // donate ~2^126 of each token
            ops[n++] = FGActor.Op(0, 0, 0, -1, false); // remove: fees = donation credited back
        }
        ops[n++] = FGActor.Op(0, 0, 0, 1, false); // keep the dust share
        attacker.exec(k, ops);
        spent = (10 - t0.balanceOf(address(attacker))) + (10 - t1.balanceOf(address(attacker)));
    }

    /// Edith Q3: the price wall is reachable at PoolManager level with ~zero capital via flash accounting
    /// ([add 1 share, donate, remove] repeated inside one unlock; donations come back as the attacker's own fees).
    /// This test CONFIRMS that (attacker's net spend is a few wei) and shows that after the fix the wall no longer
    /// blocks honest swaps.
    function test_pm_zeroCapitalPoison_noLongerBlocksSwaps() public {
        _deployStack();
        PoolKey memory k =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 10, address(0), CurveType.BIN_AMM);
        address[] memory none = new address[](0);
        spm.setPluginWhitelist(IPluginWhitelist(address(new PluginWhitelist(address(this), none))));
        spm.initialize(k, SQRT_1_1, "");
        BinAMMEngine bin = BinAMMEngine(address(spm.binEngine()));

        assertLe(_attack(k), 10, "zero-capital: attacker spent only a few wei (Q3 confirmed)");
        (,,, uint256 g0, uint256 g1) = bin.getBin(k.toId(), 0);
        assertEq(g0, type(uint256).max - (uint256(1) << 128) + 1, "bin 0 growth parked at 2^256 - 2^128");
        assertEq(g1, g0);

        FGActor lp = new FGActor(sv, spm);
        t0.mint(address(lp), 1e30);
        t1.mint(address(lp), 1e30);
        FGActor.Op[] memory one = new FGActor.Op[](1);
        one[0] = FGActor.Op(0, -64, -1, 1e24, false);
        lp.exec(k, one);

        FGActor trader = new FGActor(sv, spm);
        t0.mint(address(trader), 1e22);
        one[0] = FGActor.Op(1, 0, 0, 1e22, true);
        trader.exec(k, one);
        assertEq(t0.balanceOf(address(trader)), 0, "trader's exact-in consumed");
        assertGt(t1.balanceOf(address(trader)), 0, "trader received token1 through the poisoned bin");
        assertLt(bin.getActiveBinId(k.toId()), 0, "price moved below the former wall");

        one[0] = FGActor.Op(0, -64, -1, -1e24, false);
        lp.exec(k, one);
    }
}
