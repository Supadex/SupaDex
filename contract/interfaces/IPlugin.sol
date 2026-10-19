// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "../types/PoolKey.sol";
import {PoolId} from "../types/PoolId.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {IPoolManager} from "./IPoolManager.sol";

/**
 * @title IPlugin
 * @notice Lifecycle interface for SupaDex native plugins and external hooks.
 */
interface IPlugin {
    /**
     * @notice Permission bitflags determining which lifecycle callbacks are activated.
     */
    function getPluginPermissions() external view returns (uint32 permissions);

    /**
     * @notice Hook called before pool initialization.
     */
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);

    /**
     * @notice Hook called after pool initialization.
     */
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4);

    /**
     * @notice Hook called before modifying liquidity.
     */
    function beforeModifyLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);

    /**
     * @notice Hook called after modifying liquidity.
     * @param delta Principal balance delta from the engine (excludes feesAccrued).
     * @param feesAccrued Fees owed to the position from fee growth (non-negative legs).
     * @return hookDelta Principal haircut (credit-only, non-negative on credit legs).
     * @return feesHookDelta Unvested fee share to confiscate (0 <= feesHookDelta <= feesAccrued per leg).
     */
    function afterModifyLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta, BalanceDelta);

    /**
     * @notice Hook called before executing a swap.
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, uint24 overrideFee);

    /**
     * @notice Hook called after executing a swap.
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128 hookDeltaSpecified);

    /**
     * @notice Hook called before a donation.
     */
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);

    /**
     * @notice Hook called after a donation.
     */
    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);
}
