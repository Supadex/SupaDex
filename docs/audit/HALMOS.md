# Halmos formal verification — SupaDEX

Formal properties in `test/formal/` are verified with [Halmos](https://github.com/a16z/halmos)
and run in CI as the `halmos` job in `.github/workflows/test.yml`. This document
records what is proven, how it is run, the harness fixes that were required to
make the proofs meaningful, and what Halmos cannot express.

## Toolchain (pinned)

| Tool | Version | Where pinned |
| --- | --- | --- |
| Foundry (`forge`) | **1.10.0** | `foundry-toolchain@v1` `version: 1.10.0` in all three CI jobs |
| Halmos | **0.3.3** | `python3 -m pip install --user --break-system-packages "halmos==0.3.3"` in the `halmos` job |
| Solver | z3 (bundled `z3-solver 4.12.6.0`) | `--solver z3` on the Halmos command line |
| solc | 0.8.26, Cancun, via_ir, optimizer_runs 1,000,000 | `foundry.toml` `[profile.default]` (inherited by `[profile.halmos]`) |

Halmos is **not** run through `forge test`: `forge test` never executes
`check_`-prefixed functions, so the formal properties would silently never run.
The CI job invokes the `halmos` binary directly and fails the job on any
non-zero exit.

## How it runs

```sh
FOUNDRY_PROFILE=halmos forge build --ast --extra-output storageLayout metadata
timeout 25m halmos --function check_ --solver z3 --loop 2 --solver-timeout-assertion 120000
```

- `--function check_` selects exactly the six formal properties below.
- `--loop 2` caps loop exploration at 2 iterations per path (Halmos default).
- `--solver-timeout-assertion 120000` gives each solver query 120 s; a query
  that exceeds it fails that function instead of hanging.
- `timeout 25m` caps the whole run; the job itself has `timeout-minutes: 45`.
- There is no `continue-on-error` and no conditional skip anywhere in the job:
  if the Foundry or Halmos install fails, or any property fails, errors, or
  times out, the job fails.

## Why there is a `[profile.halmos]` in foundry.toml

Foundry 1.10 dynamically links `new` deployments inside test contracts through
`vm.deployCode` by default ("dynamic test linking"). Halmos 0.3.3 does not
implement the `deployCode` cheatcode, so any formal test that deploys a contract
failed in `setUp()` with `Unsupported cheat code: deployCode(string,bytes)`.

`[profile.halmos]` overrides exactly one setting — `dynamic_test_linking = false`
— and inherits the rest of the compiler pipeline from `[profile.default]`. With
it, every `new` compiles to a plain `CREATE`, which Halmos executes. The
setting cannot be passed to Halmos's internal `forge build` via a CLI flag
(Halmos has no build-args passthrough), and neither `FOUNDRY_NO_DYNAMIC_TEST_LINKING`
nor `NO_DYNAMIC_TEST_LINKING` is honoured by forge 1.10.0 (both verified to have
no effect on 26 Nov 2026), so a dedicated profile is the only declarative route.
Default / `ci` / `dev` / `legacy` compilation is unchanged; the `[invariant]`
and `[profile.ci.invariant]` sections are untouched.

## Properties proven

| Function | File | Property | Bounds / assumptions |
| --- | --- | --- | --- |
| `check_nonzeroDeltaCannotUnlock(int128 delta)` | `TransientDeltaSolvency.t.sol` | An unlock with any non-zero transient delta reverts with exactly `CurrencyNotSettled(DUMMY, delta)` | `delta != 0` (`vm.assume`); `delta` ranges over all `int128` |
| `check_zeroDeltaCanUnlock()` | `TransientDeltaSolvency.t.sol` | An unlock with zero delta succeeds and the vault is locked again afterwards | No symbolic inputs |
| `check_claimsTransferConservation(uint128 initialBalAlice, uint128 transferAmount)` | `VaultSolvencyProof.t.sol` | Minting claims to Alice then transferring part to Bob conserves the total claim supply and lands exact balances | `initialBalAlice > 0`, `transferAmount <= initialBalAlice`; both amounts additionally bounded by `uint128(type(int128).max)` because the vault's per-call mint/settle bounds are `int128` (C-01 fix) |
| `check_pauseStateTransition(bytes32 poolIdRaw)` | `CircuitBreakerFormal.t.sol` | A guardian can pause a pool and only the owner can unpause it | `poolIdRaw` arbitrary; `pausePool` is `onlyGuardianOrOwner`, `unpausePool` is `onlyOwner` |
| `check_mulDivRoundingUpAlwaysGreaterOrEqual(uint128 a, uint128 b, uint128 denominator)` | `MathMonotonicityProof.t.sol` | `mulDivUp >= mulDiv` and the difference is at most 1 | `denominator != 0` (early return); pure math, no state |
| `check_safeCastIdentityInRange(uint128 x)` | `MathMonotonicityProof.t.sol` | `SafeCastLib.toUint128` round-trips any `uint128` | Pure math, no state |

Local results (26 Nov 2026, 22:41 WAT, Halmos 0.3.3, z3, `--loop 2`,
`--solver-timeout-assertion 120000`, run in the minimal verification vehicle —
see "Local verification" below — against the exact committed files).
**All 6 properties pass; halmos exit code 0.**
Full log: `/tmp/halmos-final-run3.log`. An earlier identical run on the
pre-`forge fmt` files gave the same 6/6 pass with slightly different timings
(`/tmp/halmos-final-run2.log`, 22:24 WAT); path counts vary a little run to
run (solver ordering), all results pass.

| Function | Result | Paths | Time |
| --- | --- | --- | --- |
| `check_nonzeroDeltaCannotUnlock(int128)` | PASS | 3 | 0.48 s |
| `check_zeroDeltaCanUnlock()` | PASS | 1 | 0.09 s |
| `check_claimsTransferConservation(uint128,uint128)` | PASS | 13 | 4.98 s |
| `check_pauseStateTransition(bytes32)` | PASS | 1 | 0.20 s |
| `check_mulDivRoundingUpAlwaysGreaterOrEqual(uint128,uint128,uint128)` | PASS | 15 | 8.09 s |
| `check_safeCastIdentityInRange(uint128)` | PASS | 2 | 0.11 s |

Total Halmos run time: ~15 s (warm build reused). For comparison, the same
command against the ORIGINAL unfixed harnesses gave 2 pass / 4 fail-error
(26 Nov 2026, 21:34 WAT, `/tmp/halmos-orig-run1.log`): the two Math properties
passed, CircuitBreaker failed on `deployCode`, TransientDelta's nonzero
errored on `expectRevert` and its zero case failed on the missing callback,
and VaultSolvency failed with "all paths have been reverted".

## Harness fixes (T-5) — why the original properties did not prove their claims

Two of the six properties had harness flaws of the same class, and one
property could not be expressed with a Halmos-supported cheatcode. Only the
test harnesses were fixed; **no contract code was changed** to make a proof pass.

### 1. The callback flaw — `TransientDeltaSolvency` (and `VaultSolvencyProof`)

`SupaVault.unlock` calls back into `msg.sender` — the unlock *caller* — via
`IUnlockCallback(msg.sender).unlockCallback(data)`. The original properties
called `vault.unlock("")` from the test contract, which implements no
`unlockCallback` and has no fallback, so `unlock` reverted for the
missing-callback reason, not the delta reason:

- `check_nonzeroDeltaCannotUnlock` expected a revert and got one — a **vacuous
  pass**: it proved nothing about deltas.
- `check_zeroDeltaCanUnlock` expected success and got a revert — it **failed**
  for the wrong reason.

Fix: the unlock is now performed by a dedicated callback contract
(`UnsettledCallback.unlock()`), so the locker is the callback itself; inside
`unlockCallback` the delta account is `address(this)` (the callback), because
there `msg.sender` is the vault, not the locker. The zero-delta property now
unlocks through the callback and asserts the vault is locked again.

The same class of flaw existed in `VaultSolvencyProof.mintClaims`: its
`unlockCallback` credited the delta to `msg.sender` — the vault, not the
minter — so the minter's `-amount` and the vault's `+amount` never cancelled
and `unlock` always reverted `CurrencyNotSettled` for any `amount > 0`.

### 2. The unbacked mint — `VaultSolvencyProof`

Even with the account fixed, the original mint could never succeed: the
`efba73c` `_enforceClaimBacking` check (`claimSupplyOf <= reservesOf`,
`ClaimsExceedReserves`) reverts on an unbacked mint (supply `amount`, reserves
`0`). The fix backs the mint the way production mints work — `sync` →
`transfer` → `settle` (credits the minter `+amount`) then `mint` (debits the
minter `-amount`), net delta zero, supply == reserves — using a minimal local
`FormalMockERC20` (mint/transfer/balanceOf only). Amounts are bounded by
`uint128(type(int128).max)` per the vault's `int128` per-call bounds, and the
minter is funded with that maximum in `setUp`.

### 3. `vm.expectRevert` is not implemented in Halmos 0.3.3

Halmos 0.3.3 has no handler for any `vm.expectRevert` overload (verified in
the installed source and by observation: `Unsupported cheat code: expectRevert()`).
The nonzero-delta `check_` therefore asserts the revert reason with a
low-level call and a returndata comparison instead:

```solidity
(bool ok, bytes memory ret) = address(callback).call(
    abi.encodeWithSelector(UnsettledCallback.unlock.selector)
);
assertFalse(ok);
assertEq(
    ret,
    abi.encodeWithSelector(VaultErrors.CurrencyNotSettled.selector, DUMMY, int256(delta))
);
```

This pins the exact revert reason in pure Solidity, so the property cannot pass
vacuously on a different revert. The `forge test` mirrors (`testFuzz_*` /
`test_*`) keep `vm.expectRevert(abi.encodeWithSelector(...))` with the same
expected data — forge supports it — and the deliberate divergence is documented
here. The mirrors exist so `forge test` also exercises the routing; they are
not the proof.

## Halmos 0.3.3 limitations observed

- `vm.expectRevert` (all overloads): not implemented — see §3 above.
- `vm.deployCode` / `vm.getCode`: `deployCode` not implemented; `getCode` is
  implemented but builds the artifact path as `out/<filename>/<contract>.json`
  where the filename is the part before `:`, which does not match foundry's flat
  `out/<File>.sol/<Contract>.json` layout for nested source paths. Neither is
  needed any more: the `[profile.halmos]` profile keeps `new` as plain `CREATE`,
  so no `deployCode`/`getCode` call is generated.
- `vm.prank` / `startPrank` / `stopPrank`: implemented and used by
  `VaultSolvencyProof` and `CircuitBreakerFormal`.
- `vm.assume`: supported.

## Assumptions, bounds, and what is NOT covered

- **Loop bound:** `--loop 2`. Properties that need more than 2 loop iterations
  per path are out of scope for this job; none of the six properties above
  needs loops at all (the bound is a safety cap, not a proof ingredient).
- **Single-call properties only.** Halmos proves each `check_` over a single
  symbolic call from a fixed setup state. Properties over *sequences* of
  unlocks — e.g. chained zero-sum unlocks — are not expressed here; they live
  in the T-1 coverage work (`testFuzz_chainedZeroSumUnlocks` in the same file's
  forge mirrors, owned by the coverage-tests agent).
- **No cross-protocol invariants.** Halmos proves properties of this codebase
  in isolation; invariants spanning SupaDEX and another protocol (e.g. an
  external lending market) cannot be expressed as a `check_` here.
- **Solver timeouts are failures, not passes.** A `--solver-timeout-assertion`
  expiry fails the function; the CI job then fails. A green run means every
  solver query answered within 120 s.
- **Symbolic inputs are `check_` arguments only.** State is concrete at the
  start of each `check_` (fresh `setUp`), except for the symbolic arguments
  listed in the table above.
- **The `CurrencyNotSettled` selector pin** in the nonzero-delta property is
  exact: `VaultErrors.CurrencyNotSettled(Currency,int256)` with the dummy
  currency `0x1234567890123456789012345678901234567890` and the symbolic delta.
  If the vault's revert changes, this property fails loudly rather than
  passing vacuously.

## Local verification

The full-repo via_ir + AST build does not fit the shared 6–8 GB development
VM (solc is OOM-killed, signal 9, at ~3.4 GB during the full-tree build when
sibling agents run concurrent builds; the legacy profile cannot build the full
tree either — `Stack too deep` in `test/jexi/rv-039-040/JexiRV039040.t.sol`,
which only compiles with via_ir). Local Halmos runs therefore use a minimal
vehicle (`/tmp/halmos-min`, not part of the repo): a byte-identical copy of
`contract/` and `test/formal/` only, with symlinked `lib/` and a `foundry.toml`
replicating the repo's default profile plus the same `[profile.halmos]`
section. Same compiler pipeline, same sources, fewer test files. CI runs the
full repository on a GitHub-hosted runner (16 GB), so the vehicle deviation
affects local runs only and is disclosed here, not hidden.

Local verification performed 26 Nov 2026:

- `forge build --ast --extra-output storageLayout metadata` in the vehicle
  with `FOUNDRY_PROFILE=halmos`: exit 0.
- `halmos --function check_ --solver z3 --loop 2
  --solver-timeout-assertion 120000` in the vehicle: see the results table
  above.
- `forge test --match-path "test/formal/*"` in the real worktree: both forge
  mirrors pass (previously `test_zeroDeltaCanUnlock` failed).
- `forge fmt --check` and `forge build` in the real worktree: see the
  phase-2 report for exact outputs.
