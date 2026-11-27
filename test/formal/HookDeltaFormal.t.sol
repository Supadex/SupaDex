// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {IVault} from "../../contract/interfaces/IVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {ICurveEngine} from "../../contract/interfaces/ICurveEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {BaseHook} from "../../contract/plugins/external/BaseHook.sol";
import {PluginDispatcher} from "../../contract/core/PluginDispatcher.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";

contract FormalDeltaTok {
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

/// @dev afterSwap hook returning a configured delta and recording the ENGINE
/// delta it observed (before the manager applies the haircut).
contract FormalDeltaHook is BaseHook {
    int128 public hookDelta;
    int128 public lastAmount0;
    int128 public lastAmount1;

    constructor(IPoolManager pm) BaseHook(pm) {}

    function setDelta(int128 d) external {
        hookDelta = d;
    }

    function getPluginPermissions() public pure override returns (uint32) {
        return PluginDispatcher.AFTER_SWAP_FLAG;
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        lastAmount0 = delta.amount0();
        lastAmount1 = delta.amount1();
        return (this.afterSwap.selector, hookDelta);
    }
}

/// @dev Minimal unlock actor: swaps and records the manager's (adjusted) delta.
contract FormalDeltaActor is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;
    BalanceDelta public lastSwapDelta;

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
            FormalDeltaTok(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}

/// @dev Empty contract used as a CREATE-address probe (see below).
contract FormalNonceProbe {}

/// @dev Deploys the manager + engines without ANY cheatcode, so Halmos can
/// run this file: Halmos 0.3.3 does not implement `vm.getNonce` /
/// `vm.computeCreateAddress`, which `SecurityTestSetup._deploy` uses to
/// predict the manager address for the engines. Engines take the manager
/// address in their constructor, so the manager address must be known before
/// the engines exist.
///
/// The manager address is predicted BEFORE the engines are created, and the
/// prediction differs by EVM model — a probe CREATE reveals which model
/// applies (the branch is taken from the probe's ACTUAL address, so no
/// assumption about the absolute nonce/counter is needed):
/// - Standard EVM (forge): a fresh contract starts at nonce 1 (EIP-161).
///   The probe takes nonce 1, the engines take 2–4, the manager takes 5,
///   predicted by pure-Solidity RLP.
/// - Halmos 0.3.3 (`sevm.py`): `CREATE` does NOT use the RLP derivation;
///   it assigns sequential magic addresses `0xAAAA0001 + counter`. The
///   probe takes one counter step, so the manager — 4 CREATEs later (3
///   engines + manager) — is `probe + 4`. (CREATE2 is derived properly in
///   Halmos, but it cannot break this circularity: the manager's CREATE2
///   address depends on the engine addresses, which depend on the manager's.)
/// The `require` guards the prediction in both forge and Halmos; if the
/// model ever differs again, setUp fails loudly instead of deploying a
/// misbound manager. The deployer is the manager's initial owner; it
/// nominates `owner` and the caller accepts, so the test contract ends up
/// owning the manager exactly as with the cheatcode deployment path.
contract FormalManagerDeployer {
    /// @notice Deploys the manager + engines; returns the manager and
    /// whether the Halmos magic-address model was detected (see below).
    /// Callers use the flag to skip setup the Halmos properties do not need
    /// (the control pool / second actor), keeping the symbolic state small:
    /// every extra storage slot inflates each solver query, and the
    /// end-to-end cap property is already near this VM's memory limit.
    function deploy(IVault vault, address owner) external returns (SupaPoolManager manager, bool halmosModel) {
        address probe = address(new FormalNonceProbe());
        address predicted;
        if (probe == _createAddress(address(this), 1)) {
            predicted = _createAddress(address(this), 5);
        } else if ((uint160(probe) >> 16) == 0xAAAA) {
            halmosModel = true;
            predicted = address(uint160(probe) + 4);
        } else {
            revert("FormalManagerDeployer: unknown CREATE-address model");
        }
        CLAMMEngine clamm = new CLAMMEngine(predicted);
        BinAMMEngine bin = new BinAMMEngine(predicted);
        StableAMMEngine stable = new StableAMMEngine(predicted);
        manager = new SupaPoolManager(
            vault, ICurveEngine(address(clamm)), ICurveEngine(address(bin)), ICurveEngine(address(stable))
        );
        require(address(manager) == predicted, "FormalManagerDeployer: manager address mismatch");
        manager.transferOwnership(owner);
    }

    /// @dev CREATE address for `nonce < 128`: RLP([deployer, nonce]).
    /// Payload is 0x94 + 20-byte address + 1-byte nonce = 22 bytes, so the
    /// list prefix is 0xc0 + 22 = 0xd6. Nonce 0 encodes as the empty string
    /// 0x80; nonces 1–127 encode as themselves.
    function _createAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce < 128, "FormalManagerDeployer: nonce too large");
        bytes memory nonceBytes = nonce == 0 ? bytes(hex"80") : abi.encodePacked(uint8(nonce));
        bytes memory payload = abi.encodePacked(bytes1(0x94), deployer, nonceBytes);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), payload)))));
    }
}

/// @title I-01 redesign: Halmos formal properties (design §9.4)
/// @notice (a) Split conservation is verified against the production pure
/// function `SupaPoolManager._splitHookHaircut` directly. (b) Cap/headroom is
/// verified END-TO-END: a real swap with a symbolic hook return must either
/// succeed with the specified leg byte-identical to the engine delta and the
/// unspecified leg moved by exactly the haircut, or revert with exactly
/// `HookDeltaCapExceeded`. Halmos 0.3.3 has no `expectRevert`, so both
/// properties use the T-5 low-level-call + returndata pattern. The forge
/// mirrors below prove the same properties under forge fuzz.
contract HookDeltaFormalTest is Test {
    using PoolIdLibrary for PoolKey;

    SupaVault internal vault;
    SupaPoolManager internal manager;
    FormalDeltaTok internal t0;
    FormalDeltaTok internal t1;
    PoolKey internal hookedKey;
    PoolKey internal controlKey;
    FormalDeltaHook internal hook;
    FormalDeltaActor internal swapper;
    FormalDeltaActor internal victim;
    IPoolManager.HookDeltaConfig internal cfg;

    function setUp() public {
        vault = new SupaVault(address(this));
        // No cheatcodes here (see FormalManagerDeployer): Halmos 0.3.3
        // cannot run `SecurityTestSetup.deployManagerWithEngines`.
        bool halmosModel;
        (manager, halmosModel) = new FormalManagerDeployer().deploy(vault, address(this));
        manager.acceptOwnership();
        vault.setPoolManager(address(manager), true);

        FormalDeltaTok a = new FormalDeltaTok();
        FormalDeltaTok b = new FormalDeltaTok();
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);

        hook = new FormalDeltaHook(manager);
        address[] memory plugins = new address[](1);
        plugins[0] = address(hook);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(hook), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        hookedKey = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 0,
            tickSpacing: 60,
            plugin: address(hook),
            curveType: CurveType.CLAMM
        });
        cfg = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: 5000, protocolBps: 3000, beneficiaryBps: 2000, beneficiary: address(0xBEEF)
        });
        manager.setHookDeltaConfig(hookedKey, cfg);
        manager.initialize(hookedKey, 1 << 96, "");

        swapper = new FormalDeltaActor(vault, manager);
        t0.mint(address(swapper), 1_000_000 ether);
        t1.mint(address(swapper), 1_000_000 ether);
        // Wide range so the 1e6 swap stays inside seeded liquidity.
        swapper.modify(hookedKey, -60000, 60000, 10_000_000, bytes32(0));

        if (!halmosModel) {
            // Forge-only setup: the cap mirror measures the exact cap on an
            // identical no-hook pool, and the victim actor seeds both pools.
            // The Halmos check_ properties never touch the control pool, so
            // under Halmos this state is skipped to keep solver queries small.
            controlKey = hookedKey;
            controlKey.plugin = address(0);
            manager.initialize(controlKey, 1 << 96, "");

            victim = new FormalDeltaActor(vault, manager);
            t0.mint(address(victim), 1_000_000 ether);
            t1.mint(address(victim), 1_000_000 ether);
            victim.modify(controlKey, -60000, 60000, 10_000_000, bytes32(0));
        }
    }

    /// @notice (a) Split conservation: for any haircut and any valid split,
    /// the three shares sum exactly to the haircut, each is <= the haircut,
    /// and a zero-bps recipient receives exactly zero.
    function check_hookDeltaSplitConservation(uint256 haircut, uint16 lpBps, uint16 protocolBps) external view {
        vm.assume(haircut <= uint256(uint128(type(int128).max)));
        vm.assume(uint256(lpBps) + uint256(protocolBps) <= 10_000);
        uint16 beneficiaryBps = uint16(10_000 - uint256(lpBps) - uint256(protocolBps));
        address ben = beneficiaryBps > 0 ? address(0xBEEF) : address(0);
        IPoolManager.HookDeltaConfig memory c = IPoolManager.HookDeltaConfig({
            maxHaircutBps: 500, lpBps: lpBps, protocolBps: protocolBps, beneficiaryBps: beneficiaryBps, beneficiary: ben
        });
        (uint256 lp, uint256 pr, uint256 be) = manager._splitHookHaircut(haircut, c);
        assertEq(lp + pr + be, haircut);
        assertLe(lp, haircut);
        assertLe(pr, haircut);
        assertLe(be, haircut);
        if (lpBps == 0) assertEq(lp, 0);
        if (protocolBps == 0) assertEq(pr, 0);
        if (beneficiaryBps == 0) assertEq(be, 0);
        if (lpBps == 10_000) assertEq(lp, haircut);
        if (protocolBps == 10_000) assertEq(pr, haircut);
        if (beneficiaryBps == 10_000) assertEq(be, haircut);
    }

    /// @notice (b) Cap/headroom, end-to-end: a real exactInput swap with a
    /// symbolic hook return either succeeds — specified leg identical to the
    /// engine delta, unspecified leg moved by exactly the haircut — or
    /// reverts with exactly `HookDeltaCapExceeded`. No other outcome is
    /// possible: the hook is permissioned, the pool is configured, and the
    /// fixed swap succeeds with a zero haircut.
    function check_hookDeltaCapHeadroom(int128 h) external {
        hook.setDelta(h);
        (bool ok, bytes memory ret) = address(swapper)
            .call(abi.encodeWithSelector(FormalDeltaActor.swap.selector, hookedKey, true, int256(1_000_000)));
        if (ok) {
            BalanceDelta adjusted = swapper.lastSwapDelta();
            assertEq(adjusted.amount0(), hook.lastAmount0(), "specified leg must stay exact");
            assertEq(adjusted.amount1(), hook.lastAmount1() + h, "unspecified leg must move by exactly H");
        } else {
            assertEq(ret, abi.encodeWithSelector(PoolErrors.HookDeltaCapExceeded.selector));
        }
    }

    /// @notice Forge mirror of check_hookDeltaSplitConservation.
    function testFuzz_hookDeltaSplitConservation(uint256 haircutRaw, uint16 lpBpsRaw, uint16 protocolBpsRaw)
        public
        view
    {
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
    }

    /// @notice Forge mirror of check_hookDeltaCapHeadroom: fuzz the hook
    /// return in a window around the cap (and below zero); success ⟺ H is
    /// within the cap, and the legs move exactly as specified. The cap is
    /// measured on the identical control pool, so it is exact for the hooked
    /// swap; the engine delta asserted against is the one the hook recorded
    /// on the hooked swap itself.
    function testFuzz_hookDeltaCapHeadroom(int128 hRaw) public {
        swapper.swap(controlKey, true, 1_000_000);
        int128 engineAmount1 = swapper.lastSwapDelta().amount1();
        uint256 cap = uint256(uint128(engineAmount1 < 0 ? -engineAmount1 : engineAmount1)) * 500 / 10_000;
        assertGt(cap, 0, "cap must be non-zero for the boundary fuzz");
        int128 h = int128(int256(hRaw) % int256(cap + 2));
        hook.setDelta(h);
        if (h < 0 || uint256(uint128(h)) > cap) {
            vm.expectRevert(PoolErrors.HookDeltaCapExceeded.selector);
            swapper.swap(hookedKey, true, 1_000_000);
        } else {
            swapper.swap(hookedKey, true, 1_000_000);
            BalanceDelta adjusted = swapper.lastSwapDelta();
            assertEq(adjusted.amount0(), hook.lastAmount0(), "specified leg must stay exact");
            assertEq(adjusted.amount1(), hook.lastAmount1() + h, "unspecified leg must move by exactly H");
        }
    }
}
