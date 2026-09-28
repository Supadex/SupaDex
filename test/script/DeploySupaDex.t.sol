// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySupaDex} from "../../script/DeploySupaDex.s.sol";
import {VerifyDeployments} from "../../script/VerifyDeployments.s.sol";

contract DeploySupaDexTest is Test {
    DeploySupaDex public deployer;
    VerifyDeployments public verifier;

    function setUp() external {
        deployer = new DeploySupaDex();
        verifier = new VerifyDeployments();
    }

    function test_deterministicDeploymentAndVerification() public {
        address testDeployer = address(0x9999);
        DeploySupaDex.DeploymentResult memory res = deployer.deploy(testDeployer);

        // Run full verification assertion suite
        verifier.verify(res);

        assertTrue(res.timelock != address(0));
        assertTrue(res.circuitBreaker != address(0));
        assertTrue(res.vaultProxy != address(0));
        assertTrue(res.poolManager != address(0));
        assertTrue(res.clammEngine != address(0));
        assertTrue(res.binEngine != address(0));
        assertTrue(res.stableEngine != address(0));
        assertTrue(res.oracle != address(0));
        assertTrue(res.lvrShieldPlugin != address(0));
        assertTrue(res.antiJITPlugin != address(0));
        assertTrue(res.positionManager != address(0));
        assertTrue(res.router != address(0));
        assertTrue(res.quoter != address(0));
    }
}
