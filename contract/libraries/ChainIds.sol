// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ChainIds
 * @notice Single source of truth for chain-id allowlists (Edith R3, ADR-0009 / ADR-0010 conditions).
 *         Used by SupaTimelock (48 h delay floor), LVRShieldPlugin (sequencer-uptime requirement),
 *         DeployEnvironment (deploy / verify classification) and the local-only mock feeds.
 * @dev Every list is an explicit ALLOWLIST and fails closed: an id that is not listed is treated as
 *      value-bearing (48 h floor, deploy blocked) and as needing a sequencer-uptime feed.
 *      Ids checked against chainlist (chainid.network/chains.json) on 2026-10-21.
 */
library ChainIds {
    /// @notice Local development chains. Only anvil / hardhat (31337). 1337 (geth dev) is deliberately NOT
    ///         listed: some appchains reuse it, so it fails closed like any unknown id.
    function isLocal(uint256 chainId) internal pure returns (bool) {
        return chainId == 31337;
    }

    /// @notice Public test networks on which shorter timelock delays and deployments are acceptable.
    ///         Monad testnet (10143) is deliberately NOT listed: it is treated as value-bearing (deviation (e)).
    function isTestnet(uint256 chainId) internal pure returns (bool) {
        return chainId == 11155111 // Ethereum Sepolia
            || chainId == 17000 // Holesky
            || chainId == 560048 // Ethereum Hoodi
            || chainId == 84532 // Base Sepolia
            || chainId == 421614 // Arbitrum Sepolia
            || chainId == 11155420 // OP Sepolia
            || chainId == 80002 // Polygon Amoy
            || chainId == 97; // BNB Smart Chain testnet
    }

    /// @notice Local or public test chain (timelock floor 1 h; deploy scripts classify as LOCAL / TESTNET).
    function isTestChain(uint256 chainId) internal pure returns (bool) {
        return isLocal(chainId) || isTestnet(chainId);
    }

    /// @notice Chains with no single sequencer, where an L2 sequencer-uptime feed is not required: Ethereum and
    ///         validator-set chains with their own consensus (BNB, Avalanche, Gnosis, Fantom, Polygon PoS) and their
    ///         test networks, plus the local chain (ADR-0009, Edith R4). Polygon PoS checkpointing to Ethereum affects
    ///         finality, not swap liveness, and Chainlink publishes no uptime feed for it. EVERY other id, including
    ///         rollups such as Polygon zkEVM 1101, Mantle 5000, Blast 81457 and any unknown id, requires one.
    ///         Exemption does NOT approve any price feed: feeds must still be verified official same-chain Chainlink
    ///         direct-pair proxies (runbook); nothing on Fantom 250 unless verified at deploy time.
    function isSequencerExempt(uint256 chainId) internal pure returns (bool) {
        return chainId == 1 // Ethereum Mainnet
            || chainId == 11155111 // Ethereum Sepolia
            || chainId == 17000 // Holesky
            || chainId == 560048 // Ethereum Hoodi
            || chainId == 56 // BNB Smart Chain
            || chainId == 97 // BNB Smart Chain testnet
            || chainId == 43114 // Avalanche C-Chain
            || chainId == 100 // Gnosis
            || chainId == 250 // Fantom Opera (being superseded by Sonic; feeds only if verified at deploy time)
            || chainId == 137 // Polygon PoS
            || chainId == 80002 // Polygon Amoy
            || isLocal(chainId);
    }

    /// @notice Fail-closed: true unless the chain is on the explicit L1 / local exemption allowlist.
    function requiresSequencerFeed(uint256 chainId) internal pure returns (bool) {
        return !isSequencerExempt(chainId);
    }
}
