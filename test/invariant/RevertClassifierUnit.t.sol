// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";
import {PeripheryErrors} from "../../contract/errors/PeripheryErrors.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";
import {RevertClassifier} from "./RevertClassifier.sol";

/// @notice T-6: pure classifier unit tests. Deliberately light (no deployment, no
///         protocol imports) so they compile and run fast in any profile, including
///         on memory-constrained CI runners.
contract RevertClassifierUnitTest is Test {
    uint8 internal constant ECON = RevertClassifier.CTX_ECONOMIC | RevertClassifier.CTX_INPUT;
    uint8 internal constant EXTREME =
        RevertClassifier.CTX_ECONOMIC | RevertClassifier.CTX_INPUT | RevertClassifier.CTX_EXTREME;

    function test_classifierExpectedEconomicSelectors() public pure {
        bytes4[8] memory sels = [
            PoolErrors.InsufficientLiquidity.selector,
            PoolErrors.ZeroSwapAmount.selector,
            PoolErrors.StableImbalanceExceeded.selector,
            PoolErrors.InsufficientInitialLiquidity.selector,
            PoolErrors.StableMathNotConverged.selector,
            PoolErrors.PriceLimitAlreadyExceeded.selector,
            PoolErrors.LiquidityOverflow.selector,
            PeripheryErrors.SlippageExceeded.selector
        ];
        for (uint256 i; i < sels.length; i++) {
            (RevertClassifier.Kind kind,) = RevertClassifier.classify(abi.encodeWithSelector(sels[i]), ECON);
            assertTrue(kind != RevertClassifier.Kind.Unexpected, "economic selector misclassified");
        }
    }

    function test_classifierExpectedInputSelectors() public pure {
        bytes4[4] memory sels = [
            PoolErrors.TicksMisordered.selector,
            PoolErrors.TickNotSpaced.selector,
            PoolErrors.BinRangeTooWide.selector,
            PeripheryErrors.InvalidPath.selector
        ];
        for (uint256 i; i < sels.length; i++) {
            (RevertClassifier.Kind kind,) = RevertClassifier.classify(abi.encodeWithSelector(sels[i]), ECON);
            assertTrue(kind != RevertClassifier.Kind.Unexpected, "input selector misclassified");
        }
    }

    function test_classifierExtremeIsContextGated() public pure {
        bytes memory deltaOverflow = abi.encodeWithSelector(VaultErrors.DeltaOverflow.selector);
        bytes memory safeCast = abi.encodeWithSelector(SafeCastLib.SafeCastOverflow.selector);
        (RevertClassifier.Kind k1,) = RevertClassifier.classify(deltaOverflow, ECON);
        (RevertClassifier.Kind k2,) = RevertClassifier.classify(safeCast, ECON);
        assertEq(uint8(k1), uint8(RevertClassifier.Kind.Unexpected), "DeltaOverflow must be unexpected w/o EXTREME");
        assertEq(uint8(k2), uint8(RevertClassifier.Kind.Unexpected), "SafeCastOverflow must be unexpected w/o EXTREME");
        (RevertClassifier.Kind k3,) = RevertClassifier.classify(deltaOverflow, EXTREME);
        (RevertClassifier.Kind k4,) = RevertClassifier.classify(safeCast, EXTREME);
        assertEq(uint8(k3), uint8(RevertClassifier.Kind.ExpectedExtreme), "DeltaOverflow must be expected w/ EXTREME");
        assertEq(
            uint8(k4), uint8(RevertClassifier.Kind.ExpectedExtreme), "SafeCastOverflow must be expected w/ EXTREME"
        );
    }

    function test_classifierAccessIsContextGated() public pure {
        bytes memory unauth = abi.encodeWithSelector(VaultErrors.Unauthorized.selector);
        (RevertClassifier.Kind k1,) = RevertClassifier.classify(unauth, ECON);
        assertEq(uint8(k1), uint8(RevertClassifier.Kind.Unexpected), "Unauthorized must be unexpected w/o ACCESS");
        (RevertClassifier.Kind k2,) = RevertClassifier.classify(unauth, RevertClassifier.CTX_ACCESS);
        assertEq(uint8(k2), uint8(RevertClassifier.Kind.ExpectedAccess), "Unauthorized must be expected w/ ACCESS");
    }

    function test_classifierRejectsPanicsStringsEmptyAndUnknown() public pure {
        // C-02 mirror direction: arithmetic underflow Panic(0x11) — must NEVER be expected.
        bytes memory panic11 = abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11));
        bytes memory panic12 = abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x12));
        bytes memory errString = abi.encodeWithSelector(bytes4(0x08c379a0), "Insufficient");
        bytes memory empty = new bytes(0);
        bytes memory unknown = abi.encodeWithSelector(bytes4(0xdeadbeef));
        assertFalse(RevertClassifier.isExpected(panic11, EXTREME), "Panic(0x11) must be unexpected");
        assertFalse(RevertClassifier.isExpected(panic12, EXTREME), "Panic(0x12) must be unexpected");
        assertFalse(RevertClassifier.isExpected(errString, EXTREME), "Error(string) must be unexpected");
        assertFalse(RevertClassifier.isExpected(empty, EXTREME), "empty revert must be unexpected");
        assertFalse(RevertClassifier.isExpected(unknown, EXTREME), "unknown selector must be unexpected");
    }

    function test_classifierSolvencyGuardsAreUnexpected() public pure {
        // These guards firing means accounting is already wrong; treating them as
        // "expected economics" would hide the next C-01 / M-01.
        bytes memory insolvent = abi.encodeWithSelector(
            PoolErrors.PoolInsolvent.selector, PoolId.wrap(bytes32(0)), Currency.wrap(address(0)), 1, 0
        );
        bytes memory unsettled =
            abi.encodeWithSelector(VaultErrors.CurrencyNotSettled.selector, Currency.wrap(address(0)), int256(1));
        bytes memory claims =
            abi.encodeWithSelector(VaultErrors.ClaimsExceedReserves.selector, Currency.wrap(address(0)), 2, 1);
        bytes memory hook = abi.encodeWithSelector(PoolErrors.HookDeltaNotAllowed.selector, address(0));
        bytes memory notInit = abi.encodeWithSelector(PoolErrors.PoolNotInitialized.selector, PoolId.wrap(bytes32(0)));
        bytes memory pluginFail =
            abi.encodeWithSelector(PluginErrors.PluginCallFailed.selector, address(0), bytes4(0), new bytes(0));
        assertFalse(RevertClassifier.isExpected(insolvent, EXTREME), "PoolInsolvent must be unexpected");
        assertFalse(RevertClassifier.isExpected(unsettled, EXTREME), "CurrencyNotSettled must be unexpected");
        assertFalse(RevertClassifier.isExpected(claims, EXTREME), "ClaimsExceedReserves must be unexpected");
        assertFalse(RevertClassifier.isExpected(hook, EXTREME), "HookDeltaNotAllowed must be unexpected");
        assertFalse(RevertClassifier.isExpected(notInit, EXTREME), "PoolNotInitialized must be unexpected");
        assertFalse(RevertClassifier.isExpected(pluginFail, EXTREME), "PluginCallFailed must be unexpected");
    }
}
