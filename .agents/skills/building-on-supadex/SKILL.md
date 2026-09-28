---
name: building-on-supadex
description: Complete developer guide and integration SDK for external protocols, hook developers, arbitrageurs, and liquidity managers building on SupaDex AMM.
---

# Building on SupaDex AMM: Developer & Integrator Skill

This skill provides comprehensive instructions, code patterns, and technical guidelines for smart contract developers, quantitative traders, hook creators, and protocols building on or integrating with **SupaDex AMM**.

---

## 1. Core Architecture Overview

SupaDex is a singleton, multi-curve, flash-accounting AMM engine executing with ERC-6909 vault claims and pluggable hook architecture.

### Key Components
- **`SupaVault`**: Central custody vault implementing physical ERC-20 token reserves, ERC-6909 internal claims, and flash-accounting lock/unlock execution.
- **`SupaPoolManager`**: Core singleton pool manager coordinating multi-curve execution, dynamic fees, and plugin dispatch.
- **`ICurveEngine`**: Pluggable AMM math engines:
  - `CLAMM` (`curveType = 0`): Concentrated liquidity with Q64.96 tick math.
  - `BinAMM` (`curveType = 1`): Discretized price bins with zero slippage inside active bins.
  - `StableAMM` (`curveType = 2`): Stableswap amplified invariant ($A$-parameter).
- **`SupaRouter`**: Swap router supporting exact-input/exact-output single and multi-hop paths with native ETH and ERC-6909 claim settlement.
- **`SupaPositionManager`**: ERC-721 NFT liquidity wrapper with multicall, permit, and claim fee collection.
- **`SupaQuoter`**: Off-chain static quoter simulating exact returns across all curve engines.

---

## 2. Integration Archetypes

### Archetype A: Swapping via SupaRouter
To execute swaps through contracts, approve tokens to `SupaRouter` and call `exactInputSingle` or `exactInput`:

```solidity
import {ISupaRouter} from "contract/interfaces/ISupaRouter.sol";
import {PoolKey, CurveType} from "contract/types/PoolKey.sol";
import {Currency} from "contract/types/Currency.sol";

contract SwapperExample {
    ISupaRouter public immutable router;

    constructor(ISupaRouter _router) {
        router = _router;
    }

    function executeSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) external returns (uint256 amountOut) {
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            hookData: "",
            settleWithClaims: false, // Set to true to use ERC-6909 claims
            receiveAsClaims: false,  // Set to true to receive ERC-6909 claims
            recipient: msg.sender,
            deadline: block.timestamp + 300
        });

        amountOut = router.exactInputSingle(params);
    }
}
```

---

### Archetype B: Direct Vault Flash Accounting (`unlockCallback`)
For arbitrage, flash swaps, or multi-pool rebalancing, call `vault.unlock()` directly:

```solidity
import {IVault} from "contract/interfaces/IVault.sol";
import {IPoolManager} from "contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "contract/interfaces/IUnlockCallback.sol";
import {PoolKey} from "contract/types/PoolKey.sol";
import {Currency} from "contract/types/Currency.sol";
import {BalanceDelta} from "contract/types/BalanceDelta.sol";

contract FlashArbitrageur is IUnlockCallback {
    IVault public immutable vault;
    IPoolManager public immutable poolManager;

    constructor(IVault _vault, IPoolManager _poolManager) {
        vault = _vault;
        poolManager = _poolManager;
    }

    function executeArbitrage(bytes calldata data) external {
        vault.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(vault), "Unauthorized");

        // 1. Decode trade instruction
        // 2. Execute swap(s) or modifyLiquidity via poolManager
        // 3. Settle negative deltas with vault.settle() or vault.take() positive deltas
        // 4. Ensure all transient deltas equal 0 at completion

        return "";
    }
}
```

---

### Archetype C: Writing Custom Plugins & Hooks
Extend `BaseHook` to inject custom logic before/after pool initializations, liquidity modifications, swaps, or donations:

```solidity
import {BaseHook} from "contract/plugins/external/BaseHook.sol";
import {IPoolManager} from "contract/interfaces/IPoolManager.sol";
import {PoolKey} from "contract/types/PoolKey.sol";
import {BalanceDelta} from "contract/types/BalanceDelta.sol";

contract CustomVolumeIncentiveHook is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeModifyLiquidity: false,
            afterModifyLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnsDelta: false,
            afterSwapReturnsDelta: false,
            afterModifyLiquidityReturnsDelta: false
        });
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Custom fee distribution or volume tracking logic
        return (BaseHook.afterSwap.selector, 0);
    }
}
```

---

### Archetype D: Liquidity Provision via SupaPositionManager
Manage concentrated or multi-curve positions via ERC-721 tokens:

```solidity
import {ISupaPositionManager} from "contract/interfaces/ISupaPositionManager.sol";
import {PoolKey} from "contract/types/PoolKey.sol";

contract LiquidityProviderExample {
    ISupaPositionManager public immutable positionManager;

    constructor(ISupaPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    function mintPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityAmount,
        uint256 amount0Max,
        uint256 amount1Max
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        ISupaPositionManager.MintParams memory params = ISupaPositionManager.MintParams({
            poolKey: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidityAmount,
            amount0Max: amount0Max,
            amount1Max: amount1Max,
            recipient: msg.sender,
            deadline: block.timestamp + 300,
            hookData: ""
        });

        (tokenId, liquidity, amount0, amount1) = positionManager.mint(params);
    }
}
```

---

## 3. Best Practices & Safety Guidelines
1. **Flash Accounting Delta Zeroing**: Whenever calling `vault.unlock()`, every touched currency must have exactly zero net transient delta by the time the callback returns (`vault.settle()` for debits, `vault.take()` for credits).
2. **Curve Engine Compatibility**:
   - `CLAMM`: Ensure `tickLower < tickUpper` and ticks are exact multiples of `tickSpacing`.
   - `BinAMM`: Use discrete bin indices with proper `binStep`.
   - `StableAMM`: Use for correlated or pegged assets (e.g., stablecoins, LSTs) with appropriate $A$ amplification factor.
3. **ERC-6909 Gas Optimization**: When performing multiple sequential trades or rebalances across transactions, keep intermediate balances as internal ERC-6909 claims (`settleWithClaims: true`, `receiveAsClaims: true`) to bypass external ERC-20 transfers and save significant gas.
