// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AntiJITVestingPlugin} from "../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {IPluginEvents} from "../../contract/events/IPluginEvents.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../../contract/types/BalanceDelta.sol";

/// @dev I-06: the plugin's pending haircut travels via TRANSIENT storage, which only
/// survives NESTED calls under one top-level call. In Foundry, separate top-level
/// calls from the test contract each get a fresh transient context (verified with a
/// scratch tstore/tload repro: cross-top-level-call reads return 0, while nested
/// calls under one top-level call read the stored value). Production dispatches
/// before/after hooks inside one `modifyLiquidity` call, so this harness performs
/// the full before -> after round-trip in a single call, mirroring production.
/// Calling `plugin.beforeModifyLiquidity` / `afterModifyLiquidity` directly from
/// the test contract (separate top-level calls) CANNOT observe the transient value.
contract AntiJITModifyHarness {
    AntiJITVestingPlugin internal plugin;

    function setPlugin(AntiJITVestingPlugin _plugin) external {
        require(address(plugin) == address(0), "already set");
        plugin = _plugin;
    }

    /// before-only (residency recording / haircut staging), in one call.
    function before(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params)
        external
        returns (bytes4)
    {
        return plugin.beforeModifyLiquidity(sender, key, params, "");
    }

    /// Full before -> after modify round-trip in ONE call (production shape).
    function modify(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta principal,
        BalanceDelta fees
    ) external returns (bytes4 sel, BalanceDelta hookDelta, BalanceDelta feesHookDelta) {
        plugin.beforeModifyLiquidity(sender, key, params, "");
        (sel, hookDelta, feesHookDelta) = plugin.afterModifyLiquidity(sender, key, params, principal, fees, "");
    }
}

contract AntiJITVestingPluginTest is Test {
    using PoolIdLibrary for PoolKey;

    AntiJITModifyHarness internal harness;
    AntiJITVestingPlugin internal plugin;
    PoolKey internal key;

    function setUp() public {
        harness = new AntiJITModifyHarness();
        // The harness is the plugin's "pool manager" (onlyPoolManager caller).
        plugin = new AntiJITVestingPlugin(IPoolManager(address(harness)), 4); // 4 blocks → mid-vest easy to assert
        harness.setPlugin(plugin);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(plugin),
            curveType: CurveType.CLAMM
        });
    }

    function _addParams(int256 liq) internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: liq, salt: bytes32(0)});
    }

    function _posKey(address sender) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(sender, int24(-120), int24(120), bytes32(0)));
    }

    function test_addLiquidityRecordsResidency() public {
        bytes4 sel = harness.before(address(0xA), key, _addParams(10_000));

        assertEq(sel, plugin.beforeModifyLiquidity.selector);

        (uint32 lastBlock, uint32 lastTime, uint128 liq) = plugin.residencies(key.toId(), _posKey(address(0xA)));

        assertEq(lastBlock, uint32(block.number));
        assertEq(lastTime, uint32(block.timestamp));
        assertEq(liq, 10_000);
    }

    /// APUS-SUPADEX-014: a top-up restarts the residency clock (no liquidity-weighted averaging).
    function test_topUpResetsDepositBlock() public {
        uint32 start = uint32(block.number);
        harness.before(address(0xA), key, _addParams(1000));

        vm.roll(start + 10);
        harness.before(address(0xA), key, _addParams(1000));

        (uint32 lastBlock,, uint128 liq) = plugin.residencies(key.toId(), _posKey(address(0xA)));
        assertEq(lastBlock, start + 10);
        assertEq(liq, 2000);
    }

    function test_sameBlockRemovalHaircutsAllFees_notPrincipal() public {
        harness.before(address(0xA), key, _addParams(10_000));

        BalanceDelta principal = toBalanceDelta(-1000, -2000);
        BalanceDelta fees = toBalanceDelta(100, 50);

        vm.expectEmit(true, true, true, true);
        emit IPluginEvents.JITPenaltyLevied(key.toId(), address(0xA), _posKey(address(0xA)), 150, 0, 4);

        (bytes4 sel, BalanceDelta hookDelta, BalanceDelta feesHook) =
            harness.modify(address(0xA), key, _addParams(-10_000), principal, fees);

        assertEq(sel, plugin.afterModifyLiquidity.selector);
        assertEq(BalanceDelta.unwrap(hookDelta), 0, "principal must not be haircut");
        assertEq(feesHook.amount0(), 100);
        assertEq(feesHook.amount1(), 50);
    }

    function test_midResidencyPartialFeeVest() public {
        harness.before(address(0xA), key, _addParams(10_000));

        vm.roll(block.number + 2); // elapsed=2, K=4 → 50% unvested
        (,, BalanceDelta feesHook) =
            harness.modify(address(0xA), key, _addParams(-10_000), toBalanceDelta(-1000, 0), toBalanceDelta(1000, 0));

        assertEq(feesHook.amount0(), 500);
        assertEq(feesHook.amount1(), 0);
    }

    function test_fullResidencyNoFeeHaircut() public {
        harness.before(address(0xA), key, _addParams(10_000));

        vm.roll(block.number + 4);
        (,, BalanceDelta feesHook) =
            harness.modify(address(0xA), key, _addParams(-10_000), toBalanceDelta(-1000, 0), toBalanceDelta(1000, 0));

        assertEq(BalanceDelta.unwrap(feesHook), 0);
    }

    function test_pokeAlsoAppliesVesting() public {
        harness.before(address(0xA), key, _addParams(10_000));

        (,, BalanceDelta feesHook) = harness.modify(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 0, salt: bytes32(0)}),
            toBalanceDelta(0, 0),
            toBalanceDelta(200, 0)
        );

        assertEq(feesHook.amount0(), 200);
    }

    /// I-06: the pending haircut must live in transient storage only. After a
    /// `before` call stages a 100% (10_000 bps) haircut, the persistent-storage
    /// slot for the pending value must still read zero — nothing is written to
    /// persistent storage — while the in-flight value still reaches
    /// `afterModifyLiquidity` when before/after run in one call (production shape).
    function test_I06_pendingUnvestedBps_isTransient_notPersistent() public {
        harness.before(address(0xA), key, _addParams(10_000));
        // Same-block removal stages the full haircut (elapsed 0 of K=4 blocks),
        // with no after-hook in this call.
        harness.before(address(0xA), key, _addParams(-10_000));

        bytes32 slot = keccak256("supadex.antijit.pendingUnvestedBps");
        assertEq(vm.load(address(plugin), slot), bytes32(0), "pending bps must not be in persistent storage");

        (,, BalanceDelta feesHook) = harness.modify(
            address(0xA), key, _addParams(-10_000), toBalanceDelta(-1000, -2000), toBalanceDelta(100, 50)
        );
        assertEq(feesHook.amount0(), 100, "transient pending value must still reach afterModifyLiquidity");
        assertEq(feesHook.amount1(), 50);
    }
}
