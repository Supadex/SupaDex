// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title CircuitBreakerErrors
 * @notice Pure custom error definitions for SupaDex multi-tier emergency circuit breaker system.
 */
library CircuitBreakerErrors {
    /**
     * @dev Thrown when an action is attempted on a paused pool
     */
    error PoolPaused();

    /**
     * @dev Thrown when an action is attempted on a paused curve engine
     */
    error CurvePaused();

    /**
     * @dev Thrown when an action is attempted while the vault or global AMM is paused
     */
    error VaultPaused();

    /**
     * @dev Thrown when caller is not an authorized emergency guardian or admin
     */
    error UnauthorizedGuardian();

    /**
     * @dev Thrown when attempting to pause or unpause an invalid curve type
     */
    error InvalidCurveType();

    /**
     * @dev Thrown when attempting to set a zero address as guardian or circuit breaker
     */
    error ZeroAddress();
}
