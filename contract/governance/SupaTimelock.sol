// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaTimelock} from "../interfaces/ISupaTimelock.sol";
import {GovernanceErrors} from "../errors/GovernanceErrors.sol";
import {ChainIds} from "../libraries/ChainIds.sol";

/**
 * @title SupaTimelock
 * @notice Production-grade, auditor-ready Timelock Controller for SupaDex governance.
 * @dev Manages queued transactions, execution delays, and access roles (Proposers, Executors, Emergency Cancellers).
 *
 *      ADR-0010 (Jexi 017) — separation of duties, no bypass:
 *      - `admin` is an informational label only; it can NOT schedule, execute or cancel.
 *      - No address may be both proposer and executor (constructor and role setters enforce it).
 *      - Every role must keep at least one holder; the last holder cannot be removed.
 *      - Role/delay/admin changes happen only through a scheduled + delayed self-call.
 *      - Cancellers may overlap with proposers (an emergency guardian may cancel what it can see).
 *      - On-chain delay floor (Edith 10-A): `delayFloor` is fixed at construction from the chain id. Value-bearing
 *        (i.e. every chain that is not a known local/test chain — fail-closed) gets PRODUCTION_DELAY_FLOOR = 48 h;
 *        known local/test chains get MINIMUM_DELAY. Neither the constructor nor `updateDelay` accept less.
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

    /// @notice Delay floor on value-bearing networks (Edith 10-A).
    uint256 public constant PRODUCTION_DELAY_FLOOR = 48 hours;

    /// @notice Effective lower bound on `minDelay` for this deployment (chain-derived, immutable).
    uint256 public immutable delayFloor;

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

    /// @notice Holder counts per role (ADR-0010 last-holder protection).
    uint256 public proposerCount;
    uint256 public executorCount;
    uint256 public cancellerCount;

    event ProposerSet(address indexed account, bool status);
    event ExecutorSet(address indexed account, bool status);
    event CancellerSet(address indexed account, bool status);
    event AdminSet(address indexed previousAdmin, address indexed newAdmin);
    /// @notice Emitted alongside CallQueued with the salt needed to execute/cancel (OZ TimelockController style).
    ///         Always emitted (also for salt == 0) so indexers / Safe-wrapped schedules can recover it from logs.
    event CallSalt(bytes32 indexed id, bytes32 salt);

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
        uint256 floor = isTestChain(block.chainid) ? MINIMUM_DELAY : PRODUCTION_DELAY_FLOOR;
        delayFloor = floor;
        if (initialMinDelay < floor || initialMinDelay > MAXIMUM_DELAY) {
            revert GovernanceErrors.InvalidDelay();
        }

        minDelay = initialMinDelay;
        admin = initialAdmin;

        if (initialProposers.length == 0 || initialExecutors.length == 0 || initialCancellers.length == 0) {
            revert GovernanceErrors.EmptyRole();
        }
        for (uint256 i = 0; i < initialProposers.length; ++i) {
            _setProposer(initialProposers[i], true);
        }
        for (uint256 i = 0; i < initialExecutors.length; ++i) {
            _setExecutor(initialExecutors[i], true);
        }
        for (uint256 i = 0; i < initialCancellers.length; ++i) {
            _setCanceller(initialCancellers[i], true);
        }
    }

    receive() external payable {}

    /**
     * @notice Computes deterministic hash for a proposal operation
     */
    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        public
        pure
        override
        returns (bytes32)
    {
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
     * @notice True when a scheduled operation passed its execution window (ETA + GRACE_PERIOD) without executing.
     * @dev getOperationState reports such ops as Unset (it can be re-scheduled). UIs use this to show "Expired"
     *      rather than "never scheduled / cancelled".
     */
    function isOperationExpired(bytes32 id) public view returns (bool) {
        uint256 eta = _timestamps[id];
        return eta > 1 && block.timestamp > eta + GRACE_PERIOD;
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
        if (!isProposer[msg.sender]) {
            revert GovernanceErrors.UnauthorizedCaller();
        }
        if (delay < minDelay || delay > MAXIMUM_DELAY) {
            revert GovernanceErrors.InvalidDelay();
        }

        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        uint256 existing = _timestamps[id];
        if (existing != 0) {
            // Allow reschedule only when the prior op expired (not Done, past grace period).
            if (existing == 1 || block.timestamp <= existing + GRACE_PERIOD) {
                revert GovernanceErrors.ProposalAlreadyQueued();
            }
        }

        uint256 eta = block.timestamp + delay;
        _timestamps[id] = eta;

        emit CallQueued(id, 0, target, value, data, predecessor, delay);
        emit CallSalt(id, salt);
    }

    /**
     * @notice Executes a scheduled proposal operation once delay has elapsed
     */
    function execute(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        payable
        override
    {
        if (!isExecutor[msg.sender]) {
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
        if (!isCanceller[msg.sender]) {
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
        if (newDelay < delayFloor || newDelay > MAXIMUM_DELAY) {
            revert GovernanceErrors.InvalidDelay();
        }
        emit MinDelayChange(minDelay, newDelay);
        minDelay = newDelay;
    }

    /**
     * @notice Proposer role change. ADR-0005/0010: only via a scheduled + delayed self-call (`schedule` → `execute`).
     */
    function setProposer(address account, bool status) external onlySelf {
        _setProposer(account, status);
    }

    /**
     * @notice Executor role change. ADR-0005/0010: only via a scheduled + delayed self-call.
     */
    function setExecutor(address account, bool status) external onlySelf {
        _setExecutor(account, status);
    }

    /**
     * @notice Canceller role change. ADR-0005/0010: only via a scheduled + delayed self-call.
     */
    function setCanceller(address account, bool status) external onlySelf {
        _setCanceller(account, status);
    }

    function _setProposer(address account, bool status) internal {
        if (account == address(0)) revert GovernanceErrors.ZeroAddressRole();
        if (isProposer[account] == status) return;
        if (status) {
            if (isExecutor[account]) revert GovernanceErrors.RoleConflict(account);
            ++proposerCount;
        } else {
            if (proposerCount == 1) revert GovernanceErrors.LastRoleHolder();
            --proposerCount;
        }
        isProposer[account] = status;
        emit ProposerSet(account, status);
    }

    function _setExecutor(address account, bool status) internal {
        if (account == address(0)) revert GovernanceErrors.ZeroAddressRole();
        if (isExecutor[account] == status) return;
        if (status) {
            if (isProposer[account]) revert GovernanceErrors.RoleConflict(account);
            ++executorCount;
        } else {
            if (executorCount == 1) revert GovernanceErrors.LastRoleHolder();
            --executorCount;
        }
        isExecutor[account] = status;
        emit ExecutorSet(account, status);
    }

    function _setCanceller(address account, bool status) internal {
        if (account == address(0)) revert GovernanceErrors.ZeroAddressRole();
        if (isCanceller[account] == status) return;
        if (status) {
            ++cancellerCount;
        } else {
            if (cancellerCount == 1) revert GovernanceErrors.LastRoleHolder();
            --cancellerCount;
        }
        isCanceller[account] = status;
        emit CancellerSet(account, status);
    }

    /**
     * @notice Updates the informational `admin` label. ADR-0005: only via a scheduled + delayed self-call; `admin` holds no direct power.
     */
    function setAdmin(address newAdmin) external onlySelf {
        if (newAdmin == address(0)) revert GovernanceErrors.ZeroAddressAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    /**
     * @notice Chains where a delay below 48 h is acceptable: local anvil (31337) and public testnets only, read from
     * the shared `ChainIds` allowlist that the deploy scripts also use (ADR-0010 condition). Everything else
     * (including unknown chain ids, Monad testnet 10143, geth-dev 1337 and anvil forks of mainnet, which report
     * chain id 1) is treated as value-bearing.
     */
    function isTestChain(uint256 chainId) public pure returns (bool) {
        return ChainIds.isTestChain(chainId);
    }
}
