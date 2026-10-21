// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {IVault} from "../../contract/interfaces/IVault.sol";
import {ICurveEngine} from "../../contract/interfaces/ICurveEngine.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";

/// @dev TEST-ONLY: re-enables BIN_AMM pool creation so legacy BinAMM accounting tests keep running.
/// Production `SupaPoolManager` refuses BIN_AMM pools (ADR-0004); see BaselineRegression tests.
contract BinEnabledTestPoolManager is SupaPoolManager {
    constructor(IVault v, ICurveEngine c, ICurveEngine b, ICurveEngine s) SupaPoolManager(v, c, b, s) {}

    function binAmmEnabled() public pure override returns (bool) {
        return true;
    }
}

/**
 * @title SecurityTestSetup
 * @notice Shared helpers for predicted-CREATE engine binding + mandatory plugin whitelist.
 */
library SecurityTestSetup {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /**
     * @dev Deploy CLAMM/Bin/Stable engines bound to the next PoolManager CREATE address,
     * then deploy PoolManager with those engines (keeps PM initcode under EIP-3860).
     */
    function deployManagerWithEngines(IVault vault)
        internal
        returns (SupaPoolManager manager, CLAMMEngine clamm, BinAMMEngine bin, StableAMMEngine stable)
    {
        return _deploy(vault, false);
    }

    /// @dev TEST-ONLY variant with BIN_AMM pools enabled (see `BinEnabledTestPoolManager`).
    function deployManagerWithEnginesBinEnabled(IVault vault)
        internal
        returns (SupaPoolManager manager, CLAMMEngine clamm, BinAMMEngine bin, StableAMMEngine stable)
    {
        return _deploy(vault, true);
    }

    function _deploy(IVault vault, bool binEnabled)
        private
        returns (SupaPoolManager manager, CLAMMEngine clamm, BinAMMEngine bin, StableAMMEngine stable)
    {
        address deployer = address(this);
        uint64 nonce = VM.getNonce(deployer);
        address predicted = VM.computeCreateAddress(deployer, nonce + 3);

        clamm = new CLAMMEngine(predicted);
        bin = new BinAMMEngine(predicted);
        stable = new StableAMMEngine(predicted);
        if (binEnabled) {
            manager = new BinEnabledTestPoolManager(
                vault, ICurveEngine(address(clamm)), ICurveEngine(address(bin)), ICurveEngine(address(stable))
            );
        } else {
            manager = new SupaPoolManager(
                vault, ICurveEngine(address(clamm)), ICurveEngine(address(bin)), ICurveEngine(address(stable))
            );
        }
        require(address(manager) == predicted, "SecurityTestSetup: PM address mismatch");
    }

    /// @dev No-op kept for call-site compatibility; engines are bound at PoolManager construction.
    function bindEngines(SupaPoolManager, ICurveEngine, ICurveEngine, ICurveEngine) internal pure {}

    function installEmptyWhitelist(SupaPoolManager manager, address owner) internal returns (PluginWhitelist w) {
        address[] memory none = new address[](0);
        w = new PluginWhitelist(owner, none);
        manager.setPluginWhitelist(IPluginWhitelist(address(w)));
    }
}
