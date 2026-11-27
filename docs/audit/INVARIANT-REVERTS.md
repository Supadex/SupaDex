# Invariant Revert Classification (T-6)

> SupaDEX internal pre-audit §5 T-6: `fail_on_revert = false` in `foundry.toml`
> (`[invariant]` and `[profile.ci.invariant]`) means Foundry silently discards any
> invariant-handler call that reverts. Only
> `CrossProtocolInvariant.invariant_noUnexpectedReverts` partly mitigated this.
>
> Resolution (PR #7 audit closure, branch `audit/t6-strict-revert`):
> 1. **No global flip.** Per the founder, `fail_on_revert` stays `false` globally:
>    handlers intentionally encounter expected economic reverts (slippage protection,
>    liquidity constraints, configured bounds). A global flip would turn legitimate
>    economics into false positives.
> 2. **Shared classifier.** `test/invariant/RevertClassifier.sol` is the single choke
>    point. Every handler routes caught revert data through it with an explicit
>    context bitmask; anything not enumerated is UNEXPECTED by construction. There
>    is no catch-all "expected" bucket.
> 3. **Dedicated strict suite.** `test/invariant/StrictRevertInvariant.t.sol` runs
>    under the new `[profile.strict]` (`invariant.fail_on_revert = true` — the ONLY
>    profile with it set), so an uncaught handler revert fails the run at the
>    Foundry level, and a classified-unexpected revert fails
>    `invariant_noUnexpectedReverts` under every profile.
> 4. **All existing handlers retrofitted** (except CrossProtocol, see below) to
>    classify instead of discarding: the two bare `catch {}` sites
>    (VaultSolvency `mintClaims`, LVR oracle write) now classify, and the five
>    no-try/catch handlers now wrap their entry points.
> 5. **Regression tests** in `test/invariant/StrictRevertRegression.t.sol` prove
>    unexpected reverts are detected and expected reverts do not false-positive.

## Contexts

| Context | Bit | Granted to |
|---|---|---|
| `CTX_ECONOMIC` | 1 | Every op handler (market/liquidity/slippage guards) |
| `CTX_INPUT` | 2 | Every op handler (caller-parameter validation) |
| `CTX_EXTREME` | 4 | ONLY the full-uint256-domain `mintClaims` op (C-01 guards) |
| `CTX_ACCESS` | 8 | ONLY the unauthorized-caller probe (revert = secure outcome) |

A selector is expected ONLY in the contexts that name it. E.g. `DeltaOverflow` is
expected under `CTX_EXTREME` and UNEXPECTED everywhere else.

## Per-revert classification

### EXPECTED — economic (CTX_ECONOMIC)

Legitimate market/pool behaviour: the operation was refused for a priced, bounded
reason and the caller can retry with a different size/price. None of these indicates
a protocol failure.

| Error | Condition | Handler(s) | Why legitimate |
|---|---|---|---|
| `PoolErrors.InsufficientLiquidity` | Swap/output exceeds available liquidity (incl. exact-output shortfall at the engine) | CrossProtocol, MultiCurve, Delta, CLAMM, Strict (swap/dustSwap) | Market condition: no counterparty liquidity at that size/price. |
| `PoolErrors.ZeroSwapAmount` | `amountSpecified == 0`, or the fee consumes the whole input (Stable) | CrossProtocol, Strict (swap), Regression (direct) | Zero-size input; nothing to price. |
| `PoolErrors.StableImbalanceExceeded` | Swap would leave normalised reserves outside the configured imbalance range | CrossProtocol, MultiCurve, Strict (Stable swap) | Configured StableSwap guard (ADR-0008) doing its job. |
| `PoolErrors.InsufficientInitialLiquidity` | First Stable deposit ≤ `MINIMUM_LIQUIDITY` (1000) | CrossProtocol, Strict (addLiquidity) | Documented minimum-deposit rule (ADR-0001). |
| `PoolErrors.StableInvariantViolated` | Post-swap StableSwap invariant `D` would decrease | Strict (Stable swap) | Solver-domain guard; the swap cannot be priced safely at that size. Counted (not hidden) so a spike in frequency is visible in `expectedBySelector`. |
| `PoolErrors.StableMathNotConverged` | StableSwap Newton iteration did not converge in the bounded iterations | Strict (Stable swap) | Bounded solver; extreme inputs legitimately fail to converge. |
| `PoolErrors.PriceLimitAlreadyExceeded` | Caller price limit already reached | Strict (swap/router) | Caller-configured bound. |
| `PoolErrors.LiquidityOverflow` | Remove exceeds the position/pool liquidity held | Strict (remove), Regression (direct) | Caller asked to remove more than exists. |
| `PoolErrors.TickLiquidityOverflow` | Add would exceed max liquidity per tick | Strict (addLiquidity) | Configured per-tick cap (Issue 4 remediation). |
| `PoolErrors.NoLiquidityToDonate` | `donate` with zero active liquidity | Strict (donate) | Nothing to credit the donation to. |
| `PoolErrors.SlippageExceeded` | Pool-level slippage guard | Strict (swap paths) | Slippage protection working as designed. |
| `PeripheryErrors.SlippageExceeded` | Router / PositionManager output below minimum (or input above maximum) | Strict (router/position), Regression (router) | User-configured slippage protection. |
| `PeripheryErrors.InsufficientOutputAmount` | Exact-output swap (or one hop) delivers less than requested; partial fills not allowed | Strict (routerExactOutput) | Uniswap-v3-parity shortfall rule (APUS-SUPADEX-039). |
| `PeripheryErrors.DeadlinePassed` | Caller deadline elapsed | Strict (router/position), Regression (position mint) | Caller-configured deadline. |
| `PeripheryErrors.InsufficientETH` | Caller sent too little native ETH | Strict (claims deposit, native leg) | Caller funding error. |
| `PeripheryErrors.ZeroAmount` / `VaultErrors.ZeroAmount` | Zero-amount periphery/vault call | Strict (claims/router) | Zero-size input validation. |
| `PeripheryErrors.ZeroLiquidity` | Zero-liquidity position call | Strict (positionMint/decrease) | Zero-size input validation. |
| `PeripheryErrors.ETHTransferFailed` / `VaultErrors.ETHTransferFailed` | Recipient contract cannot receive ETH | Strict (router/position, recipient leg) | Recipient property (L-05), not a protocol failure. Strict-suite recipients are EOAs, so this is expected to have zero occurrences there. |

### EXPECTED — input validation (CTX_INPUT)

Caller-supplied parameters were malformed. These are input errors, not protocol
failures. They should never fire in the fixed-parameter strict suite; they are
enumerated so that a fuzzed handler that varies ticks/ranges/paths classifies them
instead of discarding them.

| Error | Condition |
|---|---|
| `PoolErrors.TicksMisordered` | `tickLower >= tickUpper` |
| `PoolErrors.TickNotSpaced` | Tick not divisible by tick spacing |
| `PoolErrors.TickOutOfBounds` | Tick outside [-887272, 887272] |
| `PoolErrors.InvalidTickSpacing` | Tick spacing ≤ 0 or out of bounds |
| `PoolErrors.InvalidBinStep` | Bin step outside [MIN_BIN_STEP, MAX_BIN_STEP] |
| `PoolErrors.BinIdOutOfBounds` | Bin id price outside TickMath range |
| `PoolErrors.BinRangeTooWide` | Position spans more than MAX_BINS_PER_POSITION bins |
| `PoolErrors.StableInvalidAmplification` | Amplification `A` outside [MIN_A, MAX_A] |
| `PoolErrors.StableDecimalsUnsupported` / `StableDecimalsMismatch` | Token decimals > 18 / unreadable / mismatched |
| `PoolErrors.InvalidInitParams` | Malformed curve init params (CLAMM/BIN must be empty; STABLE must be `abi.encode(A)`) |
| `PoolErrors.CurrenciesOutOfOrderOrEqual` | `currency0 >= currency1` |
| `PoolErrors.PriceLimitOutOfBounds` | Swap price limit outside valid bounds |
| `PeripheryErrors.InvalidPath` | Malformed / empty multi-hop path |
| `PeripheryErrors.IdenticalCurrencies` | Identical currencies in a path |
| `PeripheryErrors.InvalidPoolKey` | Invalid pool key parameters |
| `PeripheryErrors.PositionNotFound` | Position token id has zero liquidity / unknown to caller |
| `TokenDoesNotExist` (Solady ERC721) | Non-existent NFT id |

### EXPECTED — extreme magnitude (CTX_EXTREME only)

The C-01 checked-arithmetic guards firing exactly as designed. Granted ONLY to the
`mintClaims` op, which fuzzes the full `uint256` amount domain. Anywhere else these
are UNEXPECTED (a cast/delta overflow inside normal ops is a bug).

| Error | Condition | Why legitimate (in that one op only) |
|---|---|---|
| `SafeCastLib.SafeCastOverflow` | Per-call amount exceeds `int128.max` (≈1.701e38) on the `toInt128` cast in `SupaVault.settle/mint/take/burn` | The `int128`-bounded delta fix (C-01) rejecting an unrepresentable magnitude. The per-call threshold is `int128.max` — `SupaVault.settle`'s own comment: "Per-call deltas are int128-bounded (Uniswap v4). Larger settles must be split." |
| `VaultErrors.DeltaOverflow` | Checked transient-delta addition would overflow `int256` | The checked-`applyDelta` fix (C-01) refusing a wrapping delta. |

Harness bound (not a protocol bound): successful `mintClaims` amounts are each up
to `int256.max`, so repeated large mints would overflow `uint256` cumulative
accounting (mock-token balances, ERC-6909 balances, claim supply) and surface as an
arithmetic Panic. The handlers therefore stop minting once the remaining headroom
drops below `int256.max` (`cumulativeMinted` / `totalMintedClaims` guard). The
extreme-magnitude behaviour is still exercised by the mints that did run; a total
above 2^256 minted is economically impossible.

Per-call cap (not a protocol bound): cumulative claims holdings can exceed
`int128.max` via several individually in-range mints, so a single `burn` or
`claimsWithdraw` of the whole balance would trip the designed per-call
`SafeCastOverflow`. `burnClaims` (both suites) and `claimsWithdraw` therefore cap
the single call at `int128.max`; `mintClaims` alone keeps the full domain so the
guard is still exercised there.

### EXPECTED — access control (CTX_ACCESS only)

Granted ONLY to the unauthorized-caller probe, where a revert IS the expected
(secure) outcome. Anywhere else these are UNEXPECTED (a legitimate caller being
denied is a bug).

> **Overload warning — `PeripheryErrors.Unauthorized` from `SupaPositionManager.burn`:**
> `burn` reverts `Unauthorized()` not only for non-owners but also when
> `pos.liquidity != 0 || pos.tokensOwed0 != 0 || pos.tokensOwed1 != 0`
> (`SupaPositionManager.sol:239-244`). The strict suite's `positionBurn` therefore
> collects fees first; a burn that still reverts `Unauthorized` after collecting is
> UNEXPECTED (a harness sequencing bug), never silently classified as "expected
> access control". The first strict-suite fuzz run caught exactly this: a
> fully-decreased position with uncollected swap fees reverted `Unauthorized` on
> burn (seed `0x1ef9af39…`, shrunk sequence `positionBurn` after `positionDecrease`
> 100% without a `collect`). Fixed by collect-before-burn in the handler.

| Error | Condition |
|---|---|
| `VaultErrors.Unauthorized` | Non-owner / non-pool-manager / non-pending-owner caller |
| `PeripheryErrors.Unauthorized` | Non-owner / non-approved caller, or zero-address recipient |
| `PoolErrors.InvalidProtocolFeeController` | `setProtocolFee` from a non-controller |
| `PoolErrors.NotGovernance` | Governance-only call (e.g. Stable `rampA`) from a non-governance caller |

### UNEXPECTED — protocol failures (must never be silently ignored)

Anything not listed above, including every item below. If one of these fires in a
handler, `invariant_noUnexpectedReverts` fails the suite — that is the point.

| Error / shape | Why it must fail the run |
|---|---|
| `Panic(uint256)` (`0x4e487b71`) — incl. `0x11` arithmetic underflow, `0x12` division by zero | Checked-arithmetic failure. The C-02 mirror-direction underflow DoS was exactly a `0x11` panic; it must never be swallowed. **Known instance (T-6 finding, 26 Nov 2026):** CLAMM over-removal Panics `0x11` in `_updateTick` (`CLAMMEngine.sol:133-135`) before the `_updatePosition` `LiquidityOverflow` guard (`:274`) runs — see the phase report and `test_unexpectedRevertDetected_overRemovalPanics`. BIN/STABLE guard first and return the named error. |
| `Error(string)` (`0x08c379a0`) | `require` strings (incl. mock-token "Insufficient"): harness or token failure. |
| Empty revert data / unknown selector | Unclassified failure mode; bucketing it as expected would hide new bugs. |
| `PoolErrors.PoolInsolvent` | M-01 guard: a pool would pay out more than its recorded reserves. The guard firing means accounting is already wrong. |
| `VaultErrors.CurrencyNotSettled` | Unlock callback left a delta unsettled — settlement invariant broken. |
| `VaultErrors.ClaimsExceedReserves` | ERC-6909 claim supply exceeds reserves — C-01-class solvency break. |
| `VaultErrors.InsufficientBalance` | `take`/`burn` exceeds balance/reserves — payout exceeds what the vault holds. |
| `VaultErrors.CurrencyNotSynced` / `VaultErrors.NonZeroNativeValue` | Settlement sequencing violated (settle without sync / ETH on a non-native settle). |
| `VaultErrors.VaultNotUnlocked` / `VaultErrors.VaultAlreadyLocked` | Lock-state machine violated. |
| `PoolErrors.PoolNotInitialized` / `PoolAlreadyInitialized` | Operation on a pool in the wrong lifecycle state; suites initialize all pools in `setUp`. |
| `PoolErrors.CurveDisabled` | Pool creation for a disabled curve. |
| `PoolErrors.PluginNotWhitelisted` / `PluginWhitelistRequired` | Plugin not on the whitelist / whitelist unset — setup or governance failure. |
| `PoolErrors.NotPoolManager` / `PoolManagerAlreadySet` | Engine called by a non-manager / double binding. |
| `PoolErrors.NotGovernance` (outside the access probe) | Governance call from the wrong caller in normal operation. |
| `PoolErrors.InvalidProtocolFee` / `InvalidFee` / `InvalidProtocolFeeController` (outside probe) | Fee configuration outside protocol bounds / wrong controller. |
| `PoolErrors.HookDeltaNotAllowed` / `HookDeltaCapExceeded` | A plugin returned an illegal or oversized hook delta — plugin misbehaviour (I-01: afterSwap deltas are always rejected by design). |
| `PoolErrors.StableInvalidRamp` / `StableNoActiveRamp` / `StableInvalidARange` | Amplification-ramp state machine violated. |
| `PluginErrors.*` (`PluginCallFailed`, `PluginGasExceeded`, `PluginPermissionDenied`, `PluginReentrancyLock`, `OracleNotInitialized`, `InvalidCardinality`, `ObservationWindowTooOld`, `NotOracleWriter`, `InvalidFeeParameter`, `InvalidFeeBounds`, `InvalidDecayHalfLife`, `InvalidOracleConfig`, `InvalidHookPermissions`) | Plugin/oracle failure. Note `PluginErrors.JITResidencyViolation` is defined but never thrown anywhere in `contract/` — it cannot occur; if it ever does, it is unexpected. |
| `CircuitBreakerErrors.PoolPaused` / `CurvePaused` / `VaultPaused` | No suite pauses anything; a pause revert means unexpected state changed under the run. (If a future suite deliberately pauses, it must grant an explicit pause context — do not add these to the economic set.) |
| `GovernanceErrors.*`, `FeeCollectorErrors.*`, `RolesErrors.*`, `PluginWhitelistErrors.*` | Governance/fee/role failures; not reachable from invariant op handlers. |

## What was NOT classified (residual)

- **CrossProtocolInvariant's own `_classify` was left untouched.** It classifies
  only 4 selectors (`InsufficientLiquidity`, `ZeroSwapAmount`,
  `StableImbalanceExceeded`, `InsufficientInitialLiquidity`) — a strict subset of
  the Economic set above. Widening it to the full classifier set would have
  reclassified currently-unexpected reverts (e.g. `LiquidityOverflow`,
  `StableInvariantViolated`) as expected and weakened the strictest existing
  check. Unifying it onto `RevertClassifier` is follow-up work for the coordinator,
  not silently done here.
- **Quote/router `assertEq` in QuoterRouterEquivalence** was replaced by a counted
  `quoteMismatches` + `invariant_noQuoteMismatches`: an assert failure inside a
  handler reverts the handler call, which `fail_on_revert = false` discards, so a
  quoter/router mismatch could previously never fail the suite.
- **AntiJIT `invariant_feesHookNeverExceedsAccrued`** remains vacuous
  (`assertGe(type(uint256).max, ...)`); the real check is the handler-side
  `assertLe(haircut, fees)`, which still reverts (and is discarded by) the handler
  call under `fail_on_revert = false`. Counting it as a mismatch is follow-up work.

## Running the strict suite

```sh
# Strict profile: fail_on_revert = true (only here — never globally).
FOUNDRY_PROFILE=strict forge test --match-contract StrictRevertInvariantTest -vv
FOUNDRY_PROFILE=strict forge test --match-contract StrictRevertRegressionTest -vv

# Existing suites keep the ci profile (fail_on_revert = false) but now fail on
# any classified-unexpected revert via their invariant_noUnexpectedReverts.
FOUNDRY_PROFILE=ci forge test --match-contract "InvariantTest" -vv
```

## CI snippet

See `~/workspace/goals/supadex-production-readiness/hidden_files/audit-closure/phase-3-strict-revert.md`
for the exact YAML job to add to `.github/workflows/test.yml` (not edited here, per task).
