// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";
import {PeripheryErrors} from "../../contract/errors/PeripheryErrors.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";
import {CircuitBreakerErrors} from "../../contract/errors/CircuitBreakerErrors.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";

/// @notice T-6: shared, explicit revert taxonomy for invariant handlers.
///
/// `fail_on_revert = false` (foundry.toml `[invariant]` and `[profile.ci.invariant]`) means
/// Foundry silently discards ANY handler call that reverts. Before this file, only
/// CrossProtocolInvariant classified reverts (4 selectors); every other invariant handler
/// either had no try/catch at all (reverts discarded by the fuzzer) or a bare `catch {}`
/// (VaultSolvencyInvariant.mintClaims, LVRDynamicFeeInvariant oracle.write).
///
/// This library is the single choke point: every handler routes caught revert data through
/// `classify` with an explicit context bitmask, and anything not enumerated here is
/// UNEXPECTED by construction. There is no catch-all "expected" bucket.
///
/// Contexts (bitmask) — a selector is expected ONLY in the contexts that name it:
/// - CTX_ECONOMIC: legitimate market/liquidity/slippage guards firing on fuzzed inputs.
/// - CTX_INPUT:    caller-supplied parameter validation (ticks, ranges, paths, ids).
/// - CTX_EXTREME:  extreme-magnitude guards (C-01 checked arithmetic / int128 casts). Only
///                  the vault-claims handler, which fuzzes the full uint256 amount domain,
///                  may grant this. Anywhere else a SafeCastOverflow/DeltaOverflow is a bug.
/// - CTX_ACCESS:   access-control denials, granted ONLY to the unauthorized-caller probe,
///                  where a revert is the expected (secure) outcome.
library RevertClassifier {
    uint8 internal constant CTX_ECONOMIC = 1;
    uint8 internal constant CTX_INPUT = 2;
    uint8 internal constant CTX_EXTREME = 4;
    uint8 internal constant CTX_ACCESS = 8;

    /// @notice Panic(uint256) selector (Solidity 0.8 checked arithmetic, incl. 0x11 arithmetic
    ///         underflow — the C-02 mirror-direction DoS — and 0x12 division by zero).
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    /// @notice Error(string) selector (require strings, e.g. mock-token "Insufficient").
    bytes4 internal constant ERROR_STRING_SELECTOR = 0x08c379a0;

    enum Kind {
        Unexpected,
        ExpectedEconomic,
        ExpectedInput,
        ExpectedExtreme,
        ExpectedAccess
    }

    /// @dev Solady ERC721 error, thrown by SupaPositionManager for a non-existent NFT id.
    ///      Declared here (same signature => same selector) so the classifier can name it.
    error TokenDoesNotExist();

    /// @notice Classify raw revert data under `ctx`. Returns (kind, selector).
    /// @dev Only the first 4 bytes are read, so `abi.encodeWithSelector(...)` payloads
    ///      classify identically to real reverts. Short (< 4 bytes) or empty data, Panic,
    ///      Error(string) and any unlisted selector are UNEXPECTED.
    function classify(bytes memory err, uint8 ctx) internal pure returns (Kind kind, bytes4 selector) {
        if (err.length < 4) return (Kind.Unexpected, bytes4(0));
        selector = bytes4(err);
        if (selector == PANIC_SELECTOR || selector == ERROR_STRING_SELECTOR) return (Kind.Unexpected, selector);

        if ((ctx & CTX_ECONOMIC) != 0 && _isEconomic(selector)) return (Kind.ExpectedEconomic, selector);
        if ((ctx & CTX_INPUT) != 0 && _isInput(selector)) return (Kind.ExpectedInput, selector);
        if ((ctx & CTX_EXTREME) != 0 && _isExtreme(selector)) return (Kind.ExpectedExtreme, selector);
        if ((ctx & CTX_ACCESS) != 0 && _isAccess(selector)) return (Kind.ExpectedAccess, selector);
        return (Kind.Unexpected, selector);
    }

    /// @notice True iff `err` is expected under `ctx` (convenience wrapper).
    function isExpected(bytes memory err, uint8 ctx) internal pure returns (bool) {
        (Kind kind,) = classify(err, ctx);
        return kind != Kind.Unexpected;
    }

    /// @notice Legitimate economic guards: the market/pool refused the operation for a
    ///         priced, bounded reason. The caller can retry with a different size/price.
    function _isEconomic(bytes4 sel) private pure returns (bool) {
        return sel == PoolErrors.InsufficientLiquidity.selector // swap/output exceeds available liquidity
            || sel == PoolErrors.ZeroSwapAmount.selector // zero amountSpecified, or fee consumes whole input
            || sel == PoolErrors.StableImbalanceExceeded.selector // swap breaches configured imbalance bound
            || sel == PoolErrors.InsufficientInitialLiquidity.selector // first Stable deposit <= MINIMUM_LIQUIDITY
            || sel == PoolErrors.StableInvariantViolated.selector // StableSwap D would decrease (solver guard)
            || sel == PoolErrors.StableMathNotConverged.selector // StableSwap Newton did not converge (bounded)
            || sel == PoolErrors.PriceLimitAlreadyExceeded.selector // caller price limit already reached
            || sel == PoolErrors.LiquidityOverflow.selector // remove exceeds position/pool liquidity
            || sel == PoolErrors.TickLiquidityOverflow.selector // add exceeds max liquidity per tick
            || sel == PoolErrors.NoLiquidityToDonate.selector // donate with zero active liquidity
            || sel == PoolErrors.SlippageExceeded.selector // pool-level slippage guard
            || sel == PeripheryErrors.SlippageExceeded.selector // router / position-manager slippage protection
            || sel == PeripheryErrors.InsufficientOutputAmount.selector // exact-output shortfall (no partial fill)
            || sel == PeripheryErrors.DeadlinePassed.selector // caller deadline elapsed
            || sel == PeripheryErrors.InsufficientETH.selector // caller sent too little native ETH
            || sel == PeripheryErrors.ZeroAmount.selector // zero-amount periphery call
            || sel == PeripheryErrors.ZeroLiquidity.selector // zero-liquidity position call
            || sel == VaultErrors.ZeroAmount.selector // zero-amount vault call
            || sel == PeripheryErrors.ETHTransferFailed.selector // recipient cannot receive ETH (L-05; recipient-dependent)
            || sel == VaultErrors.ETHTransferFailed.selector; // as above, vault leg
    }

    /// @notice Caller-input validation: malformed ticks/ranges/paths/ids. These should never
    ///         fire in the fixed-parameter strict suite; they are expected only in the sense
    ///         that they are input errors, not protocol failures.
    function _isInput(bytes4 sel) private pure returns (bool) {
        return sel == PoolErrors.TicksMisordered.selector || sel == PoolErrors.TickNotSpaced.selector
            || sel == PoolErrors.TickOutOfBounds.selector || sel == PoolErrors.InvalidTickSpacing.selector
            || sel == PoolErrors.InvalidBinStep.selector || sel == PoolErrors.BinIdOutOfBounds.selector
            || sel == PoolErrors.BinRangeTooWide.selector || sel == PoolErrors.StableInvalidAmplification.selector
            || sel == PoolErrors.StableDecimalsUnsupported.selector || sel == PoolErrors.StableDecimalsMismatch.selector
            || sel == PoolErrors.InvalidInitParams.selector || sel == PoolErrors.CurrenciesOutOfOrderOrEqual.selector
            || sel == PoolErrors.PriceLimitOutOfBounds.selector || sel == PeripheryErrors.InvalidPath.selector
            || sel == PeripheryErrors.IdenticalCurrencies.selector || sel == PeripheryErrors.InvalidPoolKey.selector
            || sel == PeripheryErrors.PositionNotFound.selector || sel == TokenDoesNotExist.selector;
    }

    /// @notice Extreme-magnitude guards (C-01 fix working as designed). Granted ONLY to the
    ///         handler that fuzzes the full uint256 amount domain.
    function _isExtreme(bytes4 sel) private pure returns (bool) {
        return sel == SafeCastLib.SafeCastOverflow.selector || sel == VaultErrors.DeltaOverflow.selector;
    }

    /// @notice Access-control denials. Granted ONLY to the unauthorized-caller probe.
    function _isAccess(bytes4 sel) private pure returns (bool) {
        return sel == VaultErrors.Unauthorized.selector || sel == PeripheryErrors.Unauthorized.selector
            || sel == PoolErrors.InvalidProtocolFeeController.selector || sel == PoolErrors.NotGovernance.selector;
    }
}

/// @notice Shared handler base: counters + the single classification choke point.
///         Handlers inherit this and route EVERY caught revert through `_classify`.
///         `invariant_noUnexpectedReverts` in each suite asserts `unexpectedReverts == 0`.
abstract contract RevertClassifyingHandler {
    uint256 public expectedReverts;
    uint256 public unexpectedReverts;
    bytes4 public lastUnexpected;
    string public lastUnexpectedOp;
    mapping(bytes4 => uint256) public expectedBySelector;
    mapping(bytes4 => uint256) public unexpectedBySelector;
    mapping(string => uint256) public calls;

    /// @notice Classify `err` under `ctx` for operation `op`; count it. Never reverts.
    function _classify(bytes memory err, uint8 ctx, string memory op) internal {
        (RevertClassifier.Kind kind, bytes4 sel) = RevertClassifier.classify(err, ctx);
        if (kind == RevertClassifier.Kind.Unexpected) {
            unexpectedReverts++;
            unexpectedBySelector[sel]++;
            lastUnexpected = sel;
            lastUnexpectedOp = op;
        } else {
            expectedReverts++;
            expectedBySelector[sel]++;
        }
    }
}
