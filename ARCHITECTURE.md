# SupaDex Architecture Specification (V1)

## 1. Executive Summary
**SupaDex** is a next-generation decentralized Automated Market Maker (AMM) engineered to surpass Uniswap V4. By addressing systemic flaws in current singleton and concentrated liquidity designs—notably Loss-Versus-Rebalancing (LVR), JIT liquidity exploitation, hook gas overhead, rigid non-upgradeable singletons, and multi-curve inflexibility—SupaDex establishes a high-performance, LVR-resistant, multi-curve exchange engine.

---

## 2. Uniswap V4 Flaws & SupaDex Innovations

### 2.1 Flaw Breakdown & Solutions

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                 UNISWAP V4 vs. SUPADEX AMM V1                                    │
├────────────────────────────────┬────────────────────────────────┬────────────────────────────────┤
│ Category                       │ Uniswap V4 Limitations         │ SupaDex Architectural Solution  │
├────────────────────────────────┼────────────────────────────────┼────────────────────────────────┤
│ 1. LVR & Toxic Flow            │ Passive LPs lose value to CEX- │ Native Volatility Decay Curve  │
│                                │ DEX arbitrageurs on stale tick │ + fast-decay dynamic spread to │
│                                │ prices before block inclusion. │ capture & internalize MEV.     │
├────────────────────────────────┼────────────────────────────────┼────────────────────────────────┤
│ 2. Hook Execution Overhead     │ Bitmask address checks and     │ Hybrid Hook/Plugin Dispatcher: │
│                                │ dynamic external calls add gas │ Zero-overhead native plugins   │
│                                │ and reentrancy vectors.        │ + isolated external hooks.     │
├────────────────────────────────┼────────────────────────────────┼────────────────────────────────┤
│ 3. Just-In-Time (JIT) Liquidity│ Bots frontrun swaps with tight │ Native Anti-JIT Fee Residency  │
│                                │ liquidity & backrun instantly, │ with epoch-based fee vesting   │
│                                │ stealing fees from passive LPs.│ for new liquidity additions.   │
├────────────────────────────────┼────────────────────────────────┼────────────────────────────────┤
│ 4. Single-Curve Monoculture    │ Tied strictly to concentrated  │ Multi-Curve Kernel Matrix:     │
│                                │ ticks ($xy=k$). Non-tick math  │ CLAMM + BinAMM (0-slippage) +  │
│                                │ requires convoluted hacks.     │ StableSwap under one Vault.    │
├────────────────────────────────┼────────────────────────────────┼────────────────────────────────┤
│ 5. Upgradeability & Governance │ Rigid, immutable singleton.    │ UUPS Modular Upgradeability    │
│                                │ Critical bug requires multi-   │ with timelocked governance &   │
│                                │ billion dollar migration.      │ emergency circuit breakers.    │
├────────────────────────────────┼────────────────────────────────┼────────────────────────────────┤
│ 6. Cross-Rollup EVM Portability│ Hard-coded EIP-1153 opcode     │ Dual-mode Transient Storage:   │
│                                │ crashes on non-Cancun L2s.     │ Assembly TSTORE/TLOAD with     │
│                                │                                │ automatic bitmap storage fallback.│
└────────────────────────────────┴────────────────────────────────┴────────────────────────────────┘
```

---

## 3. High-Level System Architecture

```
                                      ┌───────────────────────────────────────┐
                                      │             USER / ROUTER             │
                                      │   (Universal Router / Permit2 / CoW)  │
                                      └───────────────────┬───────────────────┘
                                                          │
                                                          │ 1. unlock(data)
                                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                          SUPADEX POOL MANAGER (UUPS)                                            │
│                                                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                       TRANSIENT DELTA LEDGER                                            │   │
│   │   • EIP-1153 TSTORE/TLOAD (Cancun) with fallback bitmap ledger                                          │   │
│   │   • Tracks CurrencyDelta per account & currency across multi-hop calls                                  │   │
│   │   • Invariant: All deltas MUST be exactly 0 at completion of unlock                                     │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                          │                                                      │
│                    ┌─────────────────────────────────────┴────────────────────────────────────┐                  │
│                    │                                                                          │                  │
│                    ▼                                                                          ▼                  │
│   ┌──────────────────────────────────┐                                       ┌──────────────────────────────┐   │
│   │      NATIVE INTERNAL PLUGINS     │                                       │   ISOLATED EXTERNAL HOOKS    │   │
│   │   • Zero-call overhead (compiled)│                                       │   • Dynamic LP incentives    │   │
│   │   • Dynamic LVR Spread Engine    │                                       │   • TWAMM / Limit Orders     │   │
│   │   • Anti-JIT Liquidity Vesting   │                                       │   • KYC / Permissioned Pools │   │
│   │   • High-Precision Volatility TWAP│                                      │   • Custom Curve Modifiers   │   │
│   └──────────────────────────────────┘                                       └──────────────────────────────┘   │
│                    │                                                                          │                  │
│                    └─────────────────────────────────────┬────────────────────────────────────┘                  │
│                                                          │                                                      │
│                                                          ▼                                                      │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                       MULTI-CURVE MATH ENGINES                                          │   │
│   │                                                                                                         │   │
│   │   ┌───────────────────────────┐   ┌────────────────────────────┐   ┌────────────────────────────────┐   │   │
│   │   │       CLAMM ENGINE        │   │       BIN-AMM ENGINE       │   │        STABLE-AMM ENGINE       │   │   │
│   │   │  Concentrated Liquidity   │   │  Discretized Liquidity     │   │     StableSwap Invariant       │   │   │
│   │   │   Tick Math (Q64.96)      │   │  Zero-Slippage Bins        │   │    Amplified Invariant (A)     │   │   │
│   │   └───────────────────────────┘   └────────────────────────────┘   └────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                          │                                                      │
│                                                          ▼                                                      │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                            SUPADEX VAULT                                                │   │
│   │   • ERC-6909 Native Claims Ledger (Internal Balance Mint/Burn)                                          │   │
│   │   • ERC-20 & Native ETH Physical Custody (Zero-loss settlement)                                         │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Core Subsystems

### 4.1 Transient Delta Ledger & Flash Accounting
- In SupaDex, all swaps, liquidity modifications, and donations do not trigger immediate ERC-20 transfers.
- Instead, operations modify a transient balance delta: `BalanceDelta = (int128 amount0, int128 amount1)`.
- The caller must resolve all non-zero deltas before the end of the `unlock` callback via:
  1. `settle(Currency currency)`: Payer transfers tokens to the Vault.
  2. `take(Currency currency, address recipient, uint256 amount)`: Vault sends tokens to recipient.
  3. `mint(Currency currency, address recipient, uint256 amount)`: Vault mints ERC-6909 claim tokens.
  4. `burn(Currency currency, uint256 amount)`: Vault burns ERC-6909 claim tokens to offset delta.

### 4.2 LVR-Mitigation & Volatility-Adaptive Pricing
- Loss-Versus-Rebalancing occurs when external reference prices change faster than on-chain pool prices, enabling latency arbitrageurs to extract value from passive LPs.
- SupaDex includes an integrated Dynamic Volatility Spread:
  $$\text{Fee}(t) = \text{BaseFee} + \gamma \cdot \sigma_{\text{inst}}(t) \cdot e^{-\lambda (t - t_{\text{last}})}$$
  where $\sigma_{\text{inst}}$ is instantaneous tick volatility and $\lambda$ is the fee decay half-life. Arbitrage bursts automatically spike fees, converting toxic MEV into LP revenue.

### 4.3 Anti-JIT Liquidity Vesting Shield
- JIT attackers provide liquidity for single-block trades and extract fees with zero inventory risk.
- SupaDex tracks liquidity addition block heights:
  - Liquidity removed within the minimum residency epoch ($\Delta_{\text{blocks}} < K$) is subjected to a fee haircut that redistributes accrued fees to long-term passive LPs.

### 4.4 Multi-Curve Kernel Matrix
1. **CLAMM (Concentrated Liquidity AMM)**:
   - Optimized Q64.96 square root price math with bitmap-searched initialized ticks.
2. **BinAMM (Discretized Bins)**:
   - Liquidity is deposited into discrete price bins with zero slippage inside each bin, enabling active liquidity management with minimal math overhead.
3. **StableAMM (Amplified Invariant Curve)**:
   - High capital efficiency for correlated pairs (e.g., LSTs, stablecoins).

---

## 5. Directory & Code Splitting Standards

```
contract/
├── core/                        # Singleton Vault, PoolManager, Upgradeable Proxy
├── periphery/                   # Routers, PositionManager, Multicall, Quoters
├── interfaces/                  # Pure interface definitions (IPoolManager, IVault, etc.)
├── errors/                      # Zero-string custom error declarations
├── events/                      # Decoupled event logging contracts
├── libraries/                   # Pure assembly math, transient storage, bitmaps
├── types/                       # User-defined value types (Currency, PoolKey, PoolId, BalanceDelta)
└── plugins/                     # Native plugins and external hook interfaces
```

---

## 6. Security Invariants & Formal Verification Targets

1. **Delta Conservation Invariant**: At the end of every `unlock()` execution, all currency deltas in transient storage MUST equal zero.
2. **Vault Solvency Invariant**: For every token, $\text{Vault Balance} + \sum \text{Reserves} \ge \sum \text{ERC6909 Claims}$.
3. **Reentrancy Invariant**: `unlock()` cannot be recursively entered unless explicitly authorized by sub-context reentrancy guards.
4. **No-Free-Mint Invariant**: ERC-6909 claims can only be minted if backed 1:1 by positive transient deltas.
