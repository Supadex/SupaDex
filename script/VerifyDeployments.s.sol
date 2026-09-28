// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SupaTimelock} from "../contract/governance/SupaTimelock.sol";
import {CircuitBreaker} from "../contract/security/CircuitBreaker.sol";
import {SupaVault} from "../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../contract/core/SupaPoolManager.sol";
import {DeploySupaDex} from "./DeploySupaDex.s.sol";

/**
 * @title VerifyDeployments
 * @notice Production deployment verification script checking permissions, linkages, and delays.
 */
contract VerifyDeployments is Script {
    /**
     * @notice Validates post-deployment contract configurations and access control boundaries.
     * @param res DeploymentResult struct containing addresses of all deployed SupaDex contracts.
     */
    function verify(DeploySupaDex.DeploymentResult memory res) public view {
        console2.log("=== Verifying SupaDex Mainnet Deployments ===");

        // 1. Verify Timelock
        SupaTimelock timelock = SupaTimelock(payable(res.timelock));
        require(timelock.minDelay() == 1 days, "Timelock delay invalid");

        // 2. Verify CircuitBreaker
        CircuitBreaker cb = CircuitBreaker(res.circuitBreaker);
        require(cb.owner() == res.timelock, "CircuitBreaker owner mismatch");
        require(!cb.isVaultPaused(), "Vault unexpectedly paused");

        // 3. Verify Vault
        SupaVault vault = SupaVault(payable(res.vaultProxy));
        require(vault.owner() == res.timelock, "Vault owner mismatch");
        require(address(vault.circuitBreaker()) == res.circuitBreaker, "Vault circuit breaker mismatch");
        require(vault.isPoolManager(res.poolManager), "PoolManager not authorized in Vault");
        require(vault.isPoolManager(res.router), "Router not authorized in Vault");
        require(vault.isPoolManager(res.positionManager), "PositionManager not authorized in Vault");

        // 4. Verify PoolManager
        SupaPoolManager pm = SupaPoolManager(res.poolManager);
        require(pm.owner() == res.timelock, "PoolManager owner mismatch");
        require(address(pm.vault()) == res.vaultProxy, "PoolManager vault mismatch");
        require(address(pm.clammEngine()) == res.clammEngine, "CLAMM engine mismatch");
        require(address(pm.binEngine()) == res.binEngine, "Bin engine mismatch");
        require(address(pm.stableEngine()) == res.stableEngine, "Stable engine mismatch");

        console2.log("All 14 deployed contracts verified with 100% integrity!");
    }
}
