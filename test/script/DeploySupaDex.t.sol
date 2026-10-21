// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySupaDex} from "../../script/DeploySupaDex.s.sol";
import {VerifyDeployments} from "../../script/VerifyDeployments.s.sol";
import {DeployEnvironment} from "../../script/DeployEnvironment.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";

/// @notice Jexi 019: deploy + fail-closed verification, including negative controls.
contract DeploySupaDexTest is Test {
    DeploySupaDex public deployer;
    VerifyDeployments public verifier;

    function setUp() external {
        deployer = new DeploySupaDex();
        verifier = new VerifyDeployments();
    }

    function _cfg() internal pure returns (DeploySupaDex.RoleConfig memory) {
        return DeploySupaDex.RoleConfig({
            governance: address(0xA011),
            proposer: address(0xA017),
            executor: address(0xA018),
            canceller: address(0xA019),
            guardian: address(0xA012),
            operator: address(0xA013),
            dao: address(0xA014),
            staking: address(0xA015),
            insurance: address(0xA016),
            timelockDelay: 2 days
        });
    }

    function _deploy() internal returns (DeploySupaDex.DeploymentResult memory res) {
        // deploy() runs inside the script contract, so CREATEs and owner-only wiring originate from it (under
        // `forge script` broadcast both come from the EOA). Use the script address as the deployer.
        res = deployer.deploy(address(deployer), _cfg());
    }

    function test_deterministicDeploymentAndVerification() public {
        DeploySupaDex.DeploymentResult memory res = _deploy();
        VerifyDeployments.Report memory r = verifier.verify(res, _cfg(), address(deployer));
        assertEq(r.failures, 0);
        assertGt(r.checks, 60, "full check suite ran");
        SupaTimelock tl = SupaTimelock(payable(res.timelock));
        assertTrue(tl.isProposer(address(0xA017)) && !tl.isExecutor(address(0xA017)));
        assertTrue(tl.isExecutor(address(0xA018)) && !tl.isProposer(address(0xA018)));
        assertEq(tl.minDelay(), 2 days);
    }

    // ---- fail-closed negative controls

    function test_verify_blocksOnWrongExpectedRoles() public {
        DeploySupaDex.DeploymentResult memory res = _deploy();
        DeploySupaDex.RoleConfig memory wrong = _cfg();
        wrong.executor = address(0xBEEF);
        VerifyDeployments.Report memory r = verifier.check(res, wrong, address(deployer));
        assertGt(r.failures, 0);
        vm.expectRevert(bytes(DeployEnvironment.DEPLOYMENT_BLOCKED));
        verifier.verify(res, wrong, address(deployer));
    }

    function test_verify_blocksOnMissingCode() public {
        DeploySupaDex.DeploymentResult memory res = _deploy();
        res.router = address(0x1234);
        vm.expectRevert(bytes(DeployEnvironment.DEPLOYMENT_BLOCKED));
        verifier.verify(res, _cfg(), address(deployer));
    }

    function test_verify_blocksOnSwappedAddresses() public {
        DeploySupaDex.DeploymentResult memory res = _deploy();
        (res.clammEngine, res.stableEngine) = (res.stableEngine, res.clammEngine);
        vm.expectRevert(bytes(DeployEnvironment.DEPLOYMENT_BLOCKED));
        verifier.verify(res, _cfg(), address(deployer));
    }

    function test_verify_blocksWhenOwnershipNotHandedOff() public {
        DeploySupaDex.DeploymentResult memory res = _deploy();
        // simulate a deployment where the pool manager is owned by someone else
        vm.prank(res.timelock);
        SupaPoolManager(res.poolManager).transferOwnership(address(0xBAD));
        vm.expectRevert(bytes(DeployEnvironment.DEPLOYMENT_BLOCKED));
        verifier.verify(res, _cfg(), address(deployer));
    }

    function test_verify_blocksOnProductionOrUnknownChain() public {
        DeploySupaDex.DeploymentResult memory res = _deploy();
        vm.chainId(1);
        vm.expectRevert(bytes(DeployEnvironment.DEPLOYMENT_BLOCKED));
        verifier.verify(res, _cfg(), address(deployer));
        vm.chainId(999_999_999);
        vm.expectRevert(bytes(DeployEnvironment.DEPLOYMENT_BLOCKED));
        verifier.verify(res, _cfg(), address(deployer));
    }

    function test_deploy_blockedOnProductionAndUnknownChains() public {
        DeploySupaDex.RoleConfig memory cfg = _cfg();
        uint256[3] memory ids = [uint256(1), 8453, 424242];
        for (uint256 i; i < ids.length; ++i) {
            vm.chainId(ids[i]);
            vm.expectRevert(bytes(DeployEnvironment.DEPLOYMENT_BLOCKED));
            deployer.deploy(address(deployer), cfg);
        }
    }

    function test_deploy_allowedOnTestnet() public {
        vm.chainId(11155111);
        DeploySupaDex.DeploymentResult memory res = _deploy();
        assertEq(verifier.verify(res, _cfg(), address(deployer)).failures, 0);
    }

    function test_deploy_rejectsProposerEqualsExecutor() public {
        DeploySupaDex.RoleConfig memory cfg = _cfg();
        cfg.executor = cfg.proposer;
        vm.expectRevert(bytes("PROPOSER and EXECUTOR must differ (ADR-0010)"));
        deployer.deploy(address(deployer), cfg);
    }

    function test_deploy_rejectsDeployerHoldingRole() public {
        DeploySupaDex.RoleConfig memory cfg = _cfg();
        cfg.canceller = address(deployer);
        vm.expectRevert(bytes("deployer must hold no timelock role"));
        deployer.deploy(address(deployer), cfg);
    }

    function test_environmentClassification() public pure {
        assertEq(uint8(DeployEnvironment.classify(31337)), uint8(DeployEnvironment.Kind.LOCAL));
        assertEq(uint8(DeployEnvironment.classify(11155111)), uint8(DeployEnvironment.Kind.TESTNET));
        assertEq(uint8(DeployEnvironment.classify(1)), uint8(DeployEnvironment.Kind.PRODUCTION));
        assertEq(uint8(DeployEnvironment.classify(5)), uint8(DeployEnvironment.Kind.UNKNOWN), "Goerli is retired");
        assertFalse(DeployEnvironment.deploymentAllowed(DeployEnvironment.Kind.UNKNOWN));
        assertFalse(DeployEnvironment.deploymentAllowed(DeployEnvironment.Kind.PRODUCTION));
    }

    /// The scripts must never print a readiness claim. Source-level guard against regressions (Jexi 019).
    function test_scriptsNeverClaimMainnetProduction() public view {
        string[3] memory files = ["script/DeploySupaDex.s.sol", "script/VerifyDeployments.s.sol", "script/DeployEnvironment.sol"];
        for (uint256 i; i < files.length; ++i) {
            string memory src = vm.readFile(files[i]);
            assertFalse(_contains(src, "Mainnet Production"), files[i]);
            assertFalse(_contains(src, "MAINNET READY"), files[i]);
            assertFalse(_contains(src, "100% integrity"), files[i]);
        }
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool m = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }
}
