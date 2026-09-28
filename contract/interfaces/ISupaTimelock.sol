// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGovernanceEvents} from "../events/IGovernanceEvents.sol";

/**
 * @title ISupaTimelock
 * @notice Interface for the SupaDex decentralized governance Timelock Controller.
 */
interface ISupaTimelock is IGovernanceEvents {
    enum OperationState {
        Unset,
        Waiting,
        Ready,
        Done
    }

    function minDelay() external view returns (uint256);
    function getOperationState(bytes32 id) external view returns (OperationState);
    function isOperationReady(bytes32 id) external view returns (bool);
    function isOperationDone(bytes32 id) external view returns (bool);
    function getTimestamp(bytes32 id) external view returns (uint256);

    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    function cancel(bytes32 id) external;

    function updateDelay(uint256 newDelay) external;
}
