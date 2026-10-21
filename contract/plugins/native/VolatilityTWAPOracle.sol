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
     * @dev Sole authorized writer (typically LVRShieldPlugin). Bound at construction.
     */
    address public immutable writer;

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

    modifier onlyWriter() {
        if (msg.sender != writer) revert PluginErrors.NotOracleWriter();
        _;
    }

    /**
     * @notice Binds the sole oracle writer immutably (pass predicted LVR address at deploy).
     */
    constructor(address _writer) {
        if (_writer == address(0)) revert PluginErrors.NotOracleWriter();
        writer = _writer;
    }

    /**
     * @inheritdoc IVolatilityTWAPOracle
     */
    function initialize(PoolId poolId, uint32 blockTimestamp, int24 tick)
        external
        override
        onlyWriter
        returns (uint16 index, uint16 cardinality)
    {
        OracleState storage state = states[poolId];
        if (state.cardinality != 0) revert PluginErrors.InvalidCardinality();

        state.index = 0;
        state.cardinality = 1;
        state.cardinalityNext = 1;

        observations[poolId][0] = Observation({
            blockTimestamp: blockTimestamp, tickCumulative: 0, secondsPerLiquidityCumulativeX128: 0, initialized: true
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
        onlyWriter
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
        onlyWriter
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
     * @notice Realised tick movement over the trailing window: |latestTick − tick prevailing at (now − window)|,
     * normalised to a 12-second block (`|Δtick| · 12 / window`).
     * @dev ADR-0003. A constant tick yields 0 regardless of idle time. Returns 0 (neutral) when the oracle
     * has no history covering the window start.
     */
    function getInstantaneousVolatility(PoolId poolId, uint32 windowSeconds)
        external
        view
        override
        returns (uint256 volatility)
    {
        OracleState memory state = states[poolId];
        if (state.cardinality == 0) return 0;
        if (windowSeconds == 0) windowSeconds = 12;
        uint32 nowTs = uint32(block.timestamp);
        if (nowTs < windowSeconds) return 0;

        (bool ok, int24 startTick) = _prevailingTickAt(poolId, nowTs - windowSeconds, state);
        if (!ok) return 0;

        int256 diff = int256(latestTicks[poolId]) - int256(startTick);
        if (diff < 0) diff = -diff;
        volatility = (uint256(diff) * 12) / windowSeconds;
    }

    /**
     * @dev Tick that prevailed at `targetTime`. Between observations i and i+1 the prevailing tick is exactly
     * (cum[i+1] − cum[i]) / (t[i+1] − t[i]) because `write` accumulates the PREVIOUS latest tick.
     * At or after the newest observation the prevailing tick is `latestTicks` (correct extrapolation).
     */
    function _prevailingTickAt(PoolId poolId, uint32 targetTime, OracleState memory state)
        internal
        view
        returns (bool ok, int24 tick)
    {
        uint16 cardinality = state.cardinality;
        Observation memory newest = observations[poolId][state.index];
        if (targetTime >= newest.blockTimestamp) return (true, latestTicks[poolId]);

        uint16 oldestIndex = cardinality == 1 ? 0 : uint16((uint256(state.index) + 1) % cardinality);
        if (!observations[poolId][oldestIndex].initialized) oldestIndex = 0;
        if (targetTime < observations[poolId][oldestIndex].blockTimestamp) return (false, 0);

        // Largest logical index k (from oldest) with t[k] <= targetTime; k < last because target < newest.
        uint256 count = (uint256(state.index) + cardinality - oldestIndex) % cardinality + 1;
        uint256 lo = 0;
        uint256 hi = count - 1;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (observations[poolId][(oldestIndex + mid) % cardinality].blockTimestamp <= targetTime) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        Observation memory a = observations[poolId][(oldestIndex + lo) % cardinality];
        Observation memory b = observations[poolId][(oldestIndex + lo + 1) % cardinality];
        uint32 dt = b.blockTimestamp - a.blockTimestamp;
        if (dt == 0) return (false, 0);
        int56 dc = b.tickCumulative - a.tickCumulative;
        return (true, int24(dc / int56(uint56(dt))));
    }

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
            // Extrapolate past the newest observation with the tick that has prevailed since (ADR-0003).
            unchecked {
                tickCumulative = newest.tickCumulative + int56(latestTicks[poolId])
                    * int56(uint56(targetTime - newest.blockTimestamp));
            }
            return (tickCumulative, newest.secondsPerLiquidityCumulativeX128);
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
                        tickCumulative =
                            midObs.tickCumulative + (tickDiff * int56(uint56(offset))) / int56(uint56(timeDiff));

                        uint112 secDiff =
                            nextObs.secondsPerLiquidityCumulativeX128 - midObs.secondsPerLiquidityCumulativeX128;
                        secondsPerLiquidity =
                            midObs.secondsPerLiquidityCumulativeX128 + uint112((uint256(secDiff) * offset) / timeDiff);
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
