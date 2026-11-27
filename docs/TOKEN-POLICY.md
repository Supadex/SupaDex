# SupaDEX Token Policy — Unsupported Token Behaviours (I-03)

> **Status:** policy document, 2026-11-26 (audit closure, informational finding I-03).
> SupaDEX has **no on-chain token allowlist and no on-chain guard** against the
> behaviours below. This policy is the guard: pools must only be created for
> tokens that satisfy it, and the frontends must enforce it (see §4).

## 1. Scope

This policy covers every token that can be pooled in SupaDEX (CLAMM, BIN and
StableSwap curves) and every token that can be settled through `SupaVault`
(`contract/core/SupaVault.sol`). It does **not** cover tokens held only as
ERC-6909 vault claims, which inherit the same restrictions through settlement.

## 2. Unsupported token behaviours

The following token behaviours are **unsupported**. A pool containing such a
token must not be created, and the frontends must not list it.

| # | Behaviour | Examples | Why it breaks SupaDEX |
|---|---|---|---|
| 1 | **Rebasing supply** (balance of an address changes without a transfer) | stETH-style rebasing tokens, Ampleforth-style supply adjustments | Vault accounting (`reservesOf`) is recorded at settlement time and never re-read; a rebase desynchronises recorded reserves from the real balance (see §3). |
| 2 | **Fee-on-transfer (FOT)** (recipient receives less than the sent amount) | Deflationary / tax tokens | Settlement credits only what arrived (fail-closed), so deposits short-pay; swaps and liquidity adds that assume the nominal amount revert or mis-settle. |
| 3 | **Transfer callbacks / hooks** (token calls back into the caller on transfer, e.g. ERC-777 hooks, ERC-1363 callbacks) | ERC-777 tokens, tokens with transfer hooks | Callbacks execute inside vault settlement / router flows and can re-enter or grief settlement; SupaDEX assumes plain ERC-20 transfer semantics. |
| 4 | **Yield-bearing / rate-drifting assets in StableSwap pools** (value per token drifts from 1:1) | wstETH, rETH, sDAI, stETH | StableSwap pools assume a near-1:1 peg after decimal normalisation (`docs/audit/CLAIMS_REGISTER.md`, "StableSwap Decimals & Rates"). A drifting rate breaks the invariant. |
| 5 | **Tokens whose `transfer`/`transferFrom` do not return a standard boolean success, or that can pause transfers for arbitrary holders** | Non-standard ERC-20s, pausable-by-admin tokens | Settlement and `take` assume the transferred amount actually moved; silent failures or holder-level pauses strand funds mid-unlock. |

Plain ERC-20 tokens with fixed (or only mint/burn-governed) supply, no transfer
tax, no rebasing and no transfer callbacks **are** supported. Native ETH (as
`Currency` native) is supported through the `msg.value` settlement path.

## 3. What happens on-chain today (no guard — read this before pooling a token)

### 3.1 Fee-on-transfer: deposits fail closed

`SupaVault.settle` (`SupaVault.sol:232-253`, comment at line 241 — "Credit exactly what arrived since
`sync`") credits `balanceOfSelf() - syncedBalance`, i.e. only the tokens that
actually arrived. A FOT deposit therefore credits less than the nominal amount
the user intended, and the resulting delta settlement reverts unless the user
pays the shortfall. This is fail-closed for the depositor, but swaps / adds
priced on the nominal amount will revert or settle short — **do not rely on
this behaviour; do not pool FOT tokens.**

### 3.2 Rebasing: losses are socialised, gains become protocol surplus

- **Negative rebase** (balances shrink): `reservesOf[currency]` is not reduced,
  so recorded reserves exceed the vault's real balance. The shortfall is borne
  by whoever withdraws last — LPs and claim holders share the loss in
  withdrawal order, not pro-rata. There is no on-chain mechanism to allocate a
  negative rebase fairly.
- **Positive rebase** (balances grow): the extra balance is surplus above
  `reservesOf`. It is **not** LP yield and is **not** distributed to pools.
  Only the vault owner (governance timelock) can move it, via
  `SupaVault.sweepSurplus` (`SupaVault.sol:168-180`), and the surplus policy
  (ADR-0002) assigns donations / positive rebases to the protocol.

### 3.3 Transfer callbacks

Nothing in `SupaVault.settle` / `take` or the periphery (`PeripheryPayments`)
defends against a token that calls back into the caller during transfer.
Callback tokens are unsupported; a malicious or buggy callback can re-enter
settlement flows. The vault's unlock re-entrancy guard
(`TransientStorageLib`) protects the unlock itself, not arbitrary token hooks.

## 4. Frontend token allowlist (follow-up — NOT implemented here)

The SupaDEX frontends (`Supadex/supaswap` and `Supadex/Admin-page`) are
outside this repository and out of scope for this change. The following is a
**follow-up for the frontend teams**, not an implemented list:

1. Maintain an explicit per-chain token allowlist in each frontend; only
   allowlisted tokens may be selected for swaps, pool creation or liquidity
   adds. Do **not** invent entries — each token must be reviewed against §2
   (standard ERC-20, no rebase, no transfer tax, no transfer callback) before
   listing.
2. Pool creation in the Admin page must reject any token not on the allowlist,
   and must surface this policy to the pool creator.
3. The UI must warn before any interaction with a token that is not on the
   allowlist (e.g. a user pasting a custom token address): "This token has not
   been reviewed against the SupaDEX token policy. Rebasing, fee-on-transfer
   and callback tokens are unsupported and can lose funds."
4. Until the allowlist exists, pool creation is a governance-gated operation:
   only pools for reviewed tokens should be created (see
   `docs/runbooks/GOVERNANCE.md`).

## 5. References

- Internal pre-audit 2026-11-26, finding I-03 (`SupaVault.sol:207-241`).
- `ARCHITECTURE.md` status box: "Rebasing/fee-on-transfer tokens remain
  unsupported: a negative rebase leaves the vault holding less than
  `reservesOf`."
- `docs/audit/CLAIMS_REGISTER.md`: StableSwap row (prohibited wording:
  "Supports LSTs / yield-bearing, rebasing or rate-drifting assets").
