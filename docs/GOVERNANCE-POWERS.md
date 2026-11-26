# SupaDEX Governance Powers — What the Timelock Can Do (I-05)

> **Status:** user-facing disclosure, 2026-11-26 (audit closure, informational
> finding I-05). This document publishes the powers governance holds over
> SupaDEX so users can assess them before depositing. It describes powers that
> exist in the code today; it does not grant or remove any power.

## 1. Who holds these powers

All powers below are held by the **SupaTimelock** (`contract/governance/SupaTimelock.sol`),
the governance timelock contract. The timelock is the `owner` of `SupaVault`,
`SupaPoolManager` and `PluginWhitelist`, and the roles owner of the native
plugins. The deployer holds **no** role after handover (`script/DeploySupaDex.s.sol`,
`_handOff`). Role separation (proposer / executor / canceller / guardian /
operator) is defined in ADR-0010; see `docs/runbooks/GOVERNANCE.md`.

## 2. The powers

### 2.1 Upgrade the vault (full custody power)

- **What:** the timelock can UUPS-upgrade `SupaVault` to a new implementation.
  `SupaVault._authorizeUpgrade` (`contract/core/SupaVault.sol:151`) is
  restricted to `onlyOwner`, and the owner is the timelock.
- **Effect:** the vault holds **all** pooled funds (every pool, every currency,
  every ERC-6909 claim). A malicious or buggy upgrade could move, freeze or
  mis-account those funds. This is the single largest centralisation risk in
  the system.
- **What it cannot do:** it cannot upgrade `SupaPoolManager` or the curve
  engines — those are immutable and non-upgradeable; changing them requires a
  redeploy and liquidity migration.

### 2.2 Delist a plugin (can halt swaps on affected pools)

- **What:** the timelock (as owner of `PluginWhitelist`) can remove a plugin
  from the allowlist via `PluginWhitelist.setPluginWhitelisted(plugin, false)`
  (`contract/governance/PluginWhitelist.sol:48-55`). Delisting also clears
  that plugin's `canReturnDelta` permission.
- **Effect:** `SupaPoolManager.swap` and `donate` revert for every pool using
  the delisted plugin — `_requirePluginAllowed` (`contract/core/SupaPoolManager.sol:164`)
  is checked at the start of `swap` (line 444) and `donate` (line 550).
- **What still works:** liquidity **removal** keeps working — delisted plugins
  are skipped on removals so LP exits always work (audit §3, "Verified as
  mitigated or safe"). Fee collection and ERC-6909 claim withdrawals are not
  blocked by a plugin delisting.

### 2.3 Unset / replace the circuit breaker (remove the emergency brake)

- **What:** the timelock can call `setCircuitBreaker` with any address —
  including `address(0)` — on both `SupaPoolManager`
  (`contract/core/SupaPoolManager.sol:109-112`) and `SupaVault`
  (`contract/core/SupaVault.sol:123-126`). Setting it to `address(0)` disables
  all pause checks (`_checkCircuitBreaker` treats a zero breaker as absent).
- **Effect:** the emergency pause (vault / pool / curve pauses, including the
  BIN-at-genesis pause) stops being enforceable. The guardian's ability to
  pause in an incident depends on the breaker contract remaining configured.
- **Related power:** the timelock can also set the protocol-fee controller and
  per-pool protocol fees (capped at 25% of the swap fee, L-04 fix), and can
  authorise / de-authorise pool managers on the vault
  (`SupaVault.setPoolManager`, `SupaVault.sol:158`).

## 3. Mitigation: the 48-hour delay floor

Every power above is exercised **through the timelock**, not directly:

- `SupaTimelock.PRODUCTION_DELAY_FLOOR` is **48 hours**
  (`contract/governance/SupaTimelock.sol:35`); `delayFloor` is fixed at
  construction from the chain id and neither the constructor nor `updateDelay`
  accepts less. Value-bearing chains (every chain that is not a known
  local/test chain — fail-closed) get the 48 h floor; known local/test chains
  get 1 h (`MINIMUM_DELAY`).
- A queued operation can only execute after its delay has elapsed, and only
  within the 14-day grace period (`GRACE_PERIOD`). Cancellers (emergency
  guardians) can cancel a queued operation before it executes.
- **Practical meaning for users:** any upgrade, delisting or breaker change is
  visible on-chain for at least 48 hours before it can take effect. Users who
  monitor the timelock queue have that window to exit. There is no instant
  governance action on value-bearing chains.

## 4. What users should do

- Before depositing material funds, check the timelock queue for pending
  operations affecting the vault, the pool manager, the plugin whitelist or
  the circuit breaker.
- Treat a queued vault upgrade or a plugin delisting affecting your pools as a
  reason to review (and, if you disagree with the change, exit within the
  48-hour window — exits remain open during pauses and delistings).
- Do not assume the 48-hour window protects you if you do not monitor it:
  the delay is a transparency mechanism, not an approval by users.

## 5. References

- Internal pre-audit 2026-11-26, finding I-05 (cited there as
  `SupaVault.sol:127`, `SupaPoolManager.sol:97-107,397` at base `06c1c0c`;
  line numbers have shifted at `efba73c` — see the current numbers cited
  above).
- `docs/runbooks/GOVERNANCE.md` (roles, delays, cancellation, plugin
  whitelist policy).
- `contract/governance/SupaTimelock.sol` (delay floor, role separation,
  grace period).
