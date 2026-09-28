// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";
import {ICircuitBreakerEvents} from "../events/ICircuitBreakerEvents.sol";

/**
 * @title ICircuitBreaker
 * @notice Interface for the SupaDex multi-tier emergency circuit breaker system.
 */
interface ICircuitBreaker is ICircuitBreakerEvents {
    function isVaultPaused() external view returns (bool);
    function isPoolPaused(PoolId poolId) external view returns (bool);
    function isCurvePaused(uint8 curveType) external view returns (bool);
    function isGuardian(address account) external view returns (bool);

    function pauseVault() external;
    function unpauseVault() external;

    function pausePool(PoolId poolId) external;
    function unpausePool(PoolId poolId) external;

    function pauseCurve(uint8 curveType) external;
    function unpauseCurve(uint8 curveType) external;

    function setGuardian(address guardian, bool active) external;
}
