// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IRolesEvents
 * @notice Events for the SupaRoles operator registry.
 */
interface IRolesEvents {
    event OperatorUpdated(address indexed account, bool active);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}
