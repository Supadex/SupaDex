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
import {DeployEnvironment} from "./DeployEnvironment.sol";

/**
 * @title DeploySupaDex
 * @notice Deploys the complete SupaDex stack to a LOCAL or TESTNET chain. Value-bearing and unknown chains are
 *         refused (fail closed, Jexi 019). Passing this script means wiring only — PRODUCTION READINESS NOT
 *         ESTABLISHED.
 * @dev ADR-0010 (Jexi 017): proposer, executor and canceller are separate addresses; the deployer keeps no role
 *      and every owner-gated contract ends owned by the timelock.
 */
contract DeploySupaDex is Script {
    struct RoleConfig {
        address governance; // informational timelock `admin` label (no power)
        address proposer; // schedules timelock operations (e.g. governance multisig)
        address executor; // executes ready operations (must differ from proposer)
        address canceller; // cancels pending operations (e.g. security council)
        address guardian; // circuit-breaker pause + StableAMM stopRampA
        address operator; // SupaRoles operator (fee sweeps only)
        address dao;
        address staking;
        address insurance;
        uint256 timelockDelay; // 0 ⇒ DEFAULT_TIMELOCK_DELAY
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

    uint256 public constant DEFAULT_TIMELOCK_DELAY = 2 days;
    uint32 public constant ANTI_JIT_MIN_RESIDENCY_BLOCKS = 10;

    /// @dev Reads PRIVATE_KEY only to sign under `forge script --broadcast`; never logged or stored.
    function run() external returns (DeploymentResult memory res) {
        _resolveEnvironment();
        _requireDeployableChain();
        if (vm.envOr("EXPECTED_CHAIN_ID", uint256(0)) != block.chainid) {
            console2.log(DeployEnvironment.DEPLOYMENT_BLOCKED, "- EXPECTED_CHAIN_ID unset or != block.chainid");
            revert(DeployEnvironment.DEPLOYMENT_BLOCKED);
        }
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        RoleConfig memory rolesCfg = RoleConfig({
            governance: vm.envAddress("GOVERNANCE"),
            proposer: vm.envAddress("PROPOSER"),
            executor: vm.envAddress("EXECUTOR"),
            canceller: vm.envAddress("CANCELLER"),
            guardian: vm.envAddress("GUARDIAN"),
            operator: vm.envAddress("OPERATOR"),
            dao: vm.envAddress("DAO"),
            staking: vm.envAddress("STAKING"),
            insurance: vm.envAddress("INSURANCE"),
            timelockDelay: vm.envOr("TIMELOCK_DELAY", DEFAULT_TIMELOCK_DELAY)
        });

        vm.startBroadcast(deployerPrivateKey);
        res = deploy(deployer, rolesCfg);
        vm.stopBroadcast();
    }

    /// @dev Set by `run()` only after DEPLOY_ENV and the node probe agree (see DeployEnvironment.resolve).
    DeployEnvironment.Kind internal resolvedKind;
    bool internal resolved;

    /// @notice Is the RPC node a local anvil node? Cheatcode RPC; any failure (live node, no RPC) => false.
    function _isLocalNode() internal returns (bool) {
        try vm.rpc("anvil_nodeInfo", "[]") returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _resolveEnvironment() internal {
        string memory declared = vm.envOr("DEPLOY_ENV", string(""));
        resolvedKind = DeployEnvironment.resolve(block.chainid, declared, _isLocalNode());
        resolved = true;
        console2.log("Declared DEPLOY_ENV:", declared);
    }

    function _requireDeployableChain() internal view {
        DeployEnvironment.Kind kind = _kind();
        console2.log("Chain id:", block.chainid);
        console2.log("Environment:", DeployEnvironment.label(kind));
        if (!DeployEnvironment.deploymentAllowed(kind)) {
            console2.log(DeployEnvironment.DEPLOYMENT_BLOCKED, "- chain is not an allowed local/testnet chain");
            revert(DeployEnvironment.DEPLOYMENT_BLOCKED);
        }
        console2.log(DeployEnvironment.ENVIRONMENT_VERIFIED);
    }

    function _kind() internal view returns (DeployEnvironment.Kind) {
        return resolved ? resolvedKind : DeployEnvironment.classify(block.chainid);
    }

    /// @notice ADR-0006 / Edith 6-B: BIN stays paused on any value-bearing deployment until Jexi review AND an
    /// external audit sign off (unpausing is a timelock action). Optional on test chains via BIN_PAUSED=true.
    function binPausedAtGenesis() public view returns (bool) {
        return DeployEnvironment.valueBearing(_kind(), block.chainid) || binPausedOptIn();
    }

    /// @notice Operator opt-in (BIN_PAUSED=true). Virtual so tests can exercise the opt-in without mutating the
    /// process-wide environment, which raced with other suites running in parallel (flaky CurvePaused in setUp).
    function binPausedOptIn() public view virtual returns (bool) {
        return vm.envOr("BIN_PAUSED", false);
    }

    function validateConfig(address deployer, RoleConfig memory c) public pure {
        require(c.governance != address(0), "GOVERNANCE required");
        require(c.proposer != address(0), "PROPOSER required");
        require(c.executor != address(0), "EXECUTOR required");
        require(c.canceller != address(0), "CANCELLER required");
        require(c.guardian != address(0), "GUARDIAN required");
        require(c.operator != address(0), "OPERATOR required");
        require(c.dao != address(0), "DAO required");
        require(c.staking != address(0), "STAKING required");
        require(c.insurance != address(0), "INSURANCE required");
        require(c.proposer != c.executor, "PROPOSER and EXECUTOR must differ (ADR-0010)");
        require(
            deployer != c.proposer && deployer != c.executor && deployer != c.canceller && deployer != c.governance,
            "deployer must hold no timelock role"
        );
    }

    function deploy(address deployer, RoleConfig memory rolesCfg) public returns (DeploymentResult memory res) {
        _requireDeployableChain();
        validateConfig(deployer, rolesCfg);
        if (rolesCfg.timelockDelay == 0) rolesCfg.timelockDelay = DEFAULT_TIMELOCK_DELAY;
        console2.log(DeployEnvironment.CONFIGURATION_VALIDATED);
        console2.log(
            "=== SupaDex deployment (wiring only;", DeployEnvironment.PRODUCTION_READINESS_NOT_ESTABLISHED, ") ==="
        );
        console2.log("Deployer:", deployer);

        _deployGovernance(deployer, rolesCfg, res);
        _deployCore(deployer, res);
        _deployPlugins(deployer, res);
        _deployPeriphery(deployer, rolesCfg, res);
        _handOff(res);
        console2.log("Deployment transactions complete. Run VerifyDeployments before any use.");
        console2.log(DeployEnvironment.PRODUCTION_READINESS_NOT_ESTABLISHED);
    }

    function _deployGovernance(address deployer, RoleConfig memory c, DeploymentResult memory res) internal {
        address[] memory proposers = new address[](1);
        proposers[0] = c.proposer;
        address[] memory executors = new address[](1);
        executors[0] = c.executor;
        address[] memory cancellers = new address[](1);
        cancellers[0] = c.canceller;
        res.timelock = address(new SupaTimelock(c.timelockDelay, c.governance, proposers, executors, cancellers));
        console2.log("1. SupaTimelock:", res.timelock);

        res.roles = address(new SupaRoles(deployer, c.operator));
        console2.log("1b. SupaRoles:", res.roles);

        address[] memory guardians = new address[](1);
        guardians[0] = c.guardian;
        // Deployer owns the breaker only until _handOff (needed to pause BIN at genesis), then the timelock.
        res.circuitBreaker = address(new CircuitBreaker(deployer, guardians));
        console2.log("2. CircuitBreaker:", res.circuitBreaker);
        if (binPausedAtGenesis()) {
            CircuitBreaker(res.circuitBreaker).pauseCurve(uint8(1)); // CurveType.BIN_AMM
            console2.log("2b. BIN_AMM curve PAUSED at genesis (value-bearing; unpause needs Jexi + external audit)");
        }
    }

    function _deployCore(address deployer, DeploymentResult memory res) internal {
        // Vault & proxy — atomic initialize via the ERC1967Proxy constructor.
        res.vaultImplementation = address(new SupaVault(deployer));
        bytes memory initData = abi.encodeCall(SupaVault.initialize, (deployer));
        res.vaultProxy = address(new ERC1967Proxy(res.vaultImplementation, initData));
        SupaVault(payable(res.vaultProxy)).setCircuitBreaker(CircuitBreaker(res.circuitBreaker));
        console2.log("3. SupaVault proxy:", res.vaultProxy);

        // Engines bound to the predicted PoolManager CREATE address (EIP-3860-safe): clamm, bin, stable, PM.
        address predictedPm = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        res.clammEngine = address(new CLAMMEngine(predictedPm));
        res.binEngine = address(new BinAMMEngine(predictedPm));
        res.stableEngine = address(new StableAMMEngine(predictedPm));
        res.poolManager = address(
            new SupaPoolManager(
                IVault(res.vaultProxy),
                ICurveEngine(res.clammEngine),
                ICurveEngine(res.binEngine),
                ICurveEngine(res.stableEngine)
            )
        );
        require(res.poolManager == predictedPm, "PM CREATE mismatch");
        SupaPoolManager(res.poolManager).setCircuitBreaker(CircuitBreaker(res.circuitBreaker));
        console2.log("4-5. Engines + SupaPoolManager:", res.poolManager);
    }

    function _deployPlugins(address deployer, DeploymentResult memory res) internal {
        SupaPoolManager pm = SupaPoolManager(res.poolManager);
        LVRShieldPlugin lvr = new LVRShieldPlugin(pm);
        lvr.setRoles(ISupaRoles(res.roles)); // roles.owner() becomes the timelock in _handOff
        res.lvrShieldPlugin = address(lvr);
        res.oracle = address(lvr.oracle());
        res.antiJITPlugin = address(new AntiJITVestingPlugin(pm, ANTI_JIT_MIN_RESIDENCY_BLOCKS));
        console2.log("6. LVRShieldPlugin / AntiJITVestingPlugin:", res.lvrShieldPlugin, res.antiJITPlugin);

        address[] memory initialPlugins = new address[](2);
        initialPlugins[0] = res.lvrShieldPlugin;
        initialPlugins[1] = res.antiJITPlugin;
        PluginWhitelist whitelist = new PluginWhitelist(deployer, initialPlugins);
        whitelist.setPluginCanReturnDelta(res.antiJITPlugin, true);
        res.pluginWhitelist = address(whitelist);
        pm.setPluginWhitelist(IPluginWhitelist(res.pluginWhitelist));
        console2.log("6b. PluginWhitelist:", res.pluginWhitelist);
    }

    function _deployPeriphery(address deployer, RoleConfig memory c, DeploymentResult memory res) internal {
        SupaPoolManager pm = SupaPoolManager(res.poolManager);
        IVault v = IVault(res.vaultProxy);
        res.nftDescriptor = address(new PositionNFTDescriptor());
        res.positionManager = address(new SupaPositionManager(pm, v, res.nftDescriptor));
        res.router = address(new SupaRouter(pm, v));
        res.quoter = address(new SupaQuoter(pm, v));
        res.claimsRouter = address(new SupaClaimsRouter(v));
        res.feeCollector =
            address(new SupaFeeCollector(pm, v, ISupaRoles(res.roles), deployer, c.dao, c.staking, c.insurance));
        pm.setProtocolFeeController(res.feeCollector);
        console2.log("7. Periphery deployed; FeeCollector:", res.feeCollector);
    }

    function _handOff(DeploymentResult memory res) internal {
        SupaVault(payable(res.vaultProxy)).setPoolManager(res.poolManager, true);
        SupaVault(payable(res.vaultProxy)).transferOwnership(res.timelock);
        SupaPoolManager(res.poolManager).transferOwnership(res.timelock);
        SupaRoles(res.roles).transferOwnership(res.timelock);
        PluginWhitelist(res.pluginWhitelist).transferOwnership(res.timelock);
        SupaFeeCollector(payable(res.feeCollector)).transferOwnership(res.timelock);
        CircuitBreaker(res.circuitBreaker).transferOwnership(res.timelock);
        console2.log(
            "8. Ownership of vault, pool manager, roles, whitelist, fee collector, circuit breaker -> SupaTimelock"
        );
    }
}
