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
        if (state.cardinality == 0) revert PluginErrors.OracleNotInitialized();

        uint16 currentIndex = state.index;
        // If written in same timestamp, just update latest tick
        if (observations[poolId][currentIndex].blockTimestamp == blockTimestamp) {
            latestTicks[poolId] = tick;
            return (currentIndex, state.cardinality);
        }

        (indexUpdated, cardinalityUpdated) = _advance(state, currentIndex, state.cardinality);
        observations[poolId][indexUpdated] =
            _transform(observations[poolId][currentIndex], blockTimestamp, latestTicks[poolId], liquidity);
        latestTicks[poolId] = tick;
    }

    /// @dev Ring-buffer index advance (grows cardinality toward cardinalityNext first).
    function _advance(OracleState storage state, uint16 currentIndex, uint16 cardinality)
        internal
        returns (uint16 nextIndex, uint16 newCardinality)
    {
        nextIndex = currentIndex + 1;
        newCardinality = cardinality;
        if (cardinality < state.cardinalityNext) {
            newCardinality = cardinality + 1;
            state.cardinality = newCardinality;
        } else if (nextIndex >= cardinality) {
            nextIndex = 0;
        }
        state.index = nextIndex;
    }

    /// @dev Accumulates the PREVIOUS latest tick over the elapsed time (ADR-0003).
    function _transform(Observation memory last, uint32 blockTimestamp, int24 prevTick, uint128 liquidity)
        internal
        pure
        returns (Observation memory)
    {
        uint32 delta = blockTimestamp - last.blockTimestamp;
        int56 newTickCumulative;
        uint112 newSecondsPerLiquidity;
        unchecked {
            newTickCumulative = last.tickCumulative + int56(prevTick) * int56(uint56(delta));
            uint112 liquidityDelta = liquidity > 0 ? uint112((uint256(delta) << 128) / liquidity) : 0;
            newSecondsPerLiquidity = last.secondsPerLiquidityCumulativeX128 + liquidityDelta;
        }
        return Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: newTickCumulative,
            secondsPerLiquidityCumulativeX128: newSecondsPerLiquidity,
            initialized: true
        });
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

        return _search(poolId, targetTime, oldestIndex, cardinality);
    }

    /// @dev Binary search for the observation pair bracketing `targetTime` (oldest <= target < newest).
    function _search(PoolId poolId, uint32 targetTime, uint256 oldestIndex, uint256 cardinality)
        internal
        view
        returns (int56, uint112)
    {
        uint256 l = 0;
        uint256 r = cardinality - 1;
        while (true) {
            uint256 mid = (l + r) / 2;
            uint256 midIndex = (oldestIndex + mid) % cardinality;
            Observation memory midObs = observations[poolId][midIndex];
            if (midObs.blockTimestamp <= targetTime) {
                Observation memory nextObs = observations[poolId][(midIndex + 1) % cardinality];
                if (targetTime < nextObs.blockTimestamp) return _interpolate(midObs, nextObs, targetTime);
                l = mid + 1;
            } else {
                r = mid - 1;
            }
        }
        revert(); // unreachable
    }

    /// @dev Linear interpolation of the cumulatives between two bracketing observations.
    function _interpolate(Observation memory a, Observation memory b, uint32 targetTime)
        internal
        pure
        returns (int56 tickCumulative, uint112 secondsPerLiquidity)
    {
        uint32 timeDiff = b.blockTimestamp - a.blockTimestamp;
        uint32 offset = targetTime - a.blockTimestamp;
        unchecked {
            int56 tickDiff = b.tickCumulative - a.tickCumulative;
            tickCumulative = a.tickCumulative + (tickDiff * int56(uint56(offset))) / int56(uint56(timeDiff));
            uint112 secDiff = b.secondsPerLiquidityCumulativeX128 - a.secondsPerLiquidityCumulativeX128;
            secondsPerLiquidity = a.secondsPerLiquidityCumulativeX128 + uint112((uint256(secDiff) * offset) / timeDiff);
        }
    }
}
