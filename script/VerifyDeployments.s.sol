// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SupaTimelock} from "../contract/governance/SupaTimelock.sol";
import {SupaRoles} from "../contract/governance/SupaRoles.sol";
import {PluginWhitelist} from "../contract/governance/PluginWhitelist.sol";
import {CircuitBreaker} from "../contract/security/CircuitBreaker.sol";
import {SupaVault} from "../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../contract/core/engines/CLAMMEngine.sol";
import {LVRShieldPlugin} from "../contract/plugins/native/LVRShieldPlugin.sol";
import {VolatilityTWAPOracle} from "../contract/plugins/native/VolatilityTWAPOracle.sol";
import {SupaPositionManager} from "../contract/periphery/SupaPositionManager.sol";
import {SupaRouter} from "../contract/periphery/SupaRouter.sol";
import {SupaQuoter} from "../contract/periphery/SupaQuoter.sol";
import {SupaFeeCollector} from "../contract/periphery/SupaFeeCollector.sol";
import {DeploySupaDex} from "./DeploySupaDex.s.sol";
import {DeployEnvironment} from "./DeployEnvironment.sol";

/**
 * @title VerifyDeployments
 * @notice Jexi 019: fail-closed post-deployment verification. Every check runs; any failure ⇒ DEPLOYMENT BLOCKED
 *         (revert). Success prints ENVIRONMENT VERIFIED / CONFIGURATION VALIDATED / DEPLOYMENT CHECKS PASSED and
 *         ALWAYS PRODUCTION READINESS NOT ESTABLISHED — wiring checks cannot establish production readiness.
 */
contract VerifyDeployments is Script {
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Report {
        uint256 checks;
        uint256 failures;
    }

    /// @notice Reads recorded addresses (SUPADEX_* env) and the INTENDED role config (env) and verifies.
    DeployEnvironment.Kind internal resolvedKind;
    bool internal resolved;

    function run() external {
        bool localNode;
        try vm.rpc("anvil_nodeInfo", "[]") returns (bytes memory) {
            localNode = true;
        } catch {}
        resolvedKind = DeployEnvironment.resolve(block.chainid, vm.envOr("DEPLOY_ENV", string("")), localNode);
        resolved = true;
        DeploySupaDex.DeploymentResult memory res = _resFromEnv();
        DeploySupaDex.RoleConfig memory cfg = DeploySupaDex.RoleConfig({
            governance: vm.envAddress("GOVERNANCE"),
            proposer: vm.envAddress("PROPOSER"),
            executor: vm.envAddress("EXECUTOR"),
            canceller: vm.envAddress("CANCELLER"),
            guardian: vm.envAddress("GUARDIAN"),
            operator: vm.envAddress("OPERATOR"),
            dao: vm.envAddress("DAO"),
            staking: vm.envAddress("STAKING"),
            insurance: vm.envAddress("INSURANCE"),
            timelockDelay: vm.envOr("TIMELOCK_DELAY", uint256(2 days))
        });
        verify(res, cfg, vm.envAddress("DEPLOYER"));
    }

    function _resFromEnv() internal view returns (DeploySupaDex.DeploymentResult memory res) {
        res.timelock = vm.envAddress("SUPADEX_TIMELOCK");
        res.roles = vm.envAddress("SUPADEX_ROLES");
        res.pluginWhitelist = vm.envAddress("SUPADEX_PLUGIN_WHITELIST");
        res.circuitBreaker = vm.envAddress("SUPADEX_CIRCUIT_BREAKER");
        res.vaultImplementation = vm.envAddress("SUPADEX_VAULT_IMPLEMENTATION");
        res.vaultProxy = vm.envAddress("SUPADEX_VAULT");
        res.poolManager = vm.envAddress("SUPADEX_POOL_MANAGER");
        res.clammEngine = vm.envAddress("SUPADEX_CLAMM_ENGINE");
        res.binEngine = vm.envAddress("SUPADEX_BIN_ENGINE");
        res.stableEngine = vm.envAddress("SUPADEX_STABLE_ENGINE");
        res.oracle = vm.envAddress("SUPADEX_TWAP_ORACLE");
        res.lvrShieldPlugin = vm.envAddress("SUPADEX_LVR_PLUGIN");
        res.antiJITPlugin = vm.envAddress("SUPADEX_ANTI_JIT_PLUGIN");
        res.nftDescriptor = vm.envAddress("SUPADEX_NFT_DESCRIPTOR");
        res.positionManager = vm.envAddress("SUPADEX_POSITION_MANAGER");
        res.router = vm.envAddress("SUPADEX_ROUTER");
        res.quoter = vm.envAddress("SUPADEX_QUOTER");
        res.claimsRouter = vm.envAddress("SUPADEX_CLAIMS_ROUTER");
        res.feeCollector = vm.envAddress("SUPADEX_FEE_COLLECTOR");
    }

    /// @return report Number of checks executed and failed (reverts with DEPLOYMENT BLOCKED if any failed).
    function verify(DeploySupaDex.DeploymentResult memory res, DeploySupaDex.RoleConfig memory cfg, address deployer)
        public
        view
        returns (Report memory report)
    {
        report = check(res, cfg, deployer);
        if (report.failures != 0) {
            console2.log(DeployEnvironment.DEPLOYMENT_BLOCKED, "- failed checks:", report.failures);
            console2.log(DeployEnvironment.PRODUCTION_READINESS_NOT_ESTABLISHED);
            revert(DeployEnvironment.DEPLOYMENT_BLOCKED);
        }
        console2.log(DeployEnvironment.DEPLOYMENT_CHECKS_PASSED, "- checks:", report.checks);
        console2.log(DeployEnvironment.PRODUCTION_READINESS_NOT_ESTABLISHED);
    }

    /// @notice Runs every check without reverting (used by `verify` and by negative tests).
    function check(DeploySupaDex.DeploymentResult memory res, DeploySupaDex.RoleConfig memory cfg, address deployer)
        public
        view
        returns (Report memory r)
    {
        // ---- Environment
        DeployEnvironment.Kind kind = resolved ? resolvedKind : DeployEnvironment.classify(block.chainid);
        console2.log("Chain id:", block.chainid, DeployEnvironment.label(kind));
        _req(r, DeployEnvironment.deploymentAllowed(kind), "chain is an allowed local/testnet chain");
        bool codeOk = _codeChecks(r, res);
        if (r.failures == 0) console2.log(DeployEnvironment.ENVIRONMENT_VERIFIED);
        if (!codeOk) return r; // calling into missing code would revert; already failed closed

        uint256 before = r.failures;
        _timelockChecks(r, res, cfg, deployer);
        _ownershipChecks(r, res);
        _wiringChecks(r, res);
        _pluginChecks(r, res);
        if (r.failures == before) console2.log(DeployEnvironment.CONFIGURATION_VALIDATED);
    }

    function _req(Report memory r, bool ok, string memory what) internal pure {
        r.checks++;
        if (!ok) {
            r.failures++;
            console2.log("  FAIL:", what);
        }
    }

    function _codeChecks(Report memory r, DeploySupaDex.DeploymentResult memory res) internal view returns (bool ok) {
        address[19] memory a = [
            res.timelock,
            res.roles,
            res.pluginWhitelist,
            res.circuitBreaker,
            res.vaultImplementation,
            res.vaultProxy,
            res.poolManager,
            res.clammEngine,
            res.binEngine,
            res.stableEngine,
            res.oracle,
            res.lvrShieldPlugin,
            res.antiJITPlugin,
            res.nftDescriptor,
            res.positionManager,
            res.router,
            res.quoter,
            res.claimsRouter,
            res.feeCollector
        ];
        ok = true;
        for (uint256 i; i < a.length; ++i) {
            bool has = a[i] != address(0) && a[i].code.length > 0;
            _req(r, has, "contract code present at recorded address");
            ok = ok && has;
        }
    }

    function _timelockChecks(
        Report memory r,
        DeploySupaDex.DeploymentResult memory res,
        DeploySupaDex.RoleConfig memory cfg,
        address deployer
    ) internal view {
        SupaTimelock tl = SupaTimelock(payable(res.timelock));
        _req(r, tl.minDelay() >= tl.MINIMUM_DELAY(), "timelock delay >= MINIMUM_DELAY");
        _req(r, tl.minDelay() == cfg.timelockDelay, "timelock delay == configured TIMELOCK_DELAY");
        _req(r, tl.isProposer(cfg.proposer), "PROPOSER holds proposer role");
        _req(r, tl.isExecutor(cfg.executor), "EXECUTOR holds executor role");
        _req(r, tl.isCanceller(cfg.canceller), "CANCELLER holds canceller role");
        _req(r, cfg.proposer != cfg.executor, "proposer != executor (ADR-0010)");
        _req(r, !tl.isExecutor(cfg.proposer) && !tl.isProposer(cfg.executor), "no proposer/executor overlap");
        _req(
            r,
            tl.proposerCount() == 1 && tl.executorCount() == 1 && tl.cancellerCount() == 1,
            "exactly the configured role holders"
        );
        _req(
            r,
            !tl.isProposer(deployer) && !tl.isExecutor(deployer) && !tl.isCanceller(deployer),
            "deployer holds no timelock role"
        );
    }

    function _ownershipChecks(Report memory r, DeploySupaDex.DeploymentResult memory res) internal view {
        _req(r, SupaVault(payable(res.vaultProxy)).owner() == res.timelock, "vault owner == timelock");
        _req(r, SupaPoolManager(res.poolManager).owner() == res.timelock, "pool manager owner == timelock");
        _req(r, SupaRoles(res.roles).owner() == res.timelock, "roles owner == timelock");
        _req(r, PluginWhitelist(res.pluginWhitelist).owner() == res.timelock, "plugin whitelist owner == timelock");
        _req(r, SupaFeeCollector(payable(res.feeCollector)).owner() == res.timelock, "fee collector owner == timelock");
        _req(r, CircuitBreaker(res.circuitBreaker).owner() == res.timelock, "circuit breaker owner == timelock");
        address impl = address(uint160(uint256(vm.load(res.vaultProxy, ERC1967_IMPLEMENTATION_SLOT))));
        _req(r, impl == res.vaultImplementation, "vault proxy implementation slot matches");
    }

    function _wiringChecks(Report memory r, DeploySupaDex.DeploymentResult memory res) internal view {
        SupaVault vault = SupaVault(payable(res.vaultProxy));
        SupaPoolManager pm = SupaPoolManager(res.poolManager);
        _req(r, address(vault.circuitBreaker()) == res.circuitBreaker, "vault circuit breaker");
        _req(r, vault.isPoolManager(res.poolManager), "pool manager authorised in vault");
        _req(r, !vault.isPoolManager(res.router), "router NOT a vault pool manager");
        _req(r, !vault.isPoolManager(res.positionManager), "position manager NOT a vault pool manager");
        _req(r, !vault.isPoolManager(res.timelock), "timelock NOT a vault pool manager");
        _req(r, !CircuitBreaker(res.circuitBreaker).isVaultPaused(), "vault not paused");
        _req(r, address(pm.vault()) == res.vaultProxy, "pool manager vault");
        _req(r, address(pm.circuitBreaker()) == res.circuitBreaker, "pool manager circuit breaker");
        _req(r, address(pm.pluginWhitelist()) == res.pluginWhitelist, "pool manager plugin whitelist");
        _req(r, pm.protocolFeeController() == res.feeCollector, "protocol fee controller == fee collector");
        _req(r, address(pm.clammEngine()) == res.clammEngine, "CLAMM engine");
        _req(r, address(pm.binEngine()) == res.binEngine, "Bin engine");
        _req(r, address(pm.stableEngine()) == res.stableEngine, "Stable engine");
        _req(r, pm.binAmmEnabled(), "BIN_AMM enabled (ADR-0006)");
        _req(r, CLAMMEngine(res.clammEngine).poolManager() == res.poolManager, "CLAMM bound to pool manager");
        _req(r, CLAMMEngine(res.binEngine).poolManager() == res.poolManager, "Bin bound to pool manager");
        _req(r, CLAMMEngine(res.stableEngine).poolManager() == res.poolManager, "Stable bound to pool manager");
        _req(r, address(SupaRouter(payable(res.router)).poolManager()) == res.poolManager, "router pool manager");
        _req(r, address(SupaRouter(payable(res.router)).vault()) == res.vaultProxy, "router vault");
        _req(r, address(SupaQuoter(res.quoter).poolManager()) == res.poolManager, "quoter pool manager");
        _req(
            r,
            address(SupaPositionManager(payable(res.positionManager)).poolManager()) == res.poolManager,
            "position manager pool manager"
        );
        _req(
            r,
            address(SupaFeeCollector(payable(res.feeCollector)).poolManager()) == res.poolManager,
            "fee collector pool manager"
        );
        _req(r, SupaFeeCollector(payable(res.feeCollector)).roles() == res.roles, "fee collector roles");
    }

    function _pluginChecks(Report memory r, DeploySupaDex.DeploymentResult memory res) internal view {
        PluginWhitelist wl = PluginWhitelist(res.pluginWhitelist);
        LVRShieldPlugin lvr = LVRShieldPlugin(res.lvrShieldPlugin);
        _req(r, wl.isPluginWhitelisted(res.lvrShieldPlugin), "LVR plugin whitelisted");
        _req(r, wl.isPluginWhitelisted(res.antiJITPlugin), "Anti-JIT plugin whitelisted");
        _req(r, !wl.canPluginReturnDelta(res.lvrShieldPlugin), "LVR plugin cannot return deltas");
        _req(r, wl.canPluginReturnDelta(res.antiJITPlugin), "Anti-JIT plugin may return fee deltas");
        _req(r, address(lvr.poolManager()) == res.poolManager, "LVR plugin pool manager");
        _req(r, address(lvr.roles()) == res.roles, "LVR plugin roles registry");
        _req(r, address(lvr.oracle()) == res.oracle, "LVR TWAP oracle");
        _req(r, VolatilityTWAPOracle(res.oracle).writer() == res.lvrShieldPlugin, "TWAP oracle writer == LVR plugin");
        _req(
            r,
            address(LVRShieldPlugin(res.antiJITPlugin).poolManager()) == res.poolManager,
            "Anti-JIT plugin pool manager"
        );
    }
}
