// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySupaDex} from "../../script/DeploySupaDex.s.sol";
import {VerifyDeployments} from "../../script/VerifyDeployments.s.sol";
import {DeployEnvironment} from "../../script/DeployEnvironment.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CircuitBreaker} from "../../contract/security/CircuitBreaker.sol";

/// TEST-ONLY Safe stand-in exposing the two calls the verifier uses to recognise a multisig.
contract MockSafe {
    uint256 public threshold;
    address[] internal owners;

    constructor(uint256 t, uint256 n) {
        threshold = t;
        for (uint256 i; i < n; i++) owners.push(address(uint160(0x5AFE00 + i)));
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }
}

contract NotASafe {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// Test harnesses: pin the resolved environment (what `run()` derives from DEPLOY_ENV + the anvil probe).
contract DeployHarness is DeploySupaDex {
    function setKind(DeployEnvironment.Kind k) external {
        resolvedKind = k;
        resolved = true;
    }
}

contract VerifyHarness is VerifyDeployments {
    function setKind(DeployEnvironment.Kind k) external {
        resolvedKind = k;
        resolved = true;
    }
}

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

    /// Jexi 019: fork detection. Declared env and node probe must agree; every mismatch fails closed.
    function test_environmentResolution_failsClosed() public pure {
        DeployEnvironment.Kind U = DeployEnvironment.Kind.UNKNOWN;
        // local
        assertEq(uint8(DeployEnvironment.resolve(31337, "local", true)), uint8(DeployEnvironment.Kind.LOCAL));
        assertEq(uint8(DeployEnvironment.resolve(31337, "local", false)), uint8(DeployEnvironment.Kind.LOCAL));
        assertEq(uint8(DeployEnvironment.resolve(1, "local", true)), uint8(U), "mainnet id declared local");
        // fork: any chain id, but only on a local anvil node
        assertEq(uint8(DeployEnvironment.resolve(1, "fork", true)), uint8(DeployEnvironment.Kind.FORK));
        assertEq(uint8(DeployEnvironment.resolve(8453, "fork", true)), uint8(DeployEnvironment.Kind.FORK));
        assertEq(uint8(DeployEnvironment.resolve(1, "fork", false)), uint8(U), "declared fork but live node");
        // testnet
        assertEq(uint8(DeployEnvironment.resolve(11155111, "testnet", false)), uint8(DeployEnvironment.Kind.TESTNET));
        assertEq(uint8(DeployEnvironment.resolve(11155111, "testnet", true)), uint8(U), "testnet declared on anvil");
        assertEq(uint8(DeployEnvironment.resolve(1, "testnet", false)), uint8(U), "mainnet declared testnet");
        // undeclared / production / typos
        assertEq(uint8(DeployEnvironment.resolve(1, "", false)), uint8(DeployEnvironment.Kind.PRODUCTION));
        assertEq(uint8(DeployEnvironment.resolve(1, "mainnet", false)), uint8(DeployEnvironment.Kind.PRODUCTION));
        assertEq(uint8(DeployEnvironment.resolve(11155111, "", false)), uint8(U), "undeclared testnet");
        assertEq(uint8(DeployEnvironment.resolve(31337, "Local", true)), uint8(U), "case-sensitive");
        assertEq(uint8(DeployEnvironment.resolve(999999, "testnet", false)), uint8(U));
        assertTrue(DeployEnvironment.deploymentAllowed(DeployEnvironment.Kind.FORK));
        assertFalse(DeployEnvironment.deploymentAllowed(DeployEnvironment.Kind.PRODUCTION));
        assertFalse(DeployEnvironment.deploymentAllowed(U));
    }

    /// The scripts must never print a readiness claim. Source-level guard against regressions (Jexi 019).
    function test_scriptsNeverClaimMainnetProduction() public view {
        string[3] memory files =
            ["script/DeploySupaDex.s.sol", "script/VerifyDeployments.s.sol", "script/DeployEnvironment.sol"];
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

    // ---- remediation-3: value-bearing gates (conditions 3, 10, 11; Edith 6-B, 10-A, 10-C)

    function test_valueBearingClassification() public pure {
        assertFalse(DeployEnvironment.valueBearing(DeployEnvironment.Kind.LOCAL, 31337));
        assertFalse(DeployEnvironment.valueBearing(DeployEnvironment.Kind.TESTNET, 11155111));
        assertFalse(DeployEnvironment.valueBearing(DeployEnvironment.Kind.FORK, 31337), "fork of a local chain");
        assertFalse(DeployEnvironment.valueBearing(DeployEnvironment.Kind.FORK, 84532), "fork of a testnet");
        assertTrue(DeployEnvironment.valueBearing(DeployEnvironment.Kind.FORK, 1), "fork of mainnet");
        assertTrue(DeployEnvironment.valueBearing(DeployEnvironment.Kind.FORK, 8453), "fork of Base");
        assertTrue(DeployEnvironment.valueBearing(DeployEnvironment.Kind.PRODUCTION, 1));
        assertTrue(DeployEnvironment.valueBearing(DeployEnvironment.Kind.UNKNOWN, 424242), "fail closed");
    }

    function _safeCfg() internal returns (DeploySupaDex.RoleConfig memory c) {
        c = _cfg();
        c.proposer = address(new MockSafe(3, 5));
        c.executor = address(new MockSafe(2, 3));
        c.canceller = address(new MockSafe(2, 3));
        c.guardian = address(new MockSafe(2, 3));
        c.operator = address(new MockSafe(2, 3));
    }

    function _forkMainnet() internal returns (DeployHarness d, VerifyHarness v) {
        vm.chainId(1);
        d = new DeployHarness();
        v = new VerifyHarness();
        d.setKind(DeployEnvironment.Kind.FORK);
        v.setKind(DeployEnvironment.Kind.FORK);
    }

    /// Fork of a value-bearing chain: BIN is paused at genesis, the timelock floor is 48 h, and verification
    /// passes only when every role holder is a multisig.
    function test_valueBearing_forkDeploy_pausesBin_andPassesWithSafes() public {
        (DeployHarness d, VerifyHarness v) = _forkMainnet();
        DeploySupaDex.RoleConfig memory cfg = _safeCfg();
        DeploySupaDex.DeploymentResult memory res = d.deploy(address(d), cfg);
        CircuitBreaker cb = CircuitBreaker(res.circuitBreaker);
        assertTrue(cb.isCurvePaused(1), "BIN_AMM paused at genesis");
        assertFalse(cb.isCurvePaused(0) || cb.isCurvePaused(2), "CLAMM / STABLE live");
        assertEq(cb.owner(), res.timelock, "breaker handed to the timelock");
        assertEq(SupaTimelock(payable(res.timelock)).delayFloor(), 48 hours);
        VerifyDeployments.Report memory r = v.verify(res, cfg, address(d));
        assertEq(r.failures, 0);
    }

    function test_valueBearing_eoaRoleHoldersBlocked() public {
        (DeployHarness d, VerifyHarness v) = _forkMainnet();
        DeploySupaDex.DeploymentResult memory res = d.deploy(address(d), _cfg()); // EOAs
        VerifyDeployments.Report memory r = v.check(res, _cfg(), address(d));
        assertEq(r.failures, 5, "proposer, executor, canceller, guardian, operator are not multisigs");
        vm.expectRevert(bytes(DeployEnvironment.DEPLOYMENT_BLOCKED));
        v.verify(res, _cfg(), address(d));
        // the same EOA config is fine on a local chain (not value-bearing)
        vm.chainId(31337);
        DeploySupaDex.DeploymentResult memory local = deployer.deploy(address(deployer), _cfg());
        assertEq(verifier.verify(local, _cfg(), address(deployer)).failures, 0);
        assertFalse(CircuitBreaker(local.circuitBreaker).isCurvePaused(1), "BIN live on local chains by default");
    }

    function test_valueBearing_binUnpausedBlocked() public {
        (DeployHarness d, VerifyHarness v) = _forkMainnet();
        DeploySupaDex.RoleConfig memory cfg = _safeCfg();
        DeploySupaDex.DeploymentResult memory res = d.deploy(address(d), cfg);
        vm.prank(res.timelock);
        CircuitBreaker(res.circuitBreaker).unpauseCurve(1);
        VerifyDeployments.Report memory r = v.check(res, cfg, address(d));
        assertEq(r.failures, 1, "only the BIN pause check fails");
    }

    function test_valueBearing_guardianEqualsProposerBlocked() public {
        (DeployHarness d, VerifyHarness v) = _forkMainnet();
        DeploySupaDex.RoleConfig memory cfg = _safeCfg();
        cfg.guardian = cfg.proposer;
        DeploySupaDex.DeploymentResult memory res = d.deploy(address(d), cfg);
        VerifyDeployments.Report memory r = v.check(res, cfg, address(d));
        assertEq(r.failures, 1, "GUARDIAN != PROPOSER");
    }

    function test_valueBearing_shortDelayRefusedOnChain() public {
        (DeployHarness d,) = _forkMainnet();
        DeploySupaDex.RoleConfig memory cfg = _safeCfg();
        cfg.timelockDelay = 24 hours;
        vm.expectRevert(); // SupaTimelock: InvalidDelay (48 h floor on chain id 1)
        d.deploy(address(d), cfg);
    }

    function test_binPausedOptIn_onTestChains() public {
        vm.setEnv("BIN_PAUSED", "true");
        DeploySupaDex.DeploymentResult memory res = _deploy();
        assertTrue(CircuitBreaker(res.circuitBreaker).isCurvePaused(1));
        vm.setEnv("BIN_PAUSED", "false");
    }

    function test_isMultisig_recognition() public {
        assertFalse(verifier.isMultisig(address(0xBEEF)), "EOA");
        assertFalse(verifier.isMultisig(address(new NotASafe())), "contract without Safe interface");
        assertFalse(verifier.isMultisig(address(new MockSafe(1, 3))), "threshold 1 is not a multisig");
        assertFalse(verifier.isMultisig(address(new MockSafe(3, 2))), "threshold above owner count");
        assertTrue(verifier.isMultisig(address(new MockSafe(2, 3))));
        assertTrue(verifier.isMultisig(address(new MockSafe(3, 5))));
    }
}
