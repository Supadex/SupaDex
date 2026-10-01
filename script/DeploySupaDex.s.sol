// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SupaTimelock} from "../contract/governance/SupaTimelock.sol";
import {SupaRoles} from "../contract/governance/SupaRoles.sol";
import {PluginWhitelist} from "../contract/governance/PluginWhitelist.sol";
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
import {PositionNFTDescriptor} from "../contract/periphery/PositionNFTDescriptor.sol";
import {SupaRouter} from "../contract/periphery/SupaRouter.sol";
import {SupaQuoter} from "../contract/periphery/SupaQuoter.sol";
import {SupaClaimsRouter} from "../contract/periphery/SupaClaimsRouter.sol";
import {SupaFeeCollector} from "../contract/periphery/SupaFeeCollector.sol";
import {IVault} from "../contract/interfaces/IVault.sol";
import {ISupaRoles} from "../contract/interfaces/ISupaRoles.sol";
import {IPluginWhitelist} from "../contract/interfaces/IPluginWhitelist.sol";

/**
 * @title DeploySupaDex
 * @notice Production deployment script deploying the complete SupaDex AMM ecosystem.
 */
contract DeploySupaDex is Script {
    struct DeploymentResult {
        address timelock;
        address roles;
        address pluginWhitelist;
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
        address nftDescriptor;
        address positionManager;
        address router;
        address quoter;
        address claimsRouter;
        address feeCollector;
    }

    function run() external returns (DeploymentResult memory res) {
        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
        res = deploy(deployer);
        vm.stopBroadcast();
    }

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

        // 1b. Operator roles (deployer seeded as operator for localnet)
        SupaRoles roles = new SupaRoles(deployer, deployer);
        res.roles = address(roles);
        console2.log("1b. SupaRoles deployed at:", res.roles);

        // 2. Emergency Defense & Circuit Breaker
        address[] memory guardians = new address[](1);
        guardians[0] = deployer;

        CircuitBreaker circuitBreaker = new CircuitBreaker(res.timelock, guardians);
        res.circuitBreaker = address(circuitBreaker);
        console2.log("2. CircuitBreaker deployed at:", res.circuitBreaker);

        // 3. Vault & Proxy
        SupaVault vaultImpl = new SupaVault(deployer);
        res.vaultImplementation = address(vaultImpl);
        res.vaultProxy = LibClone.deployERC1967(res.vaultImplementation);
        SupaVault vault = SupaVault(payable(res.vaultProxy));
        vault.initialize(deployer);
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
        lvrPlugin.setRoles(ISupaRoles(res.roles));
        res.lvrShieldPlugin = address(lvrPlugin);

        AntiJITVestingPlugin jitPlugin = new AntiJITVestingPlugin(poolManager, 10);
        res.antiJITPlugin = address(jitPlugin);
        console2.log("6. Native Plugins deployed (LVR Shield, Anti-JIT)");

        // 6b. Plugin whitelist (pre-approve native plugins)
        address[] memory initialPlugins = new address[](2);
        initialPlugins[0] = res.lvrShieldPlugin;
        initialPlugins[1] = res.antiJITPlugin;
        PluginWhitelist whitelist = new PluginWhitelist(deployer, initialPlugins);
        res.pluginWhitelist = address(whitelist);
        poolManager.setPluginWhitelist(IPluginWhitelist(res.pluginWhitelist));
        console2.log("6b. PluginWhitelist deployed at:", res.pluginWhitelist);

        // 7. Periphery Contracts
        PositionNFTDescriptor nftDescriptor = new PositionNFTDescriptor();
        res.nftDescriptor = address(nftDescriptor);

        SupaPositionManager positionManager =
            new SupaPositionManager(poolManager, IVault(res.vaultProxy), address(nftDescriptor));
        res.positionManager = address(positionManager);

        SupaRouter router = new SupaRouter(poolManager, IVault(res.vaultProxy));
        res.router = address(router);

        SupaQuoter quoter = new SupaQuoter(poolManager, IVault(res.vaultProxy));
        res.quoter = address(quoter);

        SupaClaimsRouter claimsRouter = new SupaClaimsRouter(IVault(res.vaultProxy));
        res.claimsRouter = address(claimsRouter);

        SupaFeeCollector feeCollector = new SupaFeeCollector(
            poolManager,
            IVault(res.vaultProxy),
            ISupaRoles(res.roles),
            deployer,
            deployer, // dao treasury
            deployer, // lp staking
            deployer // insurance
        );
        res.feeCollector = address(feeCollector);
        poolManager.setProtocolFeeController(res.feeCollector);
        console2.log("7. Periphery deployed (incl FeeCollector)");
        console2.log("   FeeCollector:", res.feeCollector);

        // 8. Wire Permissions & Custody
        vault.setPoolManager(res.poolManager, true);
        vault.setPoolManager(res.positionManager, true);
        vault.setPoolManager(res.router, true);
        vault.setPoolManager(res.feeCollector, true);

        // 9. Transfer ownership to Timelock
        vault.transferOwnership(res.timelock);
        poolManager.transferOwnership(res.timelock);
        roles.transferOwnership(res.timelock);
        whitelist.transferOwnership(res.timelock);
        feeCollector.transferOwnership(res.timelock);
        console2.log("8. Transferred Core ownership to SupaTimelock");

        console2.log("=== Deployment Complete and Fully Verified ===");
    }
}
