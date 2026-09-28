// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPlugin} from "../../interfaces/IPlugin.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {BalanceDelta} from "../../types/BalanceDelta.sol";
import {PluginErrors} from "../../errors/PluginErrors.sol";

/**
 * @title BaseHook
 * @notice Abstract base contract for native plugins and external hooks with built-in access control and default fallbacks.
 */
abstract contract BaseHook is IPlugin {
    /**
     * @notice Address of the singleton SupaPoolManager.
     */
    IPoolManager public immutable poolManager;

    /**
     * @dev Enforces that only the authorized SupaPoolManager can invoke hook callbacks.
     */
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert PluginErrors.NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /**
     * @inheritdoc IPlugin
     */
    function getPluginPermissions() public pure virtual override returns (uint32 permissions) {
        return 0;
    }

    /**
     * @inheritdoc IPlugin
     */
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        sender;
        key;
        sqrtPriceX96;
        return this.beforeInitialize.selector;
    }

    /**
     * @inheritdoc IPlugin
     */
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        sender;
        key;
        sqrtPriceX96;
        tick;
        return this.afterInitialize.selector;
    }

    /**
     * @inheritdoc IPlugin
     */
    function beforeModifyLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4) {
        sender;
        key;
        params;
        hookData;
        return this.beforeModifyLiquidity.selector;
    }

    /**
     * @inheritdoc IPlugin
     */
    function afterModifyLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4, BalanceDelta hookDelta) {
        sender;
        key;
        params;
        delta;
        hookData;
        return (this.afterModifyLiquidity.selector, BalanceDelta.wrap(0));
    }

    /**
     * @inheritdoc IPlugin
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4, uint24 overrideFee) {
        sender;
        key;
        params;
        hookData;
        return (this.beforeSwap.selector, 0);
    }

    /**
     * @inheritdoc IPlugin
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4, int128 hookDeltaSpecified) {
        sender;
        key;
        params;
        delta;
        hookData;
        return (this.afterSwap.selector, 0);
    }

    /**
     * @inheritdoc IPlugin
     */
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4) {
        sender;
        key;
        amount0;
        amount1;
        hookData;
        return this.beforeDonate.selector;
    }

    /**
     * @inheritdoc IPlugin
     */
    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external virtual override onlyPoolManager returns (bytes4) {
        sender;
        key;
        amount0;
        amount1;
        hookData;
        return this.afterDonate.selector;
    }
}
