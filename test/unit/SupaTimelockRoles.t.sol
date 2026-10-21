// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {GovernanceErrors} from "../../contract/errors/GovernanceErrors.sol";

/// @notice ADR-0010 (issue 017): separation of duties, no admin bypass, last-holder / zero-address / empty-role
///         protections. Every negative case asserts the specific error; every role change has a positive control
///         that goes through the full schedule -> delay -> execute path.
contract SupaTimelockRolesTest is Test {
    SupaTimelock internal tl;
    address internal constant ADMIN = address(0xA11CE);
    address internal constant PROPOSER = address(0xB0B);
    address internal constant EXECUTOR = address(0xCAFE);
    address internal constant CANCELLER = address(0xD00D);
    address internal constant STRANGER = address(0xDEAD);
    uint256 internal constant DELAY = 1 days;
    uint256 internal saltN;

    function setUp() public {
        tl = new SupaTimelock(DELAY, ADMIN, _arr(PROPOSER), _arr(EXECUTOR), _arr(CANCELLER));
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    /// schedule -> warp -> execute a self-call; returns nothing, bubbles the inner revert.
    function _govSelf(bytes memory data) internal {
        bytes32 salt = bytes32(++saltN);
        vm.prank(PROPOSER);
        tl.schedule(address(tl), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(EXECUTOR);
        tl.execute(address(tl), 0, data, bytes32(0), salt);
    }

    // ------------------------------------------------------------- constructor

    function test_constructor_countsAndRoles() public view {
        assertEq(tl.proposerCount(), 1);
        assertEq(tl.executorCount(), 1);
        assertEq(tl.cancellerCount(), 1);
        assertFalse(tl.isProposer(ADMIN));
        assertFalse(tl.isExecutor(ADMIN));
        assertFalse(tl.isCanceller(ADMIN));
    }

    function test_constructor_proposerEqualsExecutorReverts() public {
        vm.expectRevert(abi.encodeWithSelector(GovernanceErrors.RoleConflict.selector, PROPOSER));
        new SupaTimelock(DELAY, ADMIN, _arr(PROPOSER), _arr(PROPOSER), _arr(CANCELLER));
    }

    function test_constructor_zeroAddressRoleReverts() public {
        vm.expectRevert(GovernanceErrors.ZeroAddressRole.selector);
        new SupaTimelock(DELAY, ADMIN, _arr(address(0)), _arr(EXECUTOR), _arr(CANCELLER));
        vm.expectRevert(GovernanceErrors.ZeroAddressRole.selector);
        new SupaTimelock(DELAY, ADMIN, _arr(PROPOSER), _arr(address(0)), _arr(CANCELLER));
        vm.expectRevert(GovernanceErrors.ZeroAddressRole.selector);
        new SupaTimelock(DELAY, ADMIN, _arr(PROPOSER), _arr(EXECUTOR), _arr(address(0)));
    }

    function test_constructor_emptyRoleReverts() public {
        address[] memory none = new address[](0);
        vm.expectRevert(GovernanceErrors.EmptyRole.selector);
        new SupaTimelock(DELAY, ADMIN, none, _arr(EXECUTOR), _arr(CANCELLER));
        vm.expectRevert(GovernanceErrors.EmptyRole.selector);
        new SupaTimelock(DELAY, ADMIN, _arr(PROPOSER), none, _arr(CANCELLER));
        vm.expectRevert(GovernanceErrors.EmptyRole.selector);
        new SupaTimelock(DELAY, ADMIN, _arr(PROPOSER), _arr(EXECUTOR), none);
    }

    function test_constructor_zeroAdminReverts() public {
        vm.expectRevert(GovernanceErrors.ZeroAddressAdmin.selector);
        new SupaTimelock(DELAY, address(0), _arr(PROPOSER), _arr(EXECUTOR), _arr(CANCELLER));
    }

    // ------------------------------------------------------------- no admin bypass

    function test_adminHasNoPower() public {
        bytes memory data = abi.encodeCall(SupaTimelock.setProposer, (ADMIN, true));
        vm.startPrank(ADMIN);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.schedule(address(tl), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.execute(address(tl), 0, data, bytes32(0), bytes32(0));
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.cancel(bytes32(uint256(1)));
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setProposer(ADMIN, true);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setExecutor(ADMIN, true);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setCanceller(ADMIN, true);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.updateDelay(2 days);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setAdmin(STRANGER);
        vm.stopPrank();
    }

    function testFuzz_roleSettersOnlySelf(address caller) public {
        vm.assume(caller != address(tl));
        vm.startPrank(caller);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setProposer(STRANGER, true);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setExecutor(STRANGER, true);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.setCanceller(STRANGER, true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- separation of duties

    function test_proposerCannotExecute_executorCannotSchedule() public {
        bytes memory data = abi.encodeCall(SupaTimelock.updateDelay, (2 days));
        vm.prank(EXECUTOR);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.schedule(address(tl), 0, data, bytes32(0), bytes32(0), DELAY);

        vm.prank(PROPOSER);
        tl.schedule(address(tl), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(PROPOSER);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        tl.execute(address(tl), 0, data, bytes32(0), bytes32(0));

        // positive control: the executor can
        vm.prank(EXECUTOR);
        tl.execute(address(tl), 0, data, bytes32(0), bytes32(0));
        assertEq(tl.minDelay(), 2 days);
    }

    function test_roleChangeNeedsDelay() public {
        bytes memory data = abi.encodeCall(SupaTimelock.setProposer, (STRANGER, true));
        vm.prank(PROPOSER);
        tl.schedule(address(tl), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(EXECUTOR);
        vm.expectRevert(GovernanceErrors.ExecutionDelayNotMet.selector);
        tl.execute(address(tl), 0, data, bytes32(0), bytes32(0));
        assertFalse(tl.isProposer(STRANGER));
    }

    function test_governedRoleChange_conflictRejected() public {
        vm.expectRevert(abi.encodeWithSelector(GovernanceErrors.RoleConflict.selector, PROPOSER));
        this.extGovSelf(abi.encodeCall(SupaTimelock.setExecutor, (PROPOSER, true)));
        vm.expectRevert(abi.encodeWithSelector(GovernanceErrors.RoleConflict.selector, EXECUTOR));
        this.extGovSelf(abi.encodeCall(SupaTimelock.setProposer, (EXECUTOR, true)));
        assertFalse(tl.isExecutor(PROPOSER));
        assertFalse(tl.isProposer(EXECUTOR));
    }

    function test_governedRoleChange_lastHolderRejected() public {
        vm.expectRevert(GovernanceErrors.LastRoleHolder.selector);
        this.extGovSelf(abi.encodeCall(SupaTimelock.setProposer, (PROPOSER, false)));
        vm.expectRevert(GovernanceErrors.LastRoleHolder.selector);
        this.extGovSelf(abi.encodeCall(SupaTimelock.setExecutor, (EXECUTOR, false)));
        vm.expectRevert(GovernanceErrors.LastRoleHolder.selector);
        this.extGovSelf(abi.encodeCall(SupaTimelock.setCanceller, (CANCELLER, false)));
        assertEq(tl.proposerCount(), 1);
        assertEq(tl.executorCount(), 1);
        assertEq(tl.cancellerCount(), 1);
    }

    function test_governedRoleChange_zeroAddressRejected() public {
        vm.expectRevert(GovernanceErrors.ZeroAddressRole.selector);
        this.extGovSelf(abi.encodeCall(SupaTimelock.setExecutor, (address(0), true)));
    }

    /// Positive control: rotation (add new, then remove old) works through governance and counts track.
    function test_governedRotation() public {
        address newProp = address(0x9001);
        address newExec = address(0x9002);
        _govSelf(abi.encodeCall(SupaTimelock.setProposer, (newProp, true)));
        _govSelf(abi.encodeCall(SupaTimelock.setExecutor, (newExec, true)));
        assertEq(tl.proposerCount(), 2);
        assertEq(tl.executorCount(), 2);
        _govSelf(abi.encodeCall(SupaTimelock.setExecutor, (EXECUTOR, false))); // executed by EXECUTOR itself
        assertEq(tl.executorCount(), 1);
        assertFalse(tl.isExecutor(EXECUTOR));
        assertTrue(tl.isExecutor(newExec));
        // idempotent set is a no-op (no count drift)
        bytes32 salt = bytes32(++saltN);
        bytes memory data = abi.encodeCall(SupaTimelock.setProposer, (newProp, true));
        vm.prank(PROPOSER);
        tl.schedule(address(tl), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(newExec);
        tl.execute(address(tl), 0, data, bytes32(0), salt);
        assertEq(tl.proposerCount(), 2);
    }

    function extGovSelf(bytes calldata data) external {
        _govSelf(data);
    }
}
