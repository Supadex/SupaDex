// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AntiJITVestingPlugin} from "../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {IPluginEvents} from "../../contract/events/IPluginEvents.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract AntiJITVestingPluginTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    AntiJITVestingPlugin internal plugin;
    PoolKey internal key;

    function setUp() public {
        manager = IPoolManager(address(this));
        plugin = new AntiJITVestingPlugin(manager, 3); // 3 blocks residency

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
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10_000,
                salt: bytes32(0)
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

    function test_sameBlockWithdrawalTriggersJITPenaltyEvent() public {
        // Add liquidity
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10_000,
                salt: bytes32(0)
            }),
            ""
        );

        // Immediate removal in the same block (JIT attack)
        // Should trigger JITPenaltyLevied event
        vm.expectEmit(true, true, true, false);
        emit IPluginEvents.JITPenaltyLevied(
            key.toId(),
            address(0xA),
            keccak256(abi.encodePacked(address(0xA), int24(-120), int24(120), bytes32(0))),
            5000, // 50% penalty on 10,000
            0,
            3
        );

        bytes4 sel = plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -10_000,
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(sel, plugin.beforeModifyLiquidity.selector);
    }

    function test_honestLPWithdrawalAfterResidencyPasses() public {
        // Add liquidity at block N
        plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10_000,
                salt: bytes32(0)
            }),
            ""
        );

        // Advance 5 blocks (> 3 min blocks)
        vm.roll(block.number + 5);

        // Withdraw liquidity - no penalty event expected
        bytes4 sel = plugin.beforeModifyLiquidity(
            address(0xA),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -10_000,
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(sel, plugin.beforeModifyLiquidity.selector);
    }
}
