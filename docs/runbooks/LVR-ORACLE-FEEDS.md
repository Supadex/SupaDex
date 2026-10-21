# Runbook: configuring an LVR oracle feed (ADR-0009)

Status: draft for review (Edith / Jexi). PRODUCTION READINESS NOT ESTABLISHED.

## What is acceptable
- **Only official Chainlink proxies, on the same chain, for the direct pair.** The feed must price base/quote itself. No composite or derived feeds (for example ETH/USD × USD/USDC), no feeds bridged from another chain, no third-party "Chainlink-compatible" feeds, and never the test-only `MockChainlinkAggregator` (it refuses to deploy outside anvil 31337).
- One plugin per pool. An LVR pool cannot also use AntiJIT. If both are needed, the answer is a purpose-built combined plugin, reviewed as one unit (ADR-0009 9-D).

## Registry (config/oracle-feeds.json)
For each feed, one reviewer copies these fields from the Chainlink feed page (data.chain.link / docs.chain.link): proxy address, exact `description()`, decimals, heartbeat, deviation threshold, the pool tokens (base/quote), and on L2s the official sequencer-uptime feed. A second reviewer re-checks every field and records the source URL. **No production entries exist yet.**

## Procedure (every `setOracleConfig` / `setSequencerUptimeFeed`)
1. **Fail closed (ADR-0009, remediation-4):** on every chain except the explicit exemption allowlist in `ChainIds.isSequencerExempt` (Ethereum 1, Sepolia 11155111, Holesky 17000, Hoodi 560048, BNB 56/97, Avalanche 43114, Gnosis 100, Fantom 250, anvil 31337), the sequencer-uptime feed must be set first. This includes every rollup (Base, OP, Arbitrum, Linea, Scroll, zkSync, Polygon zkEVM 1101, Mantle 5000, Blast 81457), Polygon PoS 137, Monad and any unknown chain id. If no official Chainlink uptime feed exists on that chain, LVR external feeds cannot be configured there (pools keep endogenous pricing). `requiresSequencerFeed(chainId)` on the plugin exposes the rule. Grace must be ≥ 3,600 s, and 3,600 s is recommended. The plugin enforces this: `setOracleConfig` reverts `InvalidOracleConfig(9)` without one.
2. Choose the parameters:
   - heartbeat = published heartbeat. It may be at most +10%. Tighter than published means constant fallback.
   - deadbandBps ≥ the published deviation threshold.
   - maxDeviationBps > deadband. Use 500–1,000 for majors.
   - fallbackFeePips ≥ the pool's static fee.
   - invert so that the feed prices currency0 in currency1.
3. Dry run on a fork of the target chain. Schedule and execute the timelock call there, then run:
   `ORACLE_ENTRY=<name> POOL_CURRENCY0=… POOL_CURRENCY1=… POOL_FEE=… POOL_TICK_SPACING=… LVR_PLUGIN=… forge script script/OracleConfigCheck.s.sol --fork-url <rpc>`
   Every check must pass (0 failures). This includes `previewOracle` status 0 and a deviation within maxDeviation, which proves that invert and decimals produce the expected price.
4. Schedule the call on the timelock (48 h minimum delay on value-bearing chains). Publish the calldata, the registry entry and the dry-run output so the canceller and the community can review them during the delay.
5. After execution, run OracleConfigCheck again against the live chain (read-only).

## Known limits (do not over-claim)
- **Feed lag:** within the heartbeat and below the deviation threshold, the feed can legitimately lag the market. The overlay then charges only on the measured deviation (test `test_feedLag_withinHeartbeat_underCharges`: true price 1.03, feed and pool at 1.00, only the 3,000-pip base fee is charged). The overlay is a surcharge heuristic, not manipulation-resistant pricing.
- When the feed or sequencer is unusable, swaps never revert. They pay max(endogenous fee, fallbackFee) and the fallback reason is emitted.
- Deviation above maxDeviation (reason 6, feed healthy), APUS-SUPADEX-023: a trade in the arbitrage direction pays max(endogenous, fallbackFee, base + surcharge capped at maxDeviation). Pushing past maxDeviation and returning therefore never costs less than a direct arbitrage. Choose alpha, deadband and maxDeviation knowing that base + alpha·(maxDeviation − deadband)·100/10,000 pips (capped at 100,000) is the fee arbitrageurs pay at and beyond maxDeviation.
