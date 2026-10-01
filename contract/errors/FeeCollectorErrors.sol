// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title FeeCollectorErrors
 * @notice Custom errors for the protocol fee collector.
 */
library FeeCollectorErrors {
    error Unauthorized();
    error ZeroAddress();
    error InvalidFeeSplit();
    error NothingToSweep();
}
