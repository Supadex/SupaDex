// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Multicall
 * @notice Enables batch execution of multiple calls in a single transaction.
 */
abstract contract Multicall {
    /**
     * @notice Executes multiple calls consecutively on this contract.
     * @param data Array of calldata payloads to execute.
     * @return results Array of abi-encoded execution return data.
     */
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; ) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
            unchecked {
                ++i;
            }
        }
    }
}
