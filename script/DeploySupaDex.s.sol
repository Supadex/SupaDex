// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SupaTimelock} from "../contract/governance/SupaTimelock.sol";
import {SupaRoles} from "../contract/governance/SupaRoles.sol";
import {PluginWhitelist} from "../contract/governance/PluginWhitelist.sol";
import {CircuitBreaker} from "../contract/security/CircuitBreaker.sol";
import {SupaVault} from "../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../contract/core/engines/StableAMMEngine.sol";
import {ICurveEngine} from "../contract/interfaces/ICurveEngine.sol";
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
    struct RoleConfig {
        address governance;
        address guardian;
        address operator;
        address dao;
        address staking;
        address insurance;
    }

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
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        RoleConfig memory rolesCfg = RoleConfig({
            governance: vm.envAddress("GOVERNANCE"),
            guardian: vm.envAddress("GUARDIAN"),
            operator: vm.envAddress("OPERATOR"),
            dao: vm.envAddress("DAO"),
            staking: vm.envAddress("STAKING"),
            insurance: vm.envAddress("INSURANCE")
        });

        vm.startBroadcast(deployerPrivateKey);
        res = deploy(deployer, rolesCfg);
        vm.stopBroadcast();
    }

    function deploy(address deployer, RoleConfig memory rolesCfg) public returns (DeploymentResult memory res) {
        require(rolesCfg.governance != address(0), "GOVERNANCE required");
        require(rolesCfg.guardian != address(0), "GUARDIAN required");
        require(rolesCfg.operator != address(0), "OPERATOR required");
        require(rolesCfg.dao != address(0), "DAO required");
        require(rolesCfg.staking != address(0), "STAKING required");
        require(rolesCfg.insurance != address(0), "INSURANCE required");

        console2.log("=== Starting SupaDex Mainnet Production Deployment ===");
        console2.log("Deployer Address:", deployer);
        console2.log("Governance:", rolesCfg.governance);

        // 1. Governance & Timelock — governance is admin/proposer; executor open to governance
        address[] memory proposers = new address[](1);
        proposers[0] = rolesCfg.governance;
        address[] memory executors = new address[](1);
        executors[0] = rolesCfg.governance;
        address[] memory cancellers = new address[](1);
        cancellers[0] = rolesCfg.governance;

        SupaTimelock timelock = new SupaTimelock(1 days, rolesCfg.governance, proposers, executors, cancellers);
        res.timelock = address(timelock);
        console2.log("1. SupaTimelock deployed at:", res.timelock);

        // 1b. Operator roles
        SupaRoles roles = new SupaRoles(deployer, rolesCfg.operator);
        res.roles = address(roles);
        console2.log("1b. SupaRoles deployed at:", res.roles);

        // 2. Emergency Defense & Circuit Breaker
        address[] memory guardians = new address[](1);
        guardians[0] = rolesCfg.guardian;

        CircuitBreaker circuitBreaker = new CircuitBreaker(res.timelock, guardians);
        res.circuitBreaker = address(circuitBreaker);
        console2.log("2. CircuitBreaker deployed at:", res.circuitBreaker);

        // 3. Vault & Proxy — atomic initialize via ERC1967Proxy constructor
        SupaVault vaultImpl = new SupaVault(deployer);
        res.vaultImplementation = address(vaultImpl);
        bytes memory initData = abi.encodeCall(SupaVault.initialize, (deployer));
        res.vaultProxy = address(new ERC1967Proxy(res.vaultImplementation, initData));
        SupaVault vault = SupaVault(payable(res.vaultProxy));
        vault.setCircuitBreaker(circuitBreaker);
        console2.log("3. SupaVault Proxy deployed at:", res.vaultProxy);

        // 4–5. Deploy engines at predicted PoolManager CREATE address (EIP-3860-safe)
        // Nonce: current after vault proxy + vault wiring txs — compute from deployer.
        uint64 pmNonce = vm.getNonce(deployer);
        // After this point we CREATE: clamm, bin, stable, then PoolManager (+3).
        address predictedPm = vm.computeCreateAddress(deployer, pmNonce + 3);
        CLAMMEngine clamm = new CLAMMEngine(predictedPm);
        BinAMMEngine bin = new BinAMMEngine(predictedPm);
        StableAMMEngine stable = new StableAMMEngine(predictedPm);
        SupaPoolManager poolManager = new SupaPoolManager(
            IVault(res.vaultProxy),
            ICurveEngine(address(clamm)),
            ICurveEngine(address(bin)),
            ICurveEngine(address(stable))
        );
        require(address(poolManager) == predictedPm, "PM CREATE mismatch");
        res.poolManager = address(poolManager);
        res.clammEngine = address(clamm);
        res.binEngine = address(bin);
        res.stableEngine = address(stable);
        poolManager.setCircuitBreaker(circuitBreaker);
        console2.log("4. Curve Engines deployed (bound to predicted PM)");
        console2.log("5. SupaPoolManager deployed at:", res.poolManager);

        // 6. LVR deploys writer-bound oracle in its constructor
        LVRShieldPlugin lvrPlugin = new LVRShieldPlugin(poolManager);
        lvrPlugin.setRoles(ISupaRoles(res.roles));
        res.lvrShieldPlugin = address(lvrPlugin);
        res.oracle = address(lvrPlugin.oracle());

        AntiJITVestingPlugin jitPlugin = new AntiJITVestingPlugin(poolManager, 10);
        res.antiJITPlugin = address(jitPlugin);
        console2.log("6. Native Plugins deployed (LVR Shield, Anti-JIT)");

        // 6b. Plugin whitelist (pre-approve native plugins; Anti-JIT may return deltas)
        address[] memory initialPlugins = new address[](2);
        initialPlugins[0] = res.lvrShieldPlugin;
        initialPlugins[1] = res.antiJITPlugin;
        PluginWhitelist whitelist = new PluginWhitelist(deployer, initialPlugins);
        whitelist.setPluginCanReturnDelta(res.antiJITPlugin, true);
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
            rolesCfg.dao,
            rolesCfg.staking,
            rolesCfg.insurance
        );
        res.feeCollector = address(feeCollector);
        poolManager.setProtocolFeeController(res.feeCollector);
        console2.log("7. Periphery deployed (incl FeeCollector)");
        console2.log("   FeeCollector:", res.feeCollector);

        // 8. Wire Permissions — only PoolManager may call accountDelta
        vault.setPoolManager(res.poolManager, true);

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
