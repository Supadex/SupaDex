// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {ISupaTimelock} from "../../contract/interfaces/ISupaTimelock.sol";
import {GovernanceErrors} from "../../contract/errors/GovernanceErrors.sol";

contract MockTarget {
    uint256 public counter;

    function increment(uint256 value) external payable {
        counter += value;
    }
}

contract SupaTimelockTest is Test {
    SupaTimelock public timelock;
    MockTarget public target;

    address public admin = address(0xA11CE);
    address public proposer = address(0xB0B);
    address public executor = address(0xCAFE);
    address public canceller = address(0xD00D);
    address public stranger = address(0xDEAD);

    uint256 public constant MIN_DELAY = 1 days;

    function setUp() external {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = executor;

        address[] memory cancellers = new address[](1);
        cancellers[0] = canceller;

        timelock = new SupaTimelock(MIN_DELAY, admin, proposers, executors, cancellers);
        target = new MockTarget();
    }

    function test_initialization() public view {
        assertEq(timelock.minDelay(), MIN_DELAY);
        assertEq(timelock.admin(), admin);
        assertTrue(timelock.isProposer(proposer));
        assertTrue(timelock.isExecutor(executor));
        assertTrue(timelock.isCanceller(canceller));
        assertFalse(timelock.isProposer(stranger));
    }

    function test_scheduleAndExecuteProposal() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.increment.selector, 42);
        bytes32 salt = bytes32(uint256(1));
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), salt);

        // Schedule as proposer
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, MIN_DELAY);

        assertEq(uint256(timelock.getOperationState(id)), uint256(ISupaTimelock.OperationState.Waiting));
        assertFalse(timelock.isOperationReady(id));

        // Attempt early execution reverts
        vm.prank(executor);
        vm.expectRevert(GovernanceErrors.ExecutionDelayNotMet.selector);
        timelock.execute(address(target), 0, data, bytes32(0), salt);

        // Warp time past delay
        vm.warp(block.timestamp + MIN_DELAY);

        assertEq(uint256(timelock.getOperationState(id)), uint256(ISupaTimelock.OperationState.Ready));
        assertTrue(timelock.isOperationReady(id));

        // Execute as executor
        vm.prank(executor);
        timelock.execute(address(target), 0, data, bytes32(0), salt);

        assertEq(target.counter(), 42);
        assertTrue(timelock.isOperationDone(id));
        assertEq(uint256(timelock.getOperationState(id)), uint256(ISupaTimelock.OperationState.Done));
    }

    function test_gracePeriodExpirationReverts() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.increment.selector, 10);
        bytes32 salt = bytes32(uint256(2));

        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, MIN_DELAY);

        // Warp past ETA + GRACE_PERIOD (14 days) + 1 second
        vm.warp(block.timestamp + MIN_DELAY + 14 days + 1);

        vm.prank(executor);
        vm.expectRevert(GovernanceErrors.GracePeriodExpired.selector);
        timelock.execute(address(target), 0, data, bytes32(0), salt);
    }

    function test_cancelProposal() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.increment.selector, 10);
        bytes32 salt = bytes32(uint256(3));
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), salt);

        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, MIN_DELAY);

        // Canceller cancels
        vm.prank(canceller);
        timelock.cancel(id);

        assertEq(uint256(timelock.getOperationState(id)), uint256(ISupaTimelock.OperationState.Unset));

        // Warp and attempt execution reverts
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(executor);
        vm.expectRevert(GovernanceErrors.ProposalNotQueued.selector);
        timelock.execute(address(target), 0, data, bytes32(0), salt);
    }

    function test_unauthorizedCallsRevert() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.increment.selector, 1);
        bytes32 salt = bytes32(uint256(4));

        vm.prank(stranger);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(stranger);
        vm.expectRevert(GovernanceErrors.UnauthorizedCaller.selector);
        timelock.cancel(salt);
    }

    function test_updateDelayViaTimelockExecution() public {
        uint256 newDelay = 2 days;
        bytes memory data = abi.encodeWithSelector(SupaTimelock.updateDelay.selector, newDelay);
        bytes32 salt = bytes32(uint256(5));

        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(executor);
        timelock.execute(address(timelock), 0, data, bytes32(0), salt);

        assertEq(timelock.minDelay(), newDelay);
    }
}
