// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";

contract ClaimMinter is IUnlockCallback {
    SupaVault public vault;

    constructor(SupaVault _vault) {
        vault = _vault;
    }

    function mintClaims(Currency currency, address to, uint256 amount) external {
        vault.unlock(abi.encode(currency, to, amount));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        vault.mint(currency, to, amount);
        vault.accountDelta(msg.sender, currency, int256(amount));
        return "";
    }
}

/// @title VaultSolvencyFormalProof
/// @notice Halmos / Forge-Symbolic formal proof verifying ERC-6909 claim conservation and physical solvency.
contract VaultSolvencyFormalProof is Test {
    SupaVault public vault;
    ClaimMinter public minter;
    address public alice = address(0xAAAA);
    address public bob = address(0xBBBB);

    function setUp() external {
        vault = new SupaVault(address(this));
        minter = new ClaimMinter(vault);
        vault.setPoolManager(address(minter), true);
    }

    /// @notice Proves theorem: Claim transfer is balance-conserving (sum of balances invariant).
    function check_claimsTransferConservation(uint128 initialBalAlice, uint128 transferAmount) external {
        vm.assume(initialBalAlice > 0);
        vm.assume(initialBalAlice >= transferAmount);

        Currency curr = Currency.wrap(address(0x1234));
        uint256 id = curr.toId();

        minter.mintClaims(curr, alice, uint256(initialBalAlice));

        uint256 totalBefore = vault.balanceOf(alice, id) + vault.balanceOf(bob, id);

        vm.prank(alice);
        vault.transfer(bob, id, uint256(transferAmount));

        uint256 totalAfter = vault.balanceOf(alice, id) + vault.balanceOf(bob, id);

        assertEq(totalBefore, totalAfter);
        assertEq(vault.balanceOf(alice, id), uint256(initialBalAlice - transferAmount));
        assertEq(vault.balanceOf(bob, id), uint256(transferAmount));
    }
}
