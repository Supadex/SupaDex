// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";

contract UnsettledCallback is IUnlockCallback {
    SupaVault public vault;
    Currency public token;
    int256 public deltaToApply;

    constructor(SupaVault _vault, Currency _token) {
        vault = _vault;
        token = _token;
    }

    function setDelta(int256 _delta) external {
        deltaToApply = _delta;
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        if (deltaToApply != 0) {
            vault.accountDelta(msg.sender, token, deltaToApply);
        }
        return "";
    }
}

/// @title TransientDeltaSolvencyFormalProof
/// @notice Halmos / Forge-Symbolic formal proof verifying that nonzero delta states cannot be finalized.
contract TransientDeltaSolvencyFormalProof is Test {
    SupaVault public vault;
    UnsettledCallback public callback;
    Currency public constant DUMMY = Currency.wrap(address(0x1234567890123456789012345678901234567890));

    function setUp() external {
        vault = new SupaVault(address(this));
        callback = new UnsettledCallback(vault, DUMMY);
        vault.setPoolManager(address(callback), true);
    }

    /// @notice Proves theorem: For any nonzero delta, unlock MUST revert with CurrencyNotSettled.
    function check_nonzeroDeltaCannotUnlock(int128 delta) external {
        vm.assume(delta != 0);

        callback.setDelta(int256(delta));

        vm.expectRevert();
        vault.unlock("");
    }

    /// @notice Proves theorem: When delta is zero, unlock succeeds and lock is released.
    function check_zeroDeltaCanUnlock() external {
        callback.setDelta(0);
        vault.unlock("");
        assertFalse(vault.isUnlocked());
    }
}
