# SupaDAO DEX User Guide: Trading, Liquidity & Claims

Version: 1.0.0 | Date: 2026-10-15 | Document Status: Under Technical Review

Welcome to SupaDAO DEX. This guide explains how to swap tokens, provide liquidity, earn trading fees, and understand risks in simple, straightforward language.

---

## 1. What is SupaDAO DEX?

SupaDAO DEX is a decentralized exchange that lets you swap cryptocurrencies directly from your wallet without depositing funds into a centralized company. 

What makes SupaDAO DEX different is that it combines three different types of liquidity pools into one shared exchange vault:
1. **Concentrated Liquidity Pools**: Best for active pairs like ETH and USDC.
2. **Discrete Price Bin Pools**: Organizes funds into price steps for exact limit-style pricing.
3. **Stable Pools**: Specially tuned for tokens that share the same dollar peg (like USDC and USDT).

Because all pools live in one vault, you always get the best available price and pay lower blockchain network fees.

---

## 2. How to Swap Tokens

Trading on SupaDAO DEX is designed to be frictionless:

1. **Connect Your Wallet**: Use MetaMask, WalletConnect, or your preferred Web3 wallet.
2. **Choose Your Tokens**: Select the token you want to spend (Token In) and the token you want to receive (Token Out).
3. **Enter the Amount**: Type in how much you wish to trade. The exchange automatically quotes the best return across all available pool types.
4. **Review Slippage Tolerance**: Slippage is the maximum price change you are willing to accept while your transaction is confirmed on the blockchain (for example, 0.5%). If the price moves beyond this, your trade safely cancels and returns your funds.
5. **Approve & Swap**: Confirm the transaction in your wallet. Your new tokens will arrive in your wallet within seconds.

---

## 3. How to Provide Liquidity and Earn Fees

When you deposit tokens into a pool, you become a **Liquidity Provider (LP)**. Every time another user trades against that pool, they pay a small fee (e.g., 0.30%), which is distributed directly to liquidity providers.

### Choosing the Right Pool Type:
- **Choose Concentrated Pools** if you are trading volatile tokens and want to focus your money in a specific price range to maximize fee earnings.
- **Choose Stable Pools** if you hold stablecoins (like USDC and USDT) and want to earn passive yield with minimal price fluctuation.
- **Choose Bin Pools** if you want to supply liquidity at specific discrete price steps with zero intra-bin slippage.

### Position Management
Your liquidity positions are tokenized as unique NFTs in your wallet. You can check your accrued fees, add more tokens, or withdraw your liquidity at any time.

---

## 4. Understanding Internal Vault Claims (ERC-6909)

When trading multiple tokens in a row, transferring physical tokens across the blockchain repeatedly costs substantial gas fees. 

SupaDAO DEX features an internal claims system (ERC-6909):
- Instead of transferring tokens out to your wallet and back in for the next trade, funds can be credited as internal balance claims inside the vault.
- Using claims saves up to 22% on network fees during multi-step trades.
- You can withdraw your internal claims into regular ERC-20 tokens in your wallet whenever you choose.

---

## 5. Important Risks to Keep in Mind

Decentralized trading involves real risks that every user should understand:
- **Price Volatility**: Token values fluctuate constantly based on global market conditions.
- **Impermanent Loss**: If the price ratio of two tokens changes significantly after you deposit them as an LP, your position value may be lower than if you had simply held the individual tokens in your wallet.
- **Smart Contract Risk**: While the protocol is thoroughly tested locally, smart contract technology is experimental and no external independent security audit has been completed yet.
- **Stablecoin Depegging**: If a pegged token loses its $1.00 value, stable pools can experience one-sided inventory loss.

Always trade responsibly and never deposit funds you cannot afford to lose.
