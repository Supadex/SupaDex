// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
        PRODUCTION // value-bearing networks: deployment blocked by this remediation
    }

    string internal constant ENVIRONMENT_VERIFIED = "ENVIRONMENT VERIFIED";
    string internal constant CONFIGURATION_VALIDATED = "CONFIGURATION VALIDATED";
    string internal constant DEPLOYMENT_CHECKS_PASSED = "DEPLOYMENT CHECKS PASSED";
    string internal constant DEPLOYMENT_BLOCKED = "DEPLOYMENT BLOCKED";
    string internal constant PRODUCTION_READINESS_NOT_ESTABLISHED = "PRODUCTION READINESS NOT ESTABLISHED";

    function classify(uint256 chainId) internal pure returns (Kind) {
        if (chainId == 31337 || chainId == 1337) return Kind.LOCAL;
        if (
            chainId == 11155111 // Ethereum Sepolia
                || chainId == 17000 // Holesky
                || chainId == 560048 // Hoodi
                || chainId == 84532 // Base Sepolia
                || chainId == 421614 // Arbitrum Sepolia
                || chainId == 11155420 // OP Sepolia
                || chainId == 80002 // Polygon Amoy
                || chainId == 97 // BNB testnet
        ) return Kind.TESTNET;
        if (
            chainId == 1 || chainId == 10 || chainId == 56 || chainId == 137 || chainId == 8453 || chainId == 42161
                || chainId == 43114 || chainId == 324 || chainId == 59144 || chainId == 534352 || chainId == 100
                || chainId == 250 || chainId == 1101 || chainId == 5000 || chainId == 81457
        ) return Kind.PRODUCTION;
        return Kind.UNKNOWN;
    }

    function label(Kind kind) internal pure returns (string memory) {
        if (kind == Kind.LOCAL) return "local development chain";
        if (kind == Kind.TESTNET) return "public testnet";
        if (kind == Kind.PRODUCTION) return "value-bearing network";
        return "unknown chain";
    }

    /// @notice Only LOCAL and TESTNET chains may be deployed to. UNKNOWN and PRODUCTION fail closed.
    function deploymentAllowed(Kind kind) internal pure returns (bool) {
        return kind == Kind.LOCAL || kind == Kind.TESTNET;
    }
}
