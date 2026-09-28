# Solidity & Smart Contract Rules for SupaDex

## 1. Compiler & EVM Configuration
- **Solidity Version**: `pragma solidity ^0.8.26;`
- **EVM Target**: `cancun` (Enabled for EIP-1153 `TSTORE` / `TLOAD`)
- **Via-IR**: `via_ir = true`
- **Optimizer Runs**: `1_000_000`

---

## 2. Directory Architecture & Layering Rules

```
contract/
├── core/                        # Upgradeable Singletons, Math Execution Engines, Vault
├── periphery/                   # Routers, PositionManager, Quoter
├── interfaces/                  # Pure interfaces (prefix: 'I')
├── errors/                      # Zero-gas Custom Errors
├── events/                      # Decoupled Event emission interfaces
├── libraries/                   # Stateless Assembly & Pure Math Libraries
├── types/                       # User Defined Value Types
└── plugins/                     # Native & External Hooks
```

---

## 3. Coding Guidelines

### 3.1 Custom Errors vs Require Strings
- **Forbidden**: `require(x > 0, "Amount must be positive");`
- **Required**: `if (x == 0) revert VaultErrors.ZeroAmount();`

### 3.2 Types & Wrappers
- Use `Currency` for token addresses (where `Currency.wrap(address(0))` represents native ETH).
- Use `BalanceDelta` for token deltas (`amount0` and `amount1` packed into an `int256`).
- Use `PoolId` (keccak256 hash of `PoolKey`) as mapping keys.

### 3.3 Flash Accounting & Transient Storage
- Use `TransientStorageLib` for managing transient deltas and reentrancy locks.
- Never store temporary flash swap deltas in persistent warm storage.

### 3.4 Upgradeability Pattern
- Core singleton contracts use the OpenZeppelin UUPS (Universal Upgradeable Proxy Standard) pattern with storage gaps and explicit initialization controls (`_disableInitializers()`).
