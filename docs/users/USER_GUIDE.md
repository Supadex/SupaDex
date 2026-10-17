# User Guide

Version: 1.0.0 | Date: 2026-10-15 | Status: Under Technical Review

## What it is
SupaDAO DEX is a multi-curve exchange implementation. Pools can use concentrated ranges, a discrete active bin, or an amplified stable curve. A shared vault and pool manager coordinate settlement.

## Choosing a pool
- **Concentrated liquidity**: Focuses capital inside selected price ranges for increased fee efficiency, but positions become inactive outside them.
- **Bin pools**: Quotes a discrete active price and is limited by that bin's inventory in the current code.
- **Stable pools**: Intended for assets that track similar value but exposes LPs to depeg and unit/decimal assumptions.

## Trading
A quote is not a guarantee. A transaction includes a deadline and slippage bound and can revert if state changes. Fees may include a dynamic plugin override. Users should verify the network, contract addresses, assets and pool plugin before signing.

## Providing liquidity
LPs bear price, inventory, fee, smart-contract and asset risks. Fee income is not guaranteed. Concentrated positions require range choices; stable pools can accumulate a depegging asset; current bin swaps do not traverse neighboring bins.

## Claims
The vault can represent deposited currency as ERC-6909 claims. A claim is an internal balance backed by vault accounting, not an ERC-20 balance visible at the external token contract. Claims can be used to fund liquidity or swap inputs without physical ERC-20 transfers.

## Status and safety
No independent audit or public-network deployment was confirmed. A reachable frontend does not prove that contracts are live on a production network. Do not rely on illustrative simulator results as expected returns.
