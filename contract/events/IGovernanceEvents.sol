// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IGovernanceEvents
 * @notice Event definitions for SupaDex timelock governance and upgrades.
 */
interface IGovernanceEvents {
    /**
     * @notice Emitted when a governance proposal is queued in the timelock
     */
    event CallQueued(
        bytes32 indexed id,
        uint256 indexed index,
        address target,
        uint256 value,
        bytes data,
        bytes32 predecessor,
        uint256 delay
    );

    /**
     * @notice Emitted when a queued governance call is executed
     */
    event CallExecuted(bytes32 indexed id, uint256 indexed index, address target, uint256 value, bytes data);

    /**
     * @notice Emitted when a queued proposal is cancelled
     */
    event CallCancelled(bytes32 indexed id);

    /**
     * @notice Emitted when the timelock delay is updated
     */
    event MinDelayChange(uint256 oldDuration, uint256 newDuration);

    /**
     * @notice Emitted when a contract implementation is upgraded
     */
    event ContractUpgraded(address indexed oldImplementation, address indexed newImplementation);
}
