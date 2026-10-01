// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRolesEvents} from "../events/IRolesEvents.sol";

/**
 * @title ISupaRoles
 * @notice Operator role registry for non-emergency protocol calibration actions.
 */
interface ISupaRoles is IRolesEvents {
    function owner() external view returns (address);
    function isOperator(address account) external view returns (bool);
    function setOperator(address account, bool active) external;
    function transferOwnership(address newOwner) external;
}
