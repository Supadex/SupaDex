// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";

/**
 * @title PoolErrors
 * @notice Library containing custom errors for pool state, liquidity, ticks, and swap execution.
 */
library PoolErrors {
    /**
     * @dev Thrown when attempting to initialize an already initialized pool.
     */
    error PoolAlreadyInitialized(PoolId id);

    /**
     * @dev Thrown when attempting an operation on an uninitialized pool.
     */
    error PoolNotInitialized(PoolId id);

    /**
     * @dev Thrown when currencies in PoolKey are not strictly ordered (currency0 >= currency1).
     */
    error CurrenciesOutOfOrderOrEqual();

    /**
     * @dev Thrown when the tick spacing is zero or negative or exceeds bounds.
     */
    error InvalidTickSpacing(int24 tickSpacing);

    /**
     * @dev Thrown when ticks are not divisible by tick spacing.
     */
    error TickNotSpaced(int24 tick, int24 tickSpacing);

    /**
     * @dev Thrown when lower tick is greater than or equal to upper tick.
     */
    error TicksMisordered(int24 tickLower, int24 tickUpper);

    /**
     * @dev Thrown when a tick is outside the valid mathematical bounds [-887272, 887272].
     */
    error TickOutOfBounds(int24 tick);

    /**
     * @dev Thrown when price limit specified in a swap is out of valid bounds.
     */
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    /**
     * @dev Thrown when price limit in swap has already been reached.
     */
    error PriceLimitAlreadyExceeded(uint160 currentPrice, uint160 sqrtPriceLimitX96);

    /**
     * @dev Thrown when liquidity added/removed causes arithmetic overflow.
     */
    error LiquidityOverflow();

    /**
     * @dev Thrown when swap specified zero amount.
     */
    error ZeroSwapAmount();

    /**
     * @dev Thrown when swap output is less than minimum specified or input exceeds maximum.
     */
    error SlippageExceeded();

    /**
     * @dev Thrown when protocol fee exceeds the maximum take rate.
     */
    error InvalidProtocolFee(uint24 protocolFee);

    /**
     * @dev Thrown when the caller is not the protocol fee controller.
     */
    error InvalidProtocolFeeController();

    /**
     * @dev Thrown when a pool plugin is not on the whitelist.
     */
    error PluginNotWhitelisted(address plugin);
}
