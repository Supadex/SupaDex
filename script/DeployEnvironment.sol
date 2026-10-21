// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ChainIds} from "../contract/libraries/ChainIds.sol";

/**
 * @title DeployEnvironment
 * @notice Jexi 019 / ADR-0010: fail-closed chain classification shared by the deploy and verify scripts.
 * @dev Status vocabulary (exact strings, logged verbatim; nothing else may claim readiness):
 *      ENVIRONMENT VERIFIED, CONFIGURATION VALIDATED, DEPLOYMENT CHECKS PASSED, DEPLOYMENT BLOCKED,
 *      PRODUCTION READINESS NOT ESTABLISHED.
 *      Scripts must never describe a run as a production / mainnet-ready deployment: passing these checks only
 *      means the wiring matches the intended configuration. Production readiness additionally needs an external
 *      audit, governance sign-off and an incident runbook, none of which a script can verify.
 */
library DeployEnvironment {
    enum Kind {
        UNKNOWN, // fail closed
        LOCAL, // anvil / hardhat / local fork
        TESTNET, // public test networks
        PRODUCTION, // value-bearing networks: deployment blocked by this remediation
        FORK // a local anvil node forking any chain (declared DEPLOY_ENV=fork AND the node answers anvil_nodeInfo)
    }

    string internal constant ENVIRONMENT_VERIFIED = "ENVIRONMENT VERIFIED";
    string internal constant CONFIGURATION_VALIDATED = "CONFIGURATION VALIDATED";
    string internal constant DEPLOYMENT_CHECKS_PASSED = "DEPLOYMENT CHECKS PASSED";
    string internal constant DEPLOYMENT_BLOCKED = "DEPLOYMENT BLOCKED";
    string internal constant PRODUCTION_READINESS_NOT_ESTABLISHED = "PRODUCTION READINESS NOT ESTABLISHED";

    function classify(uint256 chainId) internal pure returns (Kind) {
        // LOCAL / TESTNET come from the shared ChainIds allowlist that SupaTimelock.isTestChain also reads
        // (ADR-0010: one list). Monad testnet 10143 and geth-dev 1337 are not on it and resolve to UNKNOWN.
        if (ChainIds.isLocal(chainId)) return Kind.LOCAL;
        if (ChainIds.isTestnet(chainId)) return Kind.TESTNET;
        if (
            chainId == 1 || chainId == 10 || chainId == 56 || chainId == 137 || chainId == 8453 || chainId == 42161
                || chainId == 43114 || chainId == 324 || chainId == 59144 || chainId == 534352 || chainId == 100
                || chainId == 250 || chainId == 1101 || chainId == 5000 || chainId == 81457
        ) return Kind.PRODUCTION;
        return Kind.UNKNOWN;
    }

    /// @notice Resolves the environment from the chain id, the operator's declared DEPLOY_ENV and whether the RPC
    ///         node identified itself as a local anvil node. Any mismatch resolves to UNKNOWN (fail closed):
    ///         - "local":   chain id must be a local id (31337)
    ///         - "fork":    the node must be a local anvil node (chain id may be any, e.g. a mainnet fork)
    ///         - "testnet": chain id must be a known testnet AND the node must not be a local node
    ///         - anything else (unset, "mainnet", "production", typos): PRODUCTION if the id is value-bearing, else UNKNOWN
    function resolve(uint256 chainId, string memory declared, bool localNode) internal pure returns (Kind) {
        Kind base = classify(chainId);
        bytes32 d = keccak256(bytes(declared));
        if (d == keccak256("local")) return base == Kind.LOCAL ? Kind.LOCAL : Kind.UNKNOWN;
        if (d == keccak256("fork")) return localNode ? Kind.FORK : Kind.UNKNOWN;
        if (d == keccak256("testnet")) return (base == Kind.TESTNET && !localNode) ? Kind.TESTNET : Kind.UNKNOWN;
        return base == Kind.PRODUCTION ? Kind.PRODUCTION : Kind.UNKNOWN;
    }

    function label(Kind kind) internal pure returns (string memory) {
        if (kind == Kind.FORK) return "local fork (anvil)";
        if (kind == Kind.LOCAL) return "local development chain";
        if (kind == Kind.TESTNET) return "public testnet";
        if (kind == Kind.PRODUCTION) return "value-bearing network";
        return "unknown chain";
    }

    /**
     * @notice Is this deployment value-bearing (or simulating one)? PRODUCTION and UNKNOWN (fail closed), and a FORK
     * of any chain that is not itself a local/test chain (e.g. an anvil fork of Ethereum mainnet). On value-bearing
     * deployments: BIN paused at genesis (ADR-0006 / Edith 6-B), timelock delay >= 48 h (10-A), every role holder a
     * multisig (10-C).
     */
    function valueBearing(Kind kind, uint256 chainId) internal pure returns (bool) {
        if (kind == Kind.LOCAL || kind == Kind.TESTNET) return false;
        if (kind == Kind.FORK) {
            Kind base = classify(chainId);
            return !(base == Kind.LOCAL || base == Kind.TESTNET);
        }
        return true;
    }

    /// @notice Only LOCAL, FORK and TESTNET may be deployed to. UNKNOWN and PRODUCTION fail closed.
    function deploymentAllowed(Kind kind) internal pure returns (bool) {
        return kind == Kind.LOCAL || kind == Kind.FORK || kind == Kind.TESTNET;
    }
}
