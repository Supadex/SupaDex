// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";
import {Currency} from "../types/Currency.sol";

/**
 * @title IPoolEvents
 * @notice Interface containing all event declarations for SupaDex Pool operations.
 */
interface IPoolEvents {
    /**
     * @notice Emitted when a new pool is initialized.
     */
    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        address plugin,
        uint160 sqrtPriceX96,
        int24 tick
    );

    /**
     * @notice Emitted when liquidity is modified (added or removed).
     */
    event ModifyLiquidity(
        PoolId indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt
    );

    /**
     * @notice Emitted when a swap is executed.
     */
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    /**
     * @notice Emitted when tokens are donated directly to active liquidity providers.
     */
    event Donate(PoolId indexed id, address indexed sender, uint256 amount0, uint256 amount1);

    /**
     * @notice Emitted when dynamic fee is updated by a plugin or volatility engine.
     */
    event DynamicFeeUpdated(PoolId indexed id, uint24 oldFee, uint24 newFee);

    /**
     * @notice Emitted when a pool's protocol fee take rate is updated.
     */
    event ProtocolFeeUpdated(PoolId indexed id, uint24 protocolFee);

    /**
     * @notice Emitted when protocol fees are collected to a recipient.
     */
    event ProtocolFeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);
}
