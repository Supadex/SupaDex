// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";

/**
 * @title IVolatilityTWAPOracle
 * @notice Interface for the high-frequency volatility TWAP oracle ring buffer.
 */
interface IVolatilityTWAPOracle {
    /**
     * @notice Packed observation record stored in the circular ring buffer.
     */
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint112 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    /**
     * @notice State container for a pool's circular oracle buffer.
     */
    struct OracleState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /**
     * @notice Initializes oracle storage for a pool.
     */
    function initialize(PoolId poolId, uint32 blockTimestamp, int24 tick)
        external
        returns (uint16 index, uint16 cardinality);

    /**
     * @notice Appends or updates an observation in the pool's circular buffer.
     */
    function write(PoolId poolId, uint32 blockTimestamp, int24 tick, uint128 liquidity)
        external
        returns (uint16 indexUpdated, uint16 cardinalityUpdated);

    /**
     * @notice Expands observation ring buffer capacity.
     */
    function grow(PoolId poolId, uint16 newCardinalityNext) external returns (uint16 cardinalityNextUpdated);

    /**
     * @notice Returns cumulative tick and seconds-per-liquidity values looking back `secondsAgos`.
     */
    function observe(PoolId poolId, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint112[] memory secondsPerLiquidityCumulativeX128s);

    /**
     * @notice Calculates instantaneous tick volatility over a historical window.
     */
    function getInstantaneousVolatility(PoolId poolId, uint32 windowSeconds)
        external
        view
        returns (uint256 volatility);
}
