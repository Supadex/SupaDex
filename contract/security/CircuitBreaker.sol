// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";
import {ICircuitBreaker} from "../interfaces/ICircuitBreaker.sol";
import {CircuitBreakerErrors} from "../errors/CircuitBreakerErrors.sol";

/**
 * @title CircuitBreaker
 * @notice Auditor-ready, multi-tier emergency circuit breaker for the SupaDex AMM ecosystem.
 * @dev Features granular 4-tier isolation: Global Vault, Specific Pool, Curve Engine, and Action-Level gating.
 * Guardians can trigger instant emergency pauses, while unpausing is restricted to Governance/Timelock.
 */
contract CircuitBreaker is ICircuitBreaker {
    /**
     * @notice Governance admin / Timelock contract
     */
    address public owner;

    /**
     * @notice Mapping of authorized emergency guardians
     */
    mapping(address => bool) public override isGuardian;

    /**
     * @notice Global AMM / Vault pause flag
     */
    bool public override isVaultPaused;

    /**
     * @notice Per-pool emergency pause flags
     */
    mapping(PoolId => bool) public override isPoolPaused;

    /**
     * @notice Per-curve emergency pause flags (0: CLAMM, 1: BinAMM, 2: StableAMM)
     */
    mapping(uint8 => bool) public override isCurvePaused;

    modifier onlyOwner() {
        if (msg.sender != owner) revert CircuitBreakerErrors.UnauthorizedGuardian();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (!isGuardian[msg.sender] && msg.sender != owner) {
            revert CircuitBreakerErrors.UnauthorizedGuardian();
        }
        _;
    }

    constructor(address initialOwner, address[] memory initialGuardians) {
        if (initialOwner == address(0)) revert CircuitBreakerErrors.ZeroAddress();
        owner = initialOwner;

        uint256 len = initialGuardians.length;
        for (uint256 i = 0; i < len;) {
            isGuardian[initialGuardians[i]] = true;
            emit GuardianUpdated(initialGuardians[i], true);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Emergency pause for the entire Vault & AMM execution gateway
     */
    function pauseVault() external override onlyGuardianOrOwner {
        isVaultPaused = true;
        emit VaultPauseUpdated(true);
    }

    /**
     * @notice Unpauses the Vault & AMM execution gateway (restricted to Governance Timelock)
     */
    function unpauseVault() external override onlyOwner {
        isVaultPaused = false;
        emit VaultPauseUpdated(false);
    }

    /**
     * @notice Emergency pause for an individual isolated pool
     */
    function pausePool(PoolId poolId) external override onlyGuardianOrOwner {
        isPoolPaused[poolId] = true;
        emit PoolPauseUpdated(poolId, true);
    }

    /**
     * @notice Unpauses an individual pool (restricted to Governance Timelock)
     */
    function unpausePool(PoolId poolId) external override onlyOwner {
        isPoolPaused[poolId] = false;
        emit PoolPauseUpdated(poolId, false);
    }

    /**
     * @notice Emergency pause for an entire curve engine (0: CLAMM, 1: BinAMM, 2: StableAMM)
     */
    function pauseCurve(uint8 curveType) external override onlyGuardianOrOwner {
        if (curveType > 2) revert CircuitBreakerErrors.InvalidCurveType();
        isCurvePaused[curveType] = true;
        emit CurvePauseUpdated(curveType, true);
    }

    /**
     * @notice Unpauses a curve engine (restricted to Governance Timelock)
     */
    function unpauseCurve(uint8 curveType) external override onlyOwner {
        if (curveType > 2) revert CircuitBreakerErrors.InvalidCurveType();
        isCurvePaused[curveType] = false;
        emit CurvePauseUpdated(curveType, false);
    }

    /**
     * @notice Configures authorized emergency guardian status
     */
    function setGuardian(address guardian, bool active) external override onlyOwner {
        if (guardian == address(0)) revert CircuitBreakerErrors.ZeroAddress();
        isGuardian[guardian] = active;
        emit GuardianUpdated(guardian, active);
    }

    /**
     * @notice Transfers circuit breaker governance to a new owner (e.g. SupaTimelock)
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert CircuitBreakerErrors.ZeroAddress();
        owner = newOwner;
    }
}
