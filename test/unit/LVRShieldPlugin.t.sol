// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {VolatilityTWAPOracle} from "../../contract/plugins/native/VolatilityTWAPOracle.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {ISupaRoles} from "../../contract/interfaces/ISupaRoles.sol";
import {SupaRoles} from "../../contract/governance/SupaRoles.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";

contract LVRShieldPluginTest is Test {
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;

    IPoolManager internal manager;
    VolatilityTWAPOracle internal oracle;
    LVRShieldPlugin internal plugin;
    SupaRoles internal roles;
    PoolKey internal key;

    Slot0 internal mockSlot0;
    uint128 internal mockLiquidity = 1_000_000;

    function setUp() public {
        manager = IPoolManager(address(this)); // Mock manager as test contract
        plugin = new LVRShieldPlugin(manager);
        oracle = VolatilityTWAPOracle(address(plugin.oracle()));
        roles = new SupaRoles(address(this), address(this));
        plugin.setRoles(ISupaRoles(address(roles)));

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(plugin),
            curveType: CurveType.CLAMM
        });

        mockSlot0 = Slot0Library.pack(1 << 96, 0, 0, 3000, true);
        plugin.afterInitialize(address(this), key, 100, 0);
    }

    /// @dev Mock IPoolManager views used by afterSwap.
    function getSlot0(PoolId) external view returns (Slot0) {
        return mockSlot0;
    }

    function getLiquidity(PoolId) external view returns (uint128) {
        return mockLiquidity;
    }

    function test_afterInitializeSetsBaseState() public view {
        PoolId id = key.toId();
        (
            uint24 baseFee,
            uint24 lastFee,
            uint32 lastSwap,
            int24 lastTick,
            uint32 decayHalfLife,
            ,
            ,
            ,
            bool init
        ) = plugin.poolLVRStates(id);

        assertEq(baseFee, 3000);
        assertEq(lastFee, 3000);
        assertEq(lastSwap, uint32(block.timestamp));
        assertEq(lastTick, 0);
        assertEq(decayHalfLife, 12);
        assertTrue(init);
    }

    function test_afterInitializeGrowsOracleCardinality() public view {
        (,, uint16 cardinalityNext) = oracle.states(key.toId());
        assertEq(cardinalityNext, 64);
    }

    function test_beforeSwapAppliesDynamicFee() public {
        (bytes4 sel, uint24 dynamicFee) =
            plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 1000, 0), "");

        assertEq(sel, plugin.beforeSwap.selector);
        assertGe(dynamicFee, 3000);
    }

    function test_dynamicFeeDecaysOverTime() public {
        plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 1000, 0), "");

        vm.warp(block.timestamp + 48);

        (, uint24 decayedFee) = plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 1000, 0), "");
        assertEq(decayedFee, 3000);
    }

    function test_feeRisesAfterHighVolatility() public {
        PoolId id = key.toId();

        // Build observation history with a large tick jump over the 12s window.
        vm.warp(block.timestamp + 12);
        vm.prank(address(plugin));
        oracle.write(id, uint32(block.timestamp), 500, 1_000_000);

        (, uint24 elevatedFee) = plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 1000, 0), "");
        assertGt(elevatedFee, 3000, "fee should rise under high instantaneous volatility");
    }

    function test_afterSwapWritesPostSwapTickToOracle() public {
        PoolId id = key.toId();
        int24 postSwapTick = 240;
        mockSlot0 = Slot0Library.pack(1 << 96, postSwapTick, 0, 3000, true);

        vm.warp(block.timestamp + 1);
        plugin.afterSwap(address(this), key, IPoolManager.SwapParams(true, 1000, 0), BalanceDelta.wrap(0), "");

        assertEq(oracle.latestTicks(id), postSwapTick);
        (,,, int24 lastTick,,,,,) = plugin.poolLVRStates(id);
        assertEq(lastTick, postSwapTick);
    }

    function test_setDecayHalfLife() public {
        plugin.setDecayHalfLife(key, 24);
        PoolId id = key.toId();
        (,,,, uint32 decayHalfLife,,,,) = plugin.poolLVRStates(id);
        assertEq(decayHalfLife, 24);
    }

    function test_setDecayHalfLifeRevertsOnZero() public {
        vm.expectRevert(PluginErrors.InvalidDecayHalfLife.selector);
        plugin.setDecayHalfLife(key, 0);
    }

    function test_setMinFeeRevertsWhenAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidFeeBounds.selector, uint24(150_000), uint24(100_000)));
        // max is 100_000 by default; set min above it
        plugin.setMinFeeBps(key, 150_000);
    }

    function test_setMaxFeeRevertsWhenBelowMin() public {
        plugin.setMinFeeBps(key, 2000);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidFeeBounds.selector, uint24(2000), uint24(1000)));
        plugin.setMaxFeeBps(key, 1000);
    }

    function test_setDecayParametersRevertsOnInvalidBounds() public {
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidFeeBounds.selector, uint24(5000), uint24(1000)));
        plugin.setDecayParameters(key, 12, 50, 5000, 1000);
    }

    function test_settersRevertBeforeRolesWired() public {
        LVRShieldPlugin bare = new LVRShieldPlugin(manager);
        bare.afterInitialize(address(this), key, 100, 0);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.PluginPermissionDenied.selector, address(bare), uint32(0)));
        bare.setDecayHalfLife(key, 24);
    }
}
