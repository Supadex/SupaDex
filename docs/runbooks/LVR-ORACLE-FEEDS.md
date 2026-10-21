# Runbook: configuring an LVR oracle feed (ADR-0009)

Status: draft for review (Edith / Jexi). PRODUCTION READINESS NOT ESTABLISHED.

## What is acceptable
- **Only official Chainlink proxies, on the same chain, for the direct pair.** The feed must price base/quote itself. No composite or derived feeds (for example ETH/USD × USD/USDC), no feeds bridged from another chain, no third-party "Chainlink-compatible" feeds, and never the test-only `MockChainlinkAggregator` (it refuses to deploy outside anvil 31337).
- One plugin per pool. An LVR pool cannot also use AntiJIT. If both are needed, the answer is a purpose-built combined plugin, reviewed as one unit (ADR-0009 9-D).

## Registry (config/oracle-feeds.json)
For each feed, one reviewer copies these fields from the Chainlink feed page (data.chain.link / docs.chain.link): proxy address, exact `description()`, decimals, heartbeat, deviation threshold, the pool tokens (base/quote), and on L2s the official sequencer-uptime feed. A second reviewer re-checks every field and records the source URL. **No production entries exist yet.**

## Procedure (every `setOracleConfig` / `setSequencerUptimeFeed`)
1. **Fail closed (ADR-0009, remediation-4):** on every chain except the explicit exemption allowlist in `ChainIds.isSequencerExempt` (Ethereum 1, Sepolia 11155111, Holesky 17000, Hoodi 560048, BNB 56/97, Avalanche 43114, Gnosis 100, Fantom 250, Polygon PoS 137 / Amoy 80002, anvil 31337), the sequencer-uptime feed must be set first. This includes every rollup (Base, OP, Arbitrum, Linea, Scroll, zkSync, Polygon zkEVM 1101, Mantle 5000, Blast 81457), Monad and any unknown chain id. If no official Chainlink uptime feed exists on that chain, LVR external feeds cannot be configured there (pools keep endogenous pricing). `requiresSequencerFeed(chainId)` on the plugin exposes the rule. Grace must be ≥ 3,600 s, and 3,600 s is recommended. The plugin enforces this: `setOracleConfig` reverts `InvalidOracleConfig(9)` without one.
   - **Why the validator-set chains are exempt (Edith, ADR-0009):** BNB, Avalanche, Gnosis, Fantom and Polygon PoS have no single sequencer. Polygon PoS checkpointing to Ethereum affects finality, not swap liveness, and Chainlink publishes no uptime feed for it.
   - **Exemption does not approve any feed.** Every price feed on an exempt chain must still be a verified official same-chain Chainlink direct-pair proxy (rules above, two reviewers). **Fantom 250:** nothing is configured unless the feed is verified at deploy time (Fantom is being superseded by Sonic; feed availability may change).
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

## Sequencer-uptime feed availability (SDX-056, checked 2026-10-21 ~20:05 WAT)
Sources: Chainlink "L2 Sequencer Uptime Feeds" page <https://docs.chain.link/data-feeds/l2-sequencer-feeds> (page source: <https://github.com/smartcontractkit/documentation/blob/main/src/content/data-feeds/l2-sequencer-feeds.mdx>), the Data Feeds address pages <https://docs.chain.link/data-feeds/price-feeds/addresses?network=…>, and the reference-data-directory JSON the address pages are built from (URLs from the docs' `src/features/data/chains.ts`). The page says: *"Chainlink is no longer expanding L2 Sequencer Uptime Feeds to additional networks."* Supported networks listed: Arbitrum, Base, Celo, Mantle, MegaETH, Metis, OP, Scroll, Soneium, X Layer, zkSync (mainnets only).

| Chain | Official uptime feed | Evidence |
|---|---|---|
| Mantle 5000 | **Exists.** Proxy `0xaDE1b9AbB98c6A542E4B49db2588a3Ec4bF7Cdf0` (aggregator `0x154650BD0B40E449214f9c544cE693889ae65f27`) | Listed on the L2 sequencer page ("Mantle Mainnet"); RDD entry "L2 Sequencer Uptime Status Feed" in <https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-mantle-1.json> (address page `?network=mantle`). Read-only check via `https://rpc.mantle.xyz` (chain id 5000): `description()` = "L2 Sequencer Uptime Status Feed", `aggregator()` = 0x1546…5f27, `latestRoundData` answer 0 (up), startedAt 1772608187 (2026-03-04 08:09 WAT), updatedAt 1792571584 (2026-10-21 09:33 WAT). Still needs the 2-reviewer registry process before use. |
| Polygon zkEVM 1101 | **None.** | Not on the L2 sequencer page. The Polygon zkEVM feeds directory <https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-polygon-zkevm-1.json> (address page `?network=polygon-zkevm`) has 11 feeds (LINK/USD, BTC/USD, POL/USD, USDT/USD, wstETH-stETH, LINK/ETH, DAI/USD, rETH/ETH, ETH/USD, USDC/USD, AAVE/USD) and no uptime feed. ⇒ LVR external feeds cannot be configured on 1101 (endogenous only). |
| Blast 81457 | **None.** | Not on the L2 sequencer page, and Blast is not a Chainlink Data Feeds network in the docs at all (absent from `chains.ts`; no address page). ⇒ LVR external feeds cannot be configured on 81457. |
| (also) Linea 59144 | **None.** | Not on the L2 sequencer page; no uptime entry in <https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-linea-1.json>. ⇒ no LVR external feeds on Linea. |
| (also) testnets (Base/OP/Arbitrum Sepolia) | Not listed on the page (mainnets only) | Testnet LVR feeds would need an uptime feed that the docs do not list; use local anvil mocks for testing. |

No production registry entries were added. Re-check this table before any value-bearing deploy (the page can change).

