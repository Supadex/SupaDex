// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CircuitBreaker} from "../../contract/security/CircuitBreaker.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {CircuitBreakerErrors} from "../../contract/errors/CircuitBreakerErrors.sol";

contract CircuitBreakerTest is Test {
    CircuitBreaker public circuitBreaker;

    address public owner = address(0x1111);
    address public guardian = address(0x2222);
    address public stranger = address(0x3333);

    PoolId public testPoolId = PoolId.wrap(bytes32(uint256(999)));

    function setUp() external {
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;

        circuitBreaker = new CircuitBreaker(owner, guardians);
    }

    function test_initialState() public view {
        assertEq(circuitBreaker.owner(), owner);
        assertTrue(circuitBreaker.isGuardian(guardian));
        assertFalse(circuitBreaker.isGuardian(stranger));
        assertFalse(circuitBreaker.isVaultPaused());
        assertFalse(circuitBreaker.isPoolPaused(testPoolId));
        assertFalse(circuitBreaker.isCurvePaused(0));
    }

    function test_vaultEmergencyPauseByGuardian() public {
        // Guardian triggers instant emergency pause
        vm.prank(guardian);
        circuitBreaker.pauseVault();
        assertTrue(circuitBreaker.isVaultPaused());

        // Guardian CANNOT unpause
        vm.prank(guardian);
        vm.expectRevert(CircuitBreakerErrors.UnauthorizedGuardian.selector);
        circuitBreaker.unpauseVault();

        // Stranger cannot unpause
        vm.prank(stranger);
        vm.expectRevert(CircuitBreakerErrors.UnauthorizedGuardian.selector);
        circuitBreaker.unpauseVault();

        // Owner (Timelock) unpauses
        vm.prank(owner);
        circuitBreaker.unpauseVault();
        assertFalse(circuitBreaker.isVaultPaused());
    }

    function test_poolEmergencyPauseByGuardian() public {
        vm.prank(guardian);
        circuitBreaker.pausePool(testPoolId);
        assertTrue(circuitBreaker.isPoolPaused(testPoolId));

        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert(CircuitBreakerErrors.UnauthorizedGuardian.selector);
        circuitBreaker.unpausePool(testPoolId);

        // Owner unpauses
        vm.prank(owner);
        circuitBreaker.unpausePool(testPoolId);
        assertFalse(circuitBreaker.isPoolPaused(testPoolId));
    }

    function test_curveEmergencyPauseByGuardian() public {
        uint8 clammCurve = 0;
        vm.prank(guardian);
        circuitBreaker.pauseCurve(clammCurve);
        assertTrue(circuitBreaker.isCurvePaused(clammCurve));

        // Invalid curve type reverts
        vm.prank(guardian);
        vm.expectRevert(CircuitBreakerErrors.InvalidCurveType.selector);
        circuitBreaker.pauseCurve(3);

        // Owner unpauses
        vm.prank(owner);
        circuitBreaker.unpauseCurve(clammCurve);
        assertFalse(circuitBreaker.isCurvePaused(clammCurve));
    }

    function test_guardianManagement() public {
        address newGuardian = address(0x4444);

        vm.prank(owner);
        circuitBreaker.setGuardian(newGuardian, true);
        assertTrue(circuitBreaker.isGuardian(newGuardian));

        vm.prank(newGuardian);
        circuitBreaker.pauseVault();
        assertTrue(circuitBreaker.isVaultPaused());

        vm.prank(owner);
        circuitBreaker.setGuardian(newGuardian, false);
        assertFalse(circuitBreaker.isGuardian(newGuardian));
    }
}
