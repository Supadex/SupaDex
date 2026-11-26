// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaRoles} from "../interfaces/ISupaRoles.sol";
import {RolesErrors} from "../errors/RolesErrors.sol";

/**
 * @title SupaRoles
 * @notice Timelock-owned registry for OPERATOR accounts used by LVR / fee sweep / calibration.
 */
contract SupaRoles is ISupaRoles {
    address public override owner;
    mapping(address => bool) public override isOperator;

    /// @notice Nominated owner. Becomes `owner` only after `acceptOwnership`.
    address public override pendingOwner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert RolesErrors.Unauthorized();
        _;
    }

    constructor(address initialOwner, address initialOperator) {
        if (initialOwner == address(0)) revert RolesErrors.ZeroAddress();
        owner = initialOwner;
        if (initialOperator != address(0)) {
            isOperator[initialOperator] = true;
            emit OperatorUpdated(initialOperator, true);
        }
    }

    function setOperator(address account, bool active) external override onlyOwner {
        if (account == address(0)) revert RolesErrors.ZeroAddress();
        isOperator[account] = active;
        emit OperatorUpdated(account, active);
    }

    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert RolesErrors.ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert RolesErrors.Unauthorized();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }
}
