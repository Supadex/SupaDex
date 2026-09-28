// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseHook} from "../../contract/plugins/external/BaseHook.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";

contract TestHookImplementation is BaseHook {
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getPluginPermissions() public pure override returns (uint32) {
        return 0xFFFFFFFF; // Activate all for testing base callbacks
    }
}

contract BaseHookTest is Test {
    IPoolManager internal manager;
    TestHookImplementation internal hook;
    PoolKey internal key;

    function setUp() public {
        manager = IPoolManager(address(0x1234));
        hook = new TestHookImplementation(manager);
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(hook),
            curveType: CurveType.CLAMM
        });
    }

    function test_onlyPoolManagerRevertsForUnauthorizedCallers() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(PluginErrors.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, 100);

        vm.prank(address(0xDEAD));
        vm.expectRevert(PluginErrors.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, 100, 0);

        vm.prank(address(0xDEAD));
        vm.expectRevert(PluginErrors.NotPoolManager.selector);
        hook.beforeModifyLiquidity(address(this), key, IPoolManager.ModifyLiquidityParams(0, 0, 0, bytes32(0)), "");

        vm.prank(address(0xDEAD));
        vm.expectRevert(PluginErrors.NotPoolManager.selector);
        hook.afterModifyLiquidity(
            address(this), key, IPoolManager.ModifyLiquidityParams(0, 0, 0, bytes32(0)), BalanceDelta.wrap(0), ""
        );

        vm.prank(address(0xDEAD));
        vm.expectRevert(PluginErrors.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 100, 0), "");

        vm.prank(address(0xDEAD));
        vm.expectRevert(PluginErrors.NotPoolManager.selector);
        hook.afterSwap(address(this), key, IPoolManager.SwapParams(true, 100, 0), BalanceDelta.wrap(0), "");

        vm.prank(address(0xDEAD));
        vm.expectRevert(PluginErrors.NotPoolManager.selector);
        hook.beforeDonate(address(this), key, 100, 100, "");

        vm.prank(address(0xDEAD));
        vm.expectRevert(PluginErrors.NotPoolManager.selector);
        hook.afterDonate(address(this), key, 100, 100, "");
    }

    function test_authorizedPoolManagerCallbacksSucceed() public {
        vm.startPrank(address(manager));

        bytes4 selBeforeInit = hook.beforeInitialize(address(this), key, 100);
        assertEq(selBeforeInit, hook.beforeInitialize.selector);

        bytes4 selAfterInit = hook.afterInitialize(address(this), key, 100, 0);
        assertEq(selAfterInit, hook.afterInitialize.selector);

        bytes4 selBeforeMod =
            hook.beforeModifyLiquidity(address(this), key, IPoolManager.ModifyLiquidityParams(0, 0, 0, bytes32(0)), "");
        assertEq(selBeforeMod, hook.beforeModifyLiquidity.selector);

        (bytes4 selAfterMod, BalanceDelta hookDelta) = hook.afterModifyLiquidity(
            address(this), key, IPoolManager.ModifyLiquidityParams(0, 0, 0, bytes32(0)), BalanceDelta.wrap(0), ""
        );
        assertEq(selAfterMod, hook.afterModifyLiquidity.selector);
        assertEq(BalanceDelta.unwrap(hookDelta), 0);

        (bytes4 selBeforeSwap, uint24 fee) =
            hook.beforeSwap(address(this), key, IPoolManager.SwapParams(true, 100, 0), "");
        assertEq(selBeforeSwap, hook.beforeSwap.selector);
        assertEq(fee, 0);

        (bytes4 selAfterSwap, int128 hookDeltaSpecified) =
            hook.afterSwap(address(this), key, IPoolManager.SwapParams(true, 100, 0), BalanceDelta.wrap(0), "");
        assertEq(selAfterSwap, hook.afterSwap.selector);
        assertEq(hookDeltaSpecified, 0);

        bytes4 selBeforeDonate = hook.beforeDonate(address(this), key, 100, 100, "");
        assertEq(selBeforeDonate, hook.beforeDonate.selector);

        bytes4 selAfterDonate = hook.afterDonate(address(this), key, 100, 100, "");
        assertEq(selAfterDonate, hook.afterDonate.selector);

        vm.stopPrank();
    }
}
