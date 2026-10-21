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

contract AntiJITVestingPluginTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    AntiJITVestingPlugin internal plugin;
    PoolKey internal key;

    function setUp() public {
        manager = IPoolManager(address(this));
        plugin = new AntiJITVestingPlugin(manager, 4); // 4 blocks → mid-vest easy to assert

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(plugin),
            curveType: CurveType.CLAMM
        });
    }

    function test_addLiquidityRecordsResidency() public {
        bytes4 sel = plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 10_000, salt: bytes32(0)
            }),
            ""
        );

        assertEq(sel, plugin.beforeModifyLiquidity.selector);

        bytes32 posKey = keccak256(abi.encodePacked(address(0xA), int24(-120), int24(120), bytes32(0)));
        (uint32 lastBlock, uint32 lastTime, uint128 liq) = plugin.residencies(key.toId(), posKey);

        assertEq(lastBlock, uint32(block.number));
        assertEq(lastTime, uint32(block.timestamp));
        assertEq(liq, 10_000);
    }

    /// APUS-SUPADEX-014: a top-up restarts the residency clock (no liquidity-weighted averaging).
    function test_topUpResetsDepositBlock() public {
        uint32 start = uint32(block.number);
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 1000, salt: bytes32(0)
            }),
            ""
        );

        vm.roll(start + 10);
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 1000, salt: bytes32(0)
            }),
            ""
        );

        bytes32 posKey = keccak256(abi.encodePacked(address(0xA), int24(-120), int24(120), bytes32(0)));
        (uint32 lastBlock,, uint128 liq) = plugin.residencies(key.toId(), posKey);
        assertEq(lastBlock, start + 10);
        assertEq(liq, 2000);
    }

    function test_sameBlockRemovalHaircutsAllFees_notPrincipal() public {
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 10_000, salt: bytes32(0)
            }),
            ""
        );

        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -10_000, salt: bytes32(0)
            }),
            ""
        );

        BalanceDelta principal = toBalanceDelta(-1000, -2000);
        BalanceDelta fees = toBalanceDelta(100, 50);

        vm.expectEmit(true, true, true, true);
        emit IPluginEvents.JITPenaltyLevied(
            key.toId(),
            address(0xA),
            keccak256(abi.encodePacked(address(0xA), int24(-120), int24(120), bytes32(0))),
            150,
            0,
            4
        );

        (bytes4 sel, BalanceDelta hookDelta, BalanceDelta feesHook) = plugin.afterModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -10_000, salt: bytes32(0)
            }),
            principal,
            fees,
            ""
        );

        assertEq(sel, plugin.afterModifyLiquidity.selector);
        assertEq(BalanceDelta.unwrap(hookDelta), 0, "principal must not be haircut");
        assertEq(feesHook.amount0(), 100);
        assertEq(feesHook.amount1(), 50);
    }

    function test_midResidencyPartialFeeVest() public {
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 10_000, salt: bytes32(0)
            }),
            ""
        );

        vm.roll(block.number + 2); // elapsed=2, K=4 → 50% unvested
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -10_000, salt: bytes32(0)
            }),
            ""
        );

        (,, BalanceDelta feesHook) = plugin.afterModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -10_000, salt: bytes32(0)
            }),
            toBalanceDelta(-1000, 0),
            toBalanceDelta(1000, 0),
            ""
        );

        assertEq(feesHook.amount0(), 500);
        assertEq(feesHook.amount1(), 0);
    }

    function test_fullResidencyNoFeeHaircut() public {
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 10_000, salt: bytes32(0)
            }),
            ""
        );

        vm.roll(block.number + 4);
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -10_000, salt: bytes32(0)
            }),
            ""
        );

        (,, BalanceDelta feesHook) = plugin.afterModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -10_000, salt: bytes32(0)
            }),
            toBalanceDelta(-1000, 0),
            toBalanceDelta(1000, 0),
            ""
        );

        assertEq(BalanceDelta.unwrap(feesHook), 0);
    }

    function test_pokeAlsoAppliesVesting() public {
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 10_000, salt: bytes32(0)
            }),
            ""
        );

        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );

        (,, BalanceDelta feesHook) = plugin.afterModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 0, salt: bytes32(0)}),
            toBalanceDelta(0, 0),
            toBalanceDelta(200, 0),
            ""
        );

        assertEq(feesHook.amount0(), 200);
    }
}
