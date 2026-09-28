// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVolatilityTWAPOracle} from "../../interfaces/IVolatilityTWAPOracle.sol";
import {PoolId} from "../../types/PoolId.sol";
import {PluginErrors} from "../../errors/PluginErrors.sol";

/**
 * @title VolatilityTWAPOracle
 * @notice Circular ring buffer tracking cumulative ticks, liquidity, and instantaneous volatility.
 */
contract VolatilityTWAPOracle is IVolatilityTWAPOracle {
    /**
     * @dev Observations ring buffer per pool: poolId => index => Observation
     */
    mapping(PoolId => mapping(uint256 => Observation)) public observations;

    /**
     * @dev Oracle metadata state per pool: poolId => OracleState
     */
    mapping(PoolId => OracleState) public states;

    /**
     * @dev Latest tick recorded per pool
     */
    mapping(PoolId => int24) public latestTicks;

    /**
     * @inheritdoc IVolatilityTWAPOracle
     */
    function initialize(PoolId poolId, uint32 blockTimestamp, int24 tick)
        external
        override
        returns (uint16 index, uint16 cardinality)
    {
        OracleState storage state = states[poolId];
        if (state.cardinality != 0) revert PluginErrors.InvalidCardinality();

        state.index = 0;
        state.cardinality = 1;
        state.cardinalityNext = 1;

        observations[poolId][0] = Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });

        latestTicks[poolId] = tick;

        return (0, 1);
    }

    /**
     * @inheritdoc IVolatilityTWAPOracle
     */
    function write(PoolId poolId, uint32 blockTimestamp, int24 tick, uint128 liquidity)
        external
        override
        returns (uint16 indexUpdated, uint16 cardinalityUpdated)
    {
        OracleState storage state = states[poolId];
        uint16 cardinality = state.cardinality;
        if (cardinality == 0) revert PluginErrors.OracleNotInitialized();

        uint16 currentIndex = state.index;
        Observation memory last = observations[poolId][currentIndex];

        // If written in same timestamp, just update latest tick
        if (last.blockTimestamp == blockTimestamp) {
            latestTicks[poolId] = tick;
            return (currentIndex, cardinality);
        }

        uint32 delta = blockTimestamp - last.blockTimestamp;
        int56 newTickCumulative;
        uint112 newSecondsPerLiquidity;
        unchecked {
            newTickCumulative = last.tickCumulative + int56(latestTicks[poolId]) * int56(uint56(delta));
            uint112 liquidityDelta = liquidity > 0 ? uint112((uint256(delta) << 128) / liquidity) : 0;
            newSecondsPerLiquidity = last.secondsPerLiquidityCumulativeX128 + liquidityDelta;
        }

        uint16 nextIndex = currentIndex + 1;
        uint16 cardinalityNext = state.cardinalityNext;

        if (cardinality < cardinalityNext) {
            cardinality = cardinality + 1;
            state.cardinality = cardinality;
        } else if (nextIndex >= cardinality) {
            nextIndex = 0;
        }

        state.index = nextIndex;
        observations[poolId][nextIndex] = Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: newTickCumulative,
            secondsPerLiquidityCumulativeX128: newSecondsPerLiquidity,
            initialized: true
        });

        latestTicks[poolId] = tick;
        return (nextIndex, cardinality);
    }

    /**
     * @inheritdoc IVolatilityTWAPOracle
     */
    function grow(PoolId poolId, uint16 newCardinalityNext)
        external
        override
        returns (uint16 cardinalityNextUpdated)
    {
        OracleState storage state = states[poolId];
        uint16 currentCardinality = state.cardinality;
        if (currentCardinality == 0) revert PluginErrors.OracleNotInitialized();
        if (newCardinalityNext <= state.cardinalityNext) revert PluginErrors.InvalidCardinality();

        state.cardinalityNext = newCardinalityNext;
        return newCardinalityNext;
    }

    /**
     * @inheritdoc IVolatilityTWAPOracle
     */
    function observe(PoolId poolId, uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives, uint112[] memory secondsPerLiquidityCumulativeX128s)
    {
        OracleState memory state = states[poolId];
        if (state.cardinality == 0) revert PluginErrors.OracleNotInitialized();

        uint256 length = secondsAgos.length;
        tickCumulatives = new int56[](length);
        secondsPerLiquidityCumulativeX128s = new uint112[](length);

        Observation memory last = observations[poolId][state.index];
        uint32 currentTimestamp = uint32(block.timestamp);

        for (uint256 i = 0; i < length; i++) {
            uint32 secondsAgo = secondsAgos[i];
            if (secondsAgo == 0) {
                if (last.blockTimestamp == currentTimestamp) {
                    tickCumulatives[i] = last.tickCumulative;
                    secondsPerLiquidityCumulativeX128s[i] = last.secondsPerLiquidityCumulativeX128;
                } else {
                    uint32 delta = currentTimestamp - last.blockTimestamp;
                    unchecked {
                        tickCumulatives[i] = last.tickCumulative + int56(latestTicks[poolId]) * int56(uint56(delta));
                    }
                    secondsPerLiquidityCumulativeX128s[i] = last.secondsPerLiquidityCumulativeX128;
                }
            } else {
                uint32 targetTime = currentTimestamp - secondsAgo;
                (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) =
                    _binarySearchAndInterpolate(poolId, targetTime, state);
            }
        }
    }

    /**
     * @inheritdoc IVolatilityTWAPOracle
     */
    function getInstantaneousVolatility(PoolId poolId, uint32 windowSeconds)
        external
        view
        override
        returns (uint256 volatility)
    {
        OracleState memory state = states[poolId];
        if (state.cardinality == 0) return 0;
        if (windowSeconds == 0) windowSeconds = 12; // 1 block default

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = windowSeconds;
        secondsAgos[1] = 0;

        try this.observe(poolId, secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint112[] memory
        ) {
            unchecked {
                int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
                int256 averageTick = tickDelta / int56(uint56(windowSeconds));
                int256 currentTick = int256(latestTicks[poolId]);

                int256 diff = currentTick > averageTick ? currentTick - averageTick : averageTick - currentTick;
                return uint256(diff);
            }
        } catch {
            return 0;
        }
    }

    /**
     * @dev Binary searches circular buffer and interpolates values for target timestamp.
     */
    function _binarySearchAndInterpolate(PoolId poolId, uint32 targetTime, OracleState memory state)
        internal
        view
        returns (int56 tickCumulative, uint112 secondsPerLiquidity)
    {
        uint16 cardinality = state.cardinality;
        uint16 oldestIndex = (state.index + 1) % cardinality;
        Observation memory oldest = observations[poolId][oldestIndex];

        if (!oldest.initialized) {
            oldestIndex = 0;
            oldest = observations[poolId][0];
        }

        Observation memory newest = observations[poolId][state.index];

        if (targetTime < oldest.blockTimestamp) revert PluginErrors.ObservationWindowTooOld();
        if (targetTime >= newest.blockTimestamp) {
            return (newest.tickCumulative, newest.secondsPerLiquidityCumulativeX128);
        }

        // Binary search
        uint256 l = 0;
        uint256 r = cardinality - 1;

        while (true) {
            uint256 mid = (l + r) / 2;
            uint256 midIndex = (oldestIndex + mid) % cardinality;
            Observation memory midObs = observations[poolId][midIndex];

            if (midObs.blockTimestamp <= targetTime) {
                uint256 nextIndex = (midIndex + 1) % cardinality;
                Observation memory nextObs = observations[poolId][nextIndex];

                if (targetTime < nextObs.blockTimestamp) {
                    // Linear interpolation between midObs and nextObs
                    uint32 timeDiff = nextObs.blockTimestamp - midObs.blockTimestamp;
                    uint32 offset = targetTime - midObs.blockTimestamp;

                    unchecked {
                        int56 tickDiff = nextObs.tickCumulative - midObs.tickCumulative;
                        tickCumulative = midObs.tickCumulative + (tickDiff * int56(uint56(offset))) / int56(uint56(timeDiff));

                        uint112 secDiff = nextObs.secondsPerLiquidityCumulativeX128 - midObs.secondsPerLiquidityCumulativeX128;
                        secondsPerLiquidity = midObs.secondsPerLiquidityCumulativeX128 + uint112((uint256(secDiff) * offset) / timeDiff);
                    }
                    return (tickCumulative, secondsPerLiquidity);
                }
                l = mid + 1;
            } else {
                r = mid - 1;
            }
        }
    }
}
