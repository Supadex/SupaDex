// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";

/**
 * @title ICircuitBreakerEvents
 * @notice Event definitions for SupaDex granular multi-tier emergency circuit breaker system.
 */
interface ICircuitBreakerEvents {
    /**
     * @notice Emitted when the global/vault pause status is updated
     */
    event VaultPauseUpdated(bool isPaused);

    /**
     * @notice Emitted when an individual pool is paused or unpaused
     */
    event PoolPauseUpdated(PoolId indexed poolId, bool isPaused);

    /**
     * @notice Emitted when an entire curve engine (CLAMM, BinAMM, StableAMM) is paused or unpaused
     */
    event CurvePauseUpdated(uint8 indexed curveType, bool isPaused);

    /**
     * @notice Emitted when an emergency guardian's status is modified
     */
    event GuardianUpdated(address indexed guardian, bool active);
}
