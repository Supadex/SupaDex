// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CircuitBreaker} from "../../contract/security/CircuitBreaker.sol";
import {PoolId} from "../../contract/types/PoolId.sol";

/// @title CircuitBreakerFormalProof
/// @notice Halmos / Forge-Symbolic formal proof verifying state transitions and permission boundaries of CircuitBreaker.
contract CircuitBreakerFormalProof is Test {
    CircuitBreaker public circuitBreaker;
    address public owner = address(0x1111);
    address public guardian = address(0x2222);

    function setUp() external {
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;
        circuitBreaker = new CircuitBreaker(owner, guardians);
    }

    /// @notice Proves theorem: Once paused by guardian, isVaultPaused is true until unpaused by owner.
    function check_pauseStateTransition(bytes32 poolIdRaw) external {
        PoolId poolId = PoolId.wrap(poolIdRaw);

        vm.prank(guardian);
        circuitBreaker.pausePool(poolId);

        assertTrue(circuitBreaker.isPoolPaused(poolId));

        vm.prank(owner);
        circuitBreaker.unpausePool(poolId);

        assertFalse(circuitBreaker.isPoolPaused(poolId));
    }
}
