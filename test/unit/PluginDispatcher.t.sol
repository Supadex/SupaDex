// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PluginDispatcher} from "../../contract/core/PluginDispatcher.sol";
import {IPlugin} from "../../contract/interfaces/IPlugin.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";

contract MockPlugin is IPlugin {
    uint32 public permissions;
    bool public shouldRevert;
    bytes4 public invalidReturnSelector;
    uint24 public feeOverride;

    constructor(uint32 _permissions) {
        permissions = _permissions;
    }

    function setPermissions(uint32 _permissions) external {
        permissions = _permissions;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setInvalidReturnSelector(bytes4 _selector) external {
        invalidReturnSelector = _selector;
    }

    function setFeeOverride(uint24 _fee) external {
        feeOverride = _fee;
    }

    function getPluginPermissions() external view override returns (uint32) {
        return permissions;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external view override returns (bytes4) {
        if (shouldRevert) revert("PluginRevert");
        if (invalidReturnSelector != bytes4(0)) return invalidReturnSelector;
        return IPlugin.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view override returns (bytes4) {
        if (shouldRevert) revert("PluginRevert");
        if (invalidReturnSelector != bytes4(0)) return invalidReturnSelector;
        return IPlugin.afterInitialize.selector;
    }

    function beforeModifyLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (shouldRevert) revert("PluginRevert");
        if (invalidReturnSelector != bytes4(0)) return invalidReturnSelector;
        return IPlugin.beforeModifyLiquidity.selector;
    }

    function afterModifyLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override returns (bytes4, BalanceDelta, BalanceDelta) {
        if (shouldRevert) revert("PluginRevert");
        if (invalidReturnSelector != bytes4(0)) {
            return (invalidReturnSelector, toBalanceDelta(0, 0), toBalanceDelta(0, 0));
        }
        return (IPlugin.afterModifyLiquidity.selector, toBalanceDelta(10, 20), toBalanceDelta(0, 0));
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        override
        returns (bytes4, uint24)
    {
        if (shouldRevert) revert("PluginRevert");
        if (invalidReturnSelector != bytes4(0)) return (invalidReturnSelector, 0);
        return (IPlugin.beforeSwap.selector, feeOverride);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        returns (bytes4, int128)
    {
        if (shouldRevert) revert("PluginRevert");
        if (invalidReturnSelector != bytes4(0)) return (invalidReturnSelector, 0);
        return (IPlugin.afterSwap.selector, 100);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (shouldRevert) revert("PluginRevert");
        if (invalidReturnSelector != bytes4(0)) return invalidReturnSelector;
        return IPlugin.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (shouldRevert) revert("PluginRevert");
        if (invalidReturnSelector != bytes4(0)) return invalidReturnSelector;
        return IPlugin.afterDonate.selector;
    }
}

contract RevertingPermsPlugin {
    function getPluginPermissions() external pure returns (uint32) {
        revert("nope");
    }
}

contract PluginDispatcherTest is Test {
    MockPlugin public plugin;
    PoolKey public key;

    function setUp() public {
        plugin = new MockPlugin(0xFF); // all permissions enabled
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(plugin),
            curveType: CurveType.CLAMM
        });
    }

    function test_zeroAddressPluginNoOp() public {
        PluginDispatcher.dispatchBeforeInitialize(address(0), 0, address(this), key, 1 << 96);
        PluginDispatcher.dispatchAfterInitialize(address(0), 0, address(this), key, 1 << 96, 0);
        uint24 fee = PluginDispatcher.dispatchBeforeSwap(
            address(0), 0, address(this), key, IPoolManager.SwapParams(true, 100, 0), ""
        );
        assertEq(fee, 0);
    }

    function test_permissionChecks() public {
        // Plugin with no permissions (0)
        plugin.setPermissions(0);
        PluginDispatcher.dispatchBeforeInitialize(address(plugin), plugin.permissions(), address(this), key, 1 << 96);
        uint24 fee = PluginDispatcher.dispatchBeforeSwap(
            address(plugin), plugin.permissions(), address(this), key, IPoolManager.SwapParams(true, 100, 0), ""
        );
        assertEq(fee, 0);
    }

    function test_dispatchLifecycleSuccess() public {
        plugin.setFeeOverride(5000);
        PluginDispatcher.dispatchBeforeInitialize(address(plugin), plugin.permissions(), address(this), key, 1 << 96);
        PluginDispatcher.dispatchAfterInitialize(address(plugin), plugin.permissions(), address(this), key, 1 << 96, 0);

        uint24 fee = PluginDispatcher.dispatchBeforeSwap(
            address(plugin), plugin.permissions(), address(this), key, IPoolManager.SwapParams(true, 100, 0), ""
        );
        assertEq(fee, 5000);

        int128 hookDelta = PluginDispatcher.dispatchAfterSwap(
            address(plugin),
            plugin.permissions(),
            address(this),
            key,
            IPoolManager.SwapParams(true, 100, 0),
            toBalanceDelta(10, 20),
            ""
        );
        assertEq(hookDelta, 100);
    }

    function test_pluginRevertThrows() public {
        plugin.setShouldRevert(true);
        vm.expectRevert();
        this.callBeforeInit();
    }

    /// A plugin changing its own permissions after caching has no effect on dispatch.
    function test_cachedPermissionsIgnorePluginChanges() public {
        plugin.setPermissions(0);
        uint32 cached = this.readPerms(address(plugin)); // 0 at "initialize"
        plugin.setPermissions(0xFF);
        plugin.setFeeOverride(9999);
        uint24 fee = PluginDispatcher.dispatchBeforeSwap(
            address(plugin), cached, address(this), key, IPoolManager.SwapParams(true, 100, 0), ""
        );
        assertEq(fee, 0);
    }

    function test_readPermissionsFailsClosed() public {
        RevertingPermsPlugin bad = new RevertingPermsPlugin();
        vm.expectRevert();
        this.readPerms(address(bad));
        assertEq(this.readPerms(address(0)), 0);
        assertEq(this.readPerms(address(plugin)), 0xFF);
    }

    function callBeforeInit() external {
        PluginDispatcher.dispatchBeforeInitialize(address(plugin), uint32(0xFF), address(this), key, 1 << 96);
    }

    function readPerms(address p) external view returns (uint32) {
        return PluginDispatcher.readPermissions(p);
    }

    function test_invalidReturnSelectorThrows() public {
        plugin.setInvalidReturnSelector(bytes4(0x12345678));
        vm.expectRevert();
        this.callBeforeInit();
    }
}
