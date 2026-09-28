// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IUnlockCallback
 * @notice Interface for contracts that call unlock on the SupaDex Vault to perform flash swaps/liquidity operations.
 */
interface IUnlockCallback {
    /**
     * @notice Called by the Vault during `unlock`.
     * @param data Arbitrary data passed through from the `unlock` caller.
     * @return result Arbitrary return data to be returned to the unlock caller.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory result);
}
