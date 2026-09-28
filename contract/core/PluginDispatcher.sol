// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPlugin} from "../interfaces/IPlugin.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {PluginErrors} from "../errors/PluginErrors.sol";

/**
 * @title PluginDispatcher
 * @notice Library providing zero-overhead routing for internal plugins and gas-bounded calling for external hooks.
 */
library PluginDispatcher {
    uint32 internal constant BEFORE_INITIALIZE_FLAG = 1 << 0;
    uint32 internal constant AFTER_INITIALIZE_FLAG = 1 << 1;
    uint32 internal constant BEFORE_MODIFY_LIQUIDITY_FLAG = 1 << 2;
    uint32 internal constant AFTER_MODIFY_LIQUIDITY_FLAG = 1 << 3;
    uint32 internal constant BEFORE_SWAP_FLAG = 1 << 4;
    uint32 internal constant AFTER_SWAP_FLAG = 1 << 5;
    uint32 internal constant BEFORE_DONATE_FLAG = 1 << 6;
    uint32 internal constant AFTER_DONATE_FLAG = 1 << 7;

    /**
     * @dev Gas stipend forwarded to external hooks.
     */
    uint256 internal constant HOOK_GAS_LIMIT = 500_000;

    /**
     * @notice Validates plugin permissions bitmask.
     */
    function hasPermission(address plugin, uint32 flag) internal view returns (bool) {
        if (plugin == address(0)) return false;
        try IPlugin(plugin).getPluginPermissions{gas: 20_000}() returns (uint32 permissions) {
            return (permissions & flag) == flag;
        } catch {
            return false;
        }
    }

    /**
     * @notice Dispatches beforeInitialize hook.
     */
    function dispatchBeforeInitialize(address plugin, address sender, PoolKey memory key, uint160 sqrtPriceX96)
        internal
    {
        if (plugin == address(0)) return;
        if (!hasPermission(plugin, BEFORE_INITIALIZE_FLAG)) return;

        bytes4 selector = IPlugin.beforeInitialize.selector;
        try IPlugin(plugin).beforeInitialize{gas: HOOK_GAS_LIMIT}(sender, key, sqrtPriceX96) returns (bytes4 res) {
            if (res != selector) revert PluginErrors.PluginCallFailed(plugin, selector, "");
        } catch (bytes memory reason) {
            revert PluginErrors.PluginCallFailed(plugin, selector, reason);
        }
    }

    /**
     * @notice Dispatches afterInitialize hook.
     */
    function dispatchAfterInitialize(
        address plugin,
        address sender,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal {
        if (plugin == address(0)) return;
        if (!hasPermission(plugin, AFTER_INITIALIZE_FLAG)) return;

        bytes4 selector = IPlugin.afterInitialize.selector;
        try IPlugin(plugin).afterInitialize{gas: HOOK_GAS_LIMIT}(sender, key, sqrtPriceX96, tick) returns (bytes4 res)
        {
            if (res != selector) revert PluginErrors.PluginCallFailed(plugin, selector, "");
        } catch (bytes memory reason) {
            revert PluginErrors.PluginCallFailed(plugin, selector, reason);
        }
    }

    /**
     * @notice Dispatches beforeModifyLiquidity hook.
     */
    function dispatchBeforeModifyLiquidity(
        address plugin,
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) internal {
        if (plugin == address(0)) return;
        if (!hasPermission(plugin, BEFORE_MODIFY_LIQUIDITY_FLAG)) return;

        bytes4 selector = IPlugin.beforeModifyLiquidity.selector;
        try IPlugin(plugin).beforeModifyLiquidity{gas: HOOK_GAS_LIMIT}(sender, key, params, hookData) returns (
            bytes4 res
        ) {
            if (res != selector) revert PluginErrors.PluginCallFailed(plugin, selector, "");
        } catch (bytes memory reason) {
            revert PluginErrors.PluginCallFailed(plugin, selector, reason);
        }
    }

    /**
     * @notice Dispatches afterModifyLiquidity hook.
     */
    function dispatchAfterModifyLiquidity(
        address plugin,
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) internal returns (BalanceDelta hookDelta) {
        if (plugin == address(0)) return hookDelta;
        if (!hasPermission(plugin, AFTER_MODIFY_LIQUIDITY_FLAG)) return hookDelta;

        bytes4 selector = IPlugin.afterModifyLiquidity.selector;
        try IPlugin(plugin).afterModifyLiquidity{gas: HOOK_GAS_LIMIT}(sender, key, params, delta, hookData) returns (
            bytes4 res, BalanceDelta returnedDelta
        ) {
            if (res != selector) revert PluginErrors.PluginCallFailed(plugin, selector, "");
            hookDelta = returnedDelta;
        } catch (bytes memory reason) {
            revert PluginErrors.PluginCallFailed(plugin, selector, reason);
        }
    }

    /**
     * @notice Dispatches beforeSwap hook.
     */
    function dispatchBeforeSwap(
        address plugin,
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData
    ) internal returns (uint24 overrideFee) {
        if (plugin == address(0)) return 0;
        if (!hasPermission(plugin, BEFORE_SWAP_FLAG)) return 0;

        bytes4 selector = IPlugin.beforeSwap.selector;
        try IPlugin(plugin).beforeSwap{gas: HOOK_GAS_LIMIT}(sender, key, params, hookData) returns (
            bytes4 res, uint24 fee
        ) {
            if (res != selector) revert PluginErrors.PluginCallFailed(plugin, selector, "");
            overrideFee = fee;
        } catch (bytes memory reason) {
            revert PluginErrors.PluginCallFailed(plugin, selector, reason);
        }
    }

    /**
     * @notice Dispatches afterSwap hook.
     */
    function dispatchAfterSwap(
        address plugin,
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) internal returns (int128 hookDeltaSpecified) {
        if (plugin == address(0)) return 0;
        if (!hasPermission(plugin, AFTER_SWAP_FLAG)) return 0;

        bytes4 selector = IPlugin.afterSwap.selector;
        try IPlugin(plugin).afterSwap{gas: HOOK_GAS_LIMIT}(sender, key, params, delta, hookData) returns (
            bytes4 res, int128 returnedDelta
        ) {
            if (res != selector) revert PluginErrors.PluginCallFailed(plugin, selector, "");
            hookDeltaSpecified = returnedDelta;
        } catch (bytes memory reason) {
            revert PluginErrors.PluginCallFailed(plugin, selector, reason);
        }
    }

    /**
     * @notice Dispatches beforeDonate hook.
     */
    function dispatchBeforeDonate(
        address plugin,
        address sender,
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes memory hookData
    ) internal {
        if (plugin == address(0)) return;
        if (!hasPermission(plugin, BEFORE_DONATE_FLAG)) return;

        bytes4 selector = IPlugin.beforeDonate.selector;
        try IPlugin(plugin).beforeDonate{gas: HOOK_GAS_LIMIT}(sender, key, amount0, amount1, hookData) returns (
            bytes4 res
        ) {
            if (res != selector) revert PluginErrors.PluginCallFailed(plugin, selector, "");
        } catch (bytes memory reason) {
            revert PluginErrors.PluginCallFailed(plugin, selector, reason);
        }
    }

    /**
     * @notice Dispatches afterDonate hook.
     */
    function dispatchAfterDonate(
        address plugin,
        address sender,
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes memory hookData
    ) internal {
        if (plugin == address(0)) return;
        if (!hasPermission(plugin, AFTER_DONATE_FLAG)) return;

        bytes4 selector = IPlugin.afterDonate.selector;
        try IPlugin(plugin).afterDonate{gas: HOOK_GAS_LIMIT}(sender, key, amount0, amount1, hookData) returns (
            bytes4 res
        ) {
            if (res != selector) revert PluginErrors.PluginCallFailed(plugin, selector, "");
        } catch (bytes memory reason) {
            revert PluginErrors.PluginCallFailed(plugin, selector, reason);
        }
    }
}
