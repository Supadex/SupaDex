// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICircuitBreaker} from "./ICircuitBreaker.sol";

/**
 * @title IPoolManagerAdmin
 * @notice Minimal read interface engines use to resolve governance (PoolManager owner = timelock) and guardians.
 */
interface IPoolManagerAdmin {
    function owner() external view returns (address);
    function circuitBreaker() external view returns (ICircuitBreaker);
}
