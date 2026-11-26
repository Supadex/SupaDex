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

    /// @dev The locker must be this contract: vault.unlock() callbacks
    /// msg.sender, so the test calls unlock() here — NOT vault.unlock()
    /// directly from the test contract, which implements no unlockCallback.
    /// Calling vault.unlock() from the test contract reverts for the missing
    /// callback, which made check_nonzeroDeltaCannotUnlock pass vacuously
    /// (it expects a revert and got one, but for the wrong reason) and made
    /// check_zeroDeltaCanUnlock fail outright. See T-5.
    function unlock() external {
        vault.unlock("");
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        if (deltaToApply != 0) {
            // Deltas land on this contract's (the locker's) account. Note
            // msg.sender here is the vault, NOT the locker, so address(this)
            // is passed explicitly.
            vault.accountDelta(address(this), token, deltaToApply);
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
    /// @dev The revert reason is pinned exactly (selector + currency + delta):
    /// a bare expectRevert() would also pass on a missing-callback revert, which is
    /// the vacuous-pass flaw this harness fix removes.
    /// Halmos 0.3.3 does NOT implement vm.expectRevert (any overload), so the
    /// property asserts the revert reason with a low-level call and a returndata
    /// comparison instead. The forge mirror below keeps vm.expectRevert with the
    /// same expected data (forge supports it); the divergence is deliberate.
    function check_nonzeroDeltaCannotUnlock(int128 delta) external {
        vm.assume(delta != 0);

        callback.setDelta(int256(delta));

        (bool ok, bytes memory ret) = address(callback).call(abi.encodeWithSelector(UnsettledCallback.unlock.selector));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(VaultErrors.CurrencyNotSettled.selector, DUMMY, int256(delta)));
    }

    /// @notice Proves theorem: When delta is zero, unlock succeeds and lock is released.
    function check_zeroDeltaCanUnlock() external {
        callback.setDelta(0);
        callback.unlock();
        assertFalse(vault.isUnlocked());
    }

    /// @notice Forge mirror of check_nonzeroDeltaCannotUnlock (same routing as
    /// the check_ original: the callback contract is the locker).
    function testFuzz_nonzeroDeltaCannotUnlock(int128 delta) public {
        vm.assume(delta != 0);
        callback.setDelta(int256(delta));
        vm.expectRevert(abi.encodeWithSelector(VaultErrors.CurrencyNotSettled.selector, DUMMY, int256(delta)));
        callback.unlock();
    }

    /// @notice Forge mirror of check_zeroDeltaCanUnlock (same routing as the
    /// check_ original: the callback contract is the locker).
    function test_zeroDeltaCanUnlock() public {
        callback.setDelta(0);
        callback.unlock();
        assertFalse(vault.isUnlocked());
    }
}
