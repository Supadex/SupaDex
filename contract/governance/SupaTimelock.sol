// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaTimelock} from "../interfaces/ISupaTimelock.sol";
import {GovernanceErrors} from "../errors/GovernanceErrors.sol";

/**
 * @title SupaTimelock
 * @notice Production-grade, auditor-ready Timelock Controller for SupaDex governance.
 * @dev Manages queued transactions, execution delays, and access roles (Proposers, Executors, Emergency Cancellers).
 */
contract SupaTimelock is ISupaTimelock {
    /**
     * @notice Minimum permissible delay (1 hour)
     */
    uint256 public constant MINIMUM_DELAY = 1 hours;

    /**
     * @notice Maximum permissible delay (30 days)
     */
    uint256 public constant MAXIMUM_DELAY = 30 days;

    /**
     * @notice Grace period after ETA during which a queued transaction is executable (14 days)
     */
    uint256 public constant GRACE_PERIOD = 14 days;

    /**
     * @notice Current minimum execution delay
     */
    uint256 public override minDelay;

    /**
     * @notice Mapping of operation hash to scheduled execution timestamp (ETA)
     */
    mapping(bytes32 => uint256) private _timestamps;

    /**
     * @notice Role mappings
     */
    mapping(address => bool) public isProposer;
    mapping(address => bool) public isExecutor;
    mapping(address => bool) public isCanceller;
    address public admin;

    /**
     * @dev Modifier to restrict access to admin
     */
    modifier onlyAdmin() {
        if (msg.sender != admin) revert GovernanceErrors.UnauthorizedCaller();
        _;
    }

    /**
     * @dev Modifier to restrict access to this timelock contract itself
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert GovernanceErrors.UnauthorizedCaller();
        _;
    }

    constructor(
        uint256 initialMinDelay,
        address initialAdmin,
        address[] memory initialProposers,
        address[] memory initialExecutors,
        address[] memory initialCancellers
    ) {
        if (initialAdmin == address(0)) revert GovernanceErrors.ZeroAddressAdmin();
        if (initialMinDelay < MINIMUM_DELAY || initialMinDelay > MAXIMUM_DELAY) {
            revert GovernanceErrors.InvalidDelay();
        }

        minDelay = initialMinDelay;
        admin = initialAdmin;

        uint256 pLen = initialProposers.length;
        for (uint256 i = 0; i < pLen;) {
            isProposer[initialProposers[i]] = true;
            unchecked { ++i; }
        }

        uint256 eLen = initialExecutors.length;
        for (uint256 i = 0; i < eLen;) {
            isExecutor[initialExecutors[i]] = true;
            unchecked { ++i; }
        }

        uint256 cLen = initialCancellers.length;
        for (uint256 i = 0; i < cLen;) {
            isCanceller[initialCancellers[i]] = true;
            unchecked { ++i; }
        }
    }

    receive() external payable {}

    /**
     * @notice Computes deterministic hash for a proposal operation
     */
    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public pure override returns (bytes32) {
        return keccak256(abi.encode(target, value, data, predecessor, salt));
    }

    /**
     * @notice Returns current state of an operation
     */
    function getOperationState(bytes32 id) public view override returns (OperationState) {
        uint256 eta = _timestamps[id];
        if (eta == 0) return OperationState.Unset;
        if (eta == 1) return OperationState.Done;
        if (block.timestamp < eta) return OperationState.Waiting;
        if (block.timestamp <= eta + GRACE_PERIOD) return OperationState.Ready;
        return OperationState.Unset; // Expired
    }

    /**
     * @notice Returns whether an operation is ready for execution
     */
    function isOperationReady(bytes32 id) public view override returns (bool) {
        return getOperationState(id) == OperationState.Ready;
    }

    /**
     * @notice Returns whether an operation has already executed
     */
    function isOperationDone(bytes32 id) public view override returns (bool) {
        return _timestamps[id] == 1;
    }

    /**
     * @notice Returns scheduled timestamp for an operation
     */
    function getTimestamp(bytes32 id) public view override returns (uint256) {
        return _timestamps[id];
    }

    /**
     * @notice Schedules a proposal operation for execution after delay
     */
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external override {
        if (!isProposer[msg.sender] && msg.sender != admin) {
            revert GovernanceErrors.UnauthorizedCaller();
        }
        if (delay < minDelay || delay > MAXIMUM_DELAY) {
            revert GovernanceErrors.InvalidDelay();
        }

        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        if (_timestamps[id] != 0) revert GovernanceErrors.ProposalAlreadyQueued();

        uint256 eta = block.timestamp + delay;
        _timestamps[id] = eta;

        emit CallQueued(id, 0, target, value, data, predecessor, delay);
    }

    /**
     * @notice Executes a scheduled proposal operation once delay has elapsed
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable override {
        if (!isExecutor[msg.sender] && msg.sender != admin) {
            revert GovernanceErrors.UnauthorizedCaller();
        }

        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        uint256 eta = _timestamps[id];

        if (eta == 0 || eta == 1) revert GovernanceErrors.ProposalNotQueued();
        if (block.timestamp < eta) revert GovernanceErrors.ExecutionDelayNotMet();
        if (block.timestamp > eta + GRACE_PERIOD) revert GovernanceErrors.GracePeriodExpired();

        if (predecessor != bytes32(0) && !isOperationDone(predecessor)) {
            revert GovernanceErrors.ProposalNotQueued();
        }

        _timestamps[id] = 1; // Mark as done before execution to protect against reentrancy

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        if (!success) {
            if (returndata.length > 0) {
                assembly ("memory-safe") {
                    revert(add(32, returndata), mload(returndata))
                }
            } else {
                revert GovernanceErrors.ExecutionFailed();
            }
        }

        emit CallExecuted(id, 0, target, value, data);
    }

    /**
     * @notice Cancels a pending proposal operation
     */
    function cancel(bytes32 id) external override {
        if (!isCanceller[msg.sender] && msg.sender != admin) {
            revert GovernanceErrors.UnauthorizedCaller();
        }

        uint256 eta = _timestamps[id];
        if (eta == 0 || eta == 1) revert GovernanceErrors.ProposalNotQueued();

        delete _timestamps[id];
        emit CallCancelled(id);
    }

    /**
     * @notice Updates minimum execution delay (must be executed via Timelock self-call)
     */
    function updateDelay(uint256 newDelay) external override onlySelf {
        if (newDelay < MINIMUM_DELAY || newDelay > MAXIMUM_DELAY) {
            revert GovernanceErrors.InvalidDelay();
        }
        emit MinDelayChange(minDelay, newDelay);
        minDelay = newDelay;
    }

    /**
     * @notice Admin management of proposer role
     */
    function setProposer(address account, bool status) external onlyAdmin {
        isProposer[account] = status;
    }

    /**
     * @notice Admin management of executor role
     */
    function setExecutor(address account, bool status) external onlyAdmin {
        isExecutor[account] = status;
    }

    /**
     * @notice Admin management of canceller role
     */
    function setCanceller(address account, bool status) external onlyAdmin {
        isCanceller[account] = status;
    }

    /**
     * @notice Transfers admin authority (e.g. to address(this) for pure self-governance)
     */
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert GovernanceErrors.ZeroAddressAdmin();
        admin = newAdmin;
    }
}
