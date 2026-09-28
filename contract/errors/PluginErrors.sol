// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PluginErrors
 * @notice Library containing custom errors for native plugins and external hooks.
 */
library PluginErrors {
    /**
     * @dev Thrown when a plugin call reverts or returns invalid status.
     */
    error PluginCallFailed(address plugin, bytes4 selector, bytes reason);

    /**
     * @dev Thrown when a plugin consumes more gas than its allocated gas stipend.
     */
    error PluginGasExceeded(address plugin, uint256 gasUsed, uint256 gasLimit);

    /**
     * @dev Thrown when a plugin does not have permission for the requested lifecycle action.
     */
    error PluginPermissionDenied(address plugin, uint256 requiredFlag);

    /**
     * @dev Thrown when an external plugin attempts an illegal reentrancy into pool manager.
     */
    error PluginReentrancyLock();

    /**
     * @dev Thrown when anti-JIT fee residency check triggers penalty.
     */
    error JITResidencyViolation(address provider, uint256 elapsedBlocks, uint256 requiredBlocks);

    /**
     * @dev Thrown when a caller is not the authorized pool manager singleton.
     */
    error NotPoolManager();

    /**
     * @dev Thrown when an oracle operation is attempted on an uninitialized pool oracle.
     */
    error OracleNotInitialized();

    /**
     * @dev Thrown when target cardinality is invalid or smaller than current cardinality.
     */
    error InvalidCardinality();

    /**
     * @dev Thrown when requested observation window is older than available history.
     */
    error ObservationWindowTooOld();

    /**
     * @dev Thrown when a hook address does not conform to required permission bitmask.
     */
    error InvalidHookPermissions();
}
