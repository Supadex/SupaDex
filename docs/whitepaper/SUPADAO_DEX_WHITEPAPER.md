# SupaDAO DEX White Paper: Unified Singleton Exchange Architecture

White paper version: 1.0.0 | Publication date: 2026-10-15 | Document status: Under Technical Review

SupaDAO DEX is an independent decentralized exchange project. It must not be confused with SupaCore, the separate institutional settlement and interoperability infrastructure project.

---

## Executive Summary

SupaDAO DEX is a decentralized exchange designed around a single coordinating contract and vault that manages multiple types of liquidity pools. Instead of deploying separate smart contracts for standard pairs, stablecoins, and concentrated positions, SupaDAO DEX organizes them inside one shared system.

### The Problem in Plain English
In traditional decentralized exchanges, different trading models live in separate, disconnected systems. If you want to trade volatile pairs like ETH/USDC, you use one protocol. If you want to swap pegged tokens like USDC/USDT with low slippage, you must find an entirely different exchange. 

This causes two major issues for users:
1. **Capital is fragmented**: Liquidity is divided across different websites, causing higher slippage and worse prices.
2. **Expensive token transfers**: Moving funds across separate multi-hop pools requires multiple on-chain ERC-20 transfers, driving up network gas fees.

### The SupaDAO Solution
SupaDAO DEX combines three proven automated market maker (AMM) curves into one shared settlement layer:
1. **Concentrated Liquidity (CLAMM)**: Allows liquidity providers to focus funds in active price ranges, giving traders deeper liquidity and better prices for volatile pairs.
2. **Discrete Price Bins (BinAMM)**: Groups liquidity into step-by-step price buckets, enabling zero-slippage trades within each price bin.
3. **Stable Pools (StableAMM)**: An amplified invariant curve engineered for tokens pegged to the same value (like stablecoins), preventing price impact on large swaps.

All three models share one central custody vault (`SupaVault`) and one routing manager (`SupaPoolManager`). This allows swaps to route between different pool types seamlessly while saving up to 22% on gas fees through internal token balances (ERC-6909 claims).

---

## 1. Automated Market Makers Explained

Before diving into the architecture, it is helpful to understand how decentralized exchanges operate.

An Automated Market Maker (AMM) is a smart contract on the blockchain that allows anyone to swap tokens without needing a traditional central order book or centralized broker. 

### How Liquidity Pools Work
- Rather than matching buyers with sellers in real time, an AMM holds pools of token pairs (for example, ETH and USDC).
- Anyone can become a **Liquidity Provider (LP)** by depositing tokens into the pool to facilitate trading.
- In exchange for depositing their assets, liquidity providers earn a share of the trading fees paid whenever someone executes a swap.

### How Prices Are Determined
The pool's pricing is governed by a mathematical formula (called an invariant). The most classic formula is constant-product:
$$\text{Tokens}_A \cdot \text{Tokens}_B = k$$

When a trader deposits Token A to receive Token B, the supply of Token A in the pool goes up, and Token B goes down. The contract calculates the exact price so that the total balance product remains balanced.

---

## 2. Why Multiple Liquidity Models Matter

No single mathematical formula works best for all crypto assets:
- **Volatile pairs (like ETH/USDC)** change price rapidly. They benefit from concentrated liquidity where providers specify upper and lower price boundaries to maximize fee earnings.
- **Pegged pairs (like USDC/USDT)** rarely deviate from a 1:1 ratio. Using a standard curve causes unnecessary slippage; an amplified stable curve ensures large swaps execute near exact parity.
- **Emerging or discrete pairs** benefit from clear price bins where trades occur at exact prices until an inventory tier is exhausted.

By supporting all three models within one architecture, traders never need to manually choose or bridge between different exchange protocols.

---

## 3. Architecture & Singleton Design

SupaDAO DEX organizes its contracts into clear, specialized responsibilities:

```
[ Trader / Router / Periphery ]
              |
              | 1. Opens unlock session
              v
[ SupaVault ] <---- 4. Verifies net token deltas equal 0
      ^
      | 2. Updates transient balances
      v
[ SupaPoolManager ] ---- 3. Dispatches lifecycle & fees
      |
      +---> [ CLAMMEngine ]      (Concentrated ranges & ticks)
      |
      +---> [ BinAMMEngine ]     (Discrete active price bins)
      |
      +---> [ StableAMMEngine ]  (Amplified stable invariant)
```

### The Central Vault (`SupaVault`)
The vault holds the physical ERC-20 tokens, tracks internal balances via the ERC-6909 standard, and manages transient flash accounting. By utilizing Ethereum's modern EIP-1153 transient storage, all intermediate token calculations during a multi-hop swap occur in temporary memory. Physical tokens are only transferred once at the very beginning and end of the transaction, dramatically reducing gas costs.

### The Pool Manager (`SupaPoolManager`)
The pool manager is the coordinator. It manages pool creation, verifies caller permissions, dispatches calculations to the correct curve engine, and coordinates fee collection. Each pool is identified by a unique `PoolKey` containing the two tokens, fee tier, spacing, curve type, and any optional plugins.

---

## 4. How Swaps Work: Step by Step

1. **Quote & Slippage Check**: The trader specifies the input token, desired output token, and minimum acceptable output amount.
2. **Vault Unlock Session**: The router initiates an unlock callback with `SupaVault`.
3. **Curve Calculation**: The manager routes the trade to the corresponding engine (CLAMM, Bin, or Stable). The engine calculates the exact output and updates fee accumulators.
4. **Internal Delta Settlement**: If the trade is part of a multi-hop route, intermediate tokens are credited as internal claims without physical blockchain transfers.
5. **Zero-Delta Guarantee**: Before the unlock session finishes, the vault confirms that all debits and credits balance out to zero. The user receives their output tokens, and the transaction completes.

---

## 5. Dynamic Fee Protection & Research

When token prices move rapidly on centralized exchanges (such as Binance), automated trading bots attempt to trade against decentralized pools before the pool price adjusts. This dynamic is known in DeFi research as **Loss-Versus-Rebalancing (LVR)**.

SupaDAO DEX includes a production adaptive-fee plugin (`LVRShieldPlugin`). When rapid volatility is detected in recent pool trades (via an internal tick TWAP oracle), the plugin temporarily increases the swap fee and decays it toward the base fee over a configurable half-life. This raises the cost of toxic order flow during pool turbulence. The signal is based on on-pool ticks rather than an external CEX fair-price feed, so it mitigates adverse selection under pool volatility and is not a guarantee of LVR elimination.

*Important Note*: In current contract implementations, the dynamic fee plugin relies on internal pool tick observations rather than an external oracle, and remains an experimental feature subject to ongoing review.

---

## 6. Security Architecture & Safety Controls

SupaDAO DEX is built with multiple defense-in-depth security layers:
- **Transient Zero-Delta Checks**: The vault guarantees that no transaction can complete if tokens are unaccounted for.
- **Circuit Breakers**: In the event of extreme market volatility or unexpected token behavior, authorized guardians can pause individual pools, curve types, or the entire exchange.
- **Timelock Governance**: Administrative parameter changes require a minimum time delay, giving users full visibility before changes take effect.
- **Tested with Foundry**: The smart contract suite contains comprehensive unit tests, fuzz tests, and invariant test campaigns.

---

## 7. Current Development & Deployment Status

- **Smart Contract Codebase**: Core contracts, three AMM engines, periphery router, and position NFTs are implemented and tested locally.
- **Local Testing**: All suites pass on local Foundry and Anvil networks.
- **External Security Audit**: An independent third-party audit has not yet been completed.
- **Public Deployment**: The protocol has been tested locally and on development environments; public testnet deployment is in preparation.

---

## 8. Summary & Next Steps

SupaDAO DEX demonstrates how multiple automated market maker curves can coexist within a unified singleton exchange architecture. By centralizing custody and settlement while decentralizing mathematical curve execution, the platform delivers lower gas fees, improved price stability, and a simpler trading experience for everyone.

The next development milestones focus on formal external security audits, extended testnet trials, and preparing for public launch.
