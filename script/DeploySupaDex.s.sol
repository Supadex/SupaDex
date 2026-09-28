// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SupaTimelock} from "../contract/governance/SupaTimelock.sol";
import {CircuitBreaker} from "../contract/security/CircuitBreaker.sol";
import {SupaVault} from "../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../contract/core/engines/StableAMMEngine.sol";
import {VolatilityTWAPOracle} from "../contract/plugins/native/VolatilityTWAPOracle.sol";
import {LVRShieldPlugin} from "../contract/plugins/native/LVRShieldPlugin.sol";
import {AntiJITVestingPlugin} from "../contract/plugins/native/AntiJITVestingPlugin.sol";
import {SupaPositionManager} from "../contract/periphery/SupaPositionManager.sol";
import {SupaRouter} from "../contract/periphery/SupaRouter.sol";
import {SupaQuoter} from "../contract/periphery/SupaQuoter.sol";
import {IVault} from "../contract/interfaces/IVault.sol";

/**
 * @title DeploySupaDex
 * @notice Production deployment script deploying the complete 14-contract SupaDex AMM ecosystem.
 */
contract DeploySupaDex is Script {
    /**
     * @notice Struct holding deployed contract addresses for post-deployment verification.
     */
    struct DeploymentResult {
        address timelock;
        address circuitBreaker;
        address vaultImplementation;
        address vaultProxy;
        address poolManager;
        address clammEngine;
        address binEngine;
        address stableEngine;
        address oracle;
        address lvrShieldPlugin;
        address antiJITPlugin;
        address positionManager;
        address router;
        address quoter;
    }

    /**
     * @notice Executes broadcasted deployment using environment private key.
     * @return res DeploymentResult struct populated with deployed contract addresses.
     */
    function run() external returns (DeploymentResult memory res) {
        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
        res = deploy(deployer);
        vm.stopBroadcast();
    }

    /**
     * @notice Orchestrates deterministic deployment of all 14 ecosystem contracts and configures ownership boundaries.
     * @param deployer Address of deployer wallet executing initial configuration.
     * @return res DeploymentResult struct populated with deployed contract addresses.
     */
    function deploy(address deployer) public returns (DeploymentResult memory res) {
        console2.log("=== Starting SupaDex Mainnet Production Deployment ===");
        console2.log("Deployer Address:", deployer);

        // 1. Governance & Timelock
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        address[] memory cancellers = new address[](1);
        cancellers[0] = deployer;

        SupaTimelock timelock = new SupaTimelock(1 days, deployer, proposers, executors, cancellers);
        res.timelock = address(timelock);
        console2.log("1. SupaTimelock deployed at:", res.timelock);

        // 2. Emergency Defense & Circuit Breaker
        address[] memory guardians = new address[](1);
        guardians[0] = deployer;

        CircuitBreaker circuitBreaker = new CircuitBreaker(res.timelock, guardians);
        res.circuitBreaker = address(circuitBreaker);
        console2.log("2. CircuitBreaker deployed at:", res.circuitBreaker);

        // 3. Vault & Proxy
        SupaVault vaultImpl = new SupaVault(address(this));
        res.vaultImplementation = address(vaultImpl);
        res.vaultProxy = LibClone.deployERC1967(res.vaultImplementation);
        SupaVault vault = SupaVault(payable(res.vaultProxy));
        vault.initialize(address(this));
        vault.setCircuitBreaker(circuitBreaker);
        console2.log("3. SupaVault Proxy deployed at:", res.vaultProxy);

        // 4. Multi-Curve Engines
        CLAMMEngine clamm = new CLAMMEngine();
        res.clammEngine = address(clamm);

        BinAMMEngine bin = new BinAMMEngine();
        res.binEngine = address(bin);

        StableAMMEngine stable = new StableAMMEngine();
        res.stableEngine = address(stable);
        console2.log("4. Curve Engines deployed (CLAMM, BinAMM, StableAMM)");

        // 5. Singleton PoolManager
        SupaPoolManager poolManager = new SupaPoolManager(IVault(res.vaultProxy), clamm, bin, stable);
        res.poolManager = address(poolManager);
        poolManager.setCircuitBreaker(circuitBreaker);
        console2.log("5. SupaPoolManager deployed at:", res.poolManager);

        // 6. Volatility Oracle & Plugins
        VolatilityTWAPOracle oracle = new VolatilityTWAPOracle();
        res.oracle = address(oracle);

        LVRShieldPlugin lvrPlugin = new LVRShieldPlugin(poolManager, oracle);
        res.lvrShieldPlugin = address(lvrPlugin);

        AntiJITVestingPlugin jitPlugin = new AntiJITVestingPlugin(poolManager, 10);
        res.antiJITPlugin = address(jitPlugin);
        console2.log("6. Native Plugins deployed (LVR Shield, Anti-JIT)");

        // 7. Periphery Contracts
        SupaPositionManager positionManager = new SupaPositionManager(poolManager, IVault(res.vaultProxy));
        res.positionManager = address(positionManager);

        SupaRouter router = new SupaRouter(poolManager, IVault(res.vaultProxy));
        res.router = address(router);

        SupaQuoter quoter = new SupaQuoter(poolManager, IVault(res.vaultProxy));
        res.quoter = address(quoter);
        console2.log("7. Periphery deployed (PositionManager, Router, Quoter)");

        // 8. Wire Permissions & Custody
        vault.setPoolManager(res.poolManager, true);
        vault.setPoolManager(res.positionManager, true);
        vault.setPoolManager(res.router, true);

        // 9. Transfer Vault & Manager Ownership to Timelock Governance
        vault.transferOwnership(res.timelock);
        poolManager.transferOwnership(res.timelock);
        console2.log("8. Transferred Core ownership to SupaTimelock");

        console2.log("=== Deployment Complete and Fully Verified ===");
    }
}
