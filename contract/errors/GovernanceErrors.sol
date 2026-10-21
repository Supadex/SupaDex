// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title GovernanceErrors
 * @notice Pure custom error definitions for SupaDex governance, timelock, and upgrade authorizations.
 */
library GovernanceErrors {
    /**
     * @dev Thrown when caller is not authorized for the requested governance action
     */
    error UnauthorizedCaller();

    /**
     * @dev Thrown when execution is attempted before the timelock delay has elapsed
     */
    error ExecutionDelayNotMet();

    /**
     * @dev Thrown when a proposal with the same transaction hash is already queued
     */
    error ProposalAlreadyQueued();

    /**
     * @dev Thrown when a proposal has not been queued or was already executed/cancelled
     */
    error ProposalNotQueued();

    /**
     * @dev Thrown when a proposal's execution grace period has expired
     */
    error GracePeriodExpired();

    /**
     * @dev Thrown when the underlying external call execution fails
     */
    error ExecutionFailed();

    /**
     * @dev Thrown when an unauthorized caller attempts a contract upgrade
     */
    error UpgradeUnauthorized();

    /**
     * @dev Thrown when attempting to set a zero address as admin or timelock
     */
    error ZeroAddressAdmin();

    /**
     * @dev Thrown when minimum delay is less than the protocol minimum or greater than maximum
     */
    error InvalidDelay();

    /**
     * @notice ADR-0010: an address may not hold both the proposer and the executor role.
     */
    error RoleConflict(address account);

    /**
     * @notice ADR-0010: removing this holder would leave the role empty (timelock bricked).
     */
    error LastRoleHolder();

    /**
     * @notice ADR-0010: zero address supplied as a role holder.
     */
    error ZeroAddressRole();

    /**
     * @notice ADR-0010: a required role list was empty at construction.
     */
    error EmptyRole();
}
