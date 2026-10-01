// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {VolatilityTWAPOracle} from "../../contract/plugins/native/VolatilityTWAPOracle.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract LVRShieldPluginTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    VolatilityTWAPOracle internal oracle;
    LVRShieldPlugin internal plugin;
    PoolKey internal key;

    function setUp() public {
        manager = IPoolManager(address(this)); // Mock manager as test contract
        oracle = new VolatilityTWAPOracle();
        plugin = new LVRShieldPlugin(manager, oracle);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(plugin),
            curveType: CurveType.CLAMM
        });

        // Initialize pool in plugin
        plugin.afterInitialize(address(this), key, 100, 0);
    }

    function test_afterInitializeSetsBaseState() public {
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
        ) =
            plugin.poolLVRStates(id);

        assertEq(baseFee, 3000);
        assertEq(lastFee, 3000);
        assertEq(lastSwap, uint32(block.timestamp));
        assertEq(lastTick, 0);
        assertEq(decayHalfLife, 12);
        assertTrue(init);
    }

    function test_beforeSwapAppliesDynamicFee() public {
        // First swap at time 0
        (bytes4 sel, uint24 dynamicFee) =
            plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 1000, 0), "");

        assertEq(sel, plugin.beforeSwap.selector);
        assertGe(dynamicFee, 3000); // Dynamic fee >= base fee
    }

    function test_dynamicFeeDecaysOverTime() public {
        // Artificially elevate dynamic fee
        plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 1000, 0), "");

        // Advance time by 48 seconds (4 decay half-lives)
        vm.warp(block.timestamp + 48);

        (, uint24 decayedFee) = plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 1000, 0), "");

        // After multiple half lives, fee decays back to baseline
        assertEq(decayedFee, 3000);
    }

    function test_setDecayHalfLife() public {
        plugin.setDecayHalfLife(key, 24);
        PoolId id = key.toId();
        (,,,, uint32 decayHalfLife,,,,) = plugin.poolLVRStates(id);
        assertEq(decayHalfLife, 24);
    }
}
