// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {SupaQuoter} from "../../contract/periphery/SupaQuoter.sol";
import {ISupaQuoter} from "../../contract/interfaces/ISupaQuoter.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {PluginDispatcher} from "../../contract/core/PluginDispatcher.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";
import {MockQuoterToken, QuoterLiquidityHelper} from "./SupaQuoter.t.sol";
import {MockPlugin} from "./PluginDispatcher.t.sol";

/// @notice remediation-3 / Gideon items 2–4: CallSalt event, curveType in Initialize, quoter applied fee.
contract FrontendInterfacesTest is Test {
    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        address plugin,
        uint160 sqrtPriceX96,
        int24 tick,
        uint8 curveType
    );
    event CallSalt(bytes32 indexed id, bytes32 salt);

    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    SupaVault vault;
    SupaPoolManager manager;
    SupaQuoter quoter;
    QuoterLiquidityHelper lp;
    MockPlugin feePlugin;
    Currency c0;
    Currency c1;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        vault.setPoolManager(address(manager), true);
        feePlugin = new MockPlugin(PluginDispatcher.BEFORE_SWAP_FLAG);
        address[] memory plugins = new address[](1);
        plugins[0] = address(feePlugin);
        manager.setPluginWhitelist(IPluginWhitelist(address(new PluginWhitelist(address(this), plugins))));
        quoter = new SupaQuoter(manager, vault);
        lp = new QuoterLiquidityHelper(vault, manager);
        MockQuoterToken a = new MockQuoterToken("A", "A");
        MockQuoterToken b = new MockQuoterToken("B", "B");
        if (address(a) > address(b)) (a, b) = (b, a);
        c0 = Currency.wrap(address(a));
        c1 = Currency.wrap(address(b));
        a.mint(address(lp), 1e30);
        b.mint(address(lp), 1e30);
    }

    function _key(address plugin, CurveType ct, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: spacing, plugin: plugin, curveType: ct});
    }

    function _clammPool(address plugin) internal returns (PoolKey memory k) {
        k = _key(plugin, CurveType.CLAMM, 60);
        manager.initialize(k, SQRT_1_1, "");
        lp.addLiquidity(k, -1200, 1200, 100_000 ether);
    }

    function _in(PoolKey memory k, uint128 amt) internal pure returns (ISupaQuoter.QuoteExactInputSingleParams memory) {
        return ISupaQuoter.QuoteExactInputSingleParams({
            poolKey: k, zeroForOne: true, amountIn: amt, sqrtPriceLimitX96: 0, hookData: ""
        });
    }

    function _out(PoolKey memory k, uint128 amt)
        internal
        pure
        returns (ISupaQuoter.QuoteExactOutputSingleParams memory)
    {
        return ISupaQuoter.QuoteExactOutputSingleParams({
            poolKey: k, zeroForOne: true, amountOut: amt, sqrtPriceLimitX96: 0, hookData: ""
        });
    }

    // ---- item 4: quoter applied fee ----

    function test_quoteWithFee_staticFeeMatchesLegacy() public {
        PoolKey memory k = _clammPool(address(0));
        (uint256 o1, uint160 s1, int24 t1) = quoter.quoteExactInputSingle(_in(k, 1 ether));
        (uint256 o2, uint160 s2, int24 t2, uint24 fee) = quoter.quoteExactInputSingleWithFee(_in(k, 1 ether));
        assertEq(o1, o2);
        assertEq(s1, s2);
        assertEq(t1, t2);
        assertEq(fee, 3000, "key.fee applied when plugin returns 0");
        (uint256 i1,,) = quoter.quoteExactOutputSingle(_out(k, 1 ether));
        (uint256 i2,,, uint24 feeOut) = quoter.quoteExactOutputSingleWithFee(_out(k, 1 ether));
        assertEq(i1, i2);
        assertEq(feeOut, 3000);
    }

    function test_quoteWithFee_pluginOverrideReported() public {
        PoolKey memory k = _clammPool(address(feePlugin));
        feePlugin.setFeeOverride(7777);
        (uint256 outDyn,,, uint24 fee) = quoter.quoteExactInputSingleWithFee(_in(k, 1 ether));
        assertEq(fee, 7777, "plugin dynamic fee reported");
        (,,, uint24 feeOut) = quoter.quoteExactOutputSingleWithFee(_out(k, 1 ether));
        assertEq(feeOut, 7777);
        // Slot0.dynamicFee is the static key.fee; documents why the UI must not use it as "the fee".
        assertEq(manager.getSlot0(k.toId()).dynamicFee(), 3000);
        feePlugin.setFeeOverride(0);
        (uint256 outStatic,,, uint24 fee0) = quoter.quoteExactInputSingleWithFee(_in(k, 1 ether));
        assertEq(fee0, 3000);
        assertGt(outStatic, outDyn, "higher fee -> less out");
    }

    function test_quoteWithFee_bubblesPoolErrors() public {
        PoolKey memory k = _key(address(0), CurveType.CLAMM, 60); // not initialized
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PoolNotInitialized.selector, k.toId()));
        quoter.quoteExactInputSingleWithFee(_in(k, 1 ether));
    }

    function test_lastSwapFee_zeroOutsideSwap() public view {
        assertEq(manager.lastSwapFee(), 0);
    }

    function test_quoteWithFee_stateUnchanged() public {
        PoolKey memory k = _clammPool(address(feePlugin));
        feePlugin.setFeeOverride(5000);
        uint256 before = uint256(keccak256(abi.encode(manager.getSlot0(k.toId()), manager.getLiquidity(k.toId()))));
        quoter.quoteExactInputSingleWithFee(_in(k, 10 ether));
        assertEq(uint256(keccak256(abi.encode(manager.getSlot0(k.toId()), manager.getLiquidity(k.toId())))), before);
    }

    // ---- item 3: curveType in Initialize ----

    function test_initializeEmitsCurveType_CLAMM() public {
        PoolKey memory k = _key(address(0), CurveType.CLAMM, 60);
        vm.expectEmit(true, true, true, true, address(manager));
        emit Initialize(k.toId(), c0, c1, 3000, 60, address(0), SQRT_1_1, 0, 0);
        manager.initialize(k, SQRT_1_1, "");
    }

    function test_initializeEmitsCurveType_STABLE() public {
        PoolKey memory k = _key(address(0), CurveType.STABLE_AMM, 1);
        vm.recordLogs();
        manager.initializeWithParams(k, SQRT_1_1, abi.encode(uint256(100)), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == Initialize.selector) {
                assertEq(logs[i].topics[1], PoolId.unwrap(k.toId()));
                (,,,,, uint8 ct) = abi.decode(logs[i].data, (uint24, int24, address, uint160, int24, uint8));
                assertEq(ct, uint8(CurveType.STABLE_AMM));
                found = true;
            }
        }
        assertTrue(found, "Initialize log");
    }

    // ---- item 2: timelock CallSalt ----

    function test_timelockEmitsCallSalt() public {
        address[] memory p = new address[](1);
        p[0] = address(this);
        address[] memory e = new address[](1);
        e[0] = address(0xE);
        SupaTimelock tl = new SupaTimelock(1 hours, address(0xA), p, e, p);
        bytes32 salt = keccak256("frontend-salt");
        bytes memory data = abi.encodeWithSignature("updateDelay(uint256)", 2 hours);
        bytes32 id = tl.hashOperation(address(tl), 0, data, bytes32(0), salt);
        vm.expectEmit(true, false, false, true, address(tl));
        emit CallSalt(id, salt);
        tl.schedule(address(tl), 0, data, bytes32(0), salt, 1 hours);
    }

    function test_timelockExpiredView() public {
        address[] memory p = new address[](1);
        p[0] = address(this);
        address[] memory e = new address[](1);
        e[0] = address(0xE);
        SupaTimelock tl = new SupaTimelock(1 hours, address(0xA), p, e, p);
        bytes memory data = abi.encodeWithSignature("updateDelay(uint256)", 2 hours);
        bytes32 id = tl.hashOperation(address(tl), 0, data, bytes32(0), bytes32(0));
        assertFalse(tl.isOperationExpired(id));
        tl.schedule(address(tl), 0, data, bytes32(0), bytes32(0), 1 hours);
        vm.warp(block.timestamp + 1 hours + tl.GRACE_PERIOD());
        assertFalse(tl.isOperationExpired(id), "last second of the window is still Ready");
        vm.warp(block.timestamp + 1);
        assertTrue(tl.isOperationExpired(id));
        assertEq(uint8(tl.getOperationState(id)), 0, "state reads Unset once expired");
    }
}
