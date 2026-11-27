// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";

/// @notice Minimal ERC20 mock (mint / transfer / balanceOf only) used to back
/// claim mints with real reserves. Mirrors the MockERC20 in
/// test/unit/SupaVault.t.sol; kept local so this formal file is self-contained.
contract FormalMockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ClaimMinter is IUnlockCallback {
    SupaVault public vault;
    FormalMockERC20 public token;

    constructor(SupaVault _vault, FormalMockERC20 _token) {
        vault = _vault;
        token = _token;
    }

    function mintClaims(Currency currency, address to, uint256 amount) external {
        vault.unlock(abi.encode(currency, to, amount));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        // T-5 fix: the ORIGINAL harness minted unbacked claims and settled the
        // delta onto the WRONG account (msg.sender here is the vault, not the
        // locker), so mintClaims could never succeed: the minter's -amount
        // delta and the vault's +amount delta both stayed nonzero and unlock
        // always reverted CurrencyNotSettled — and even with the account fixed,
        // the efba73c claim-backing check (supply <= reserves) would revert
        // ClaimsExceedReserves on an unbacked mint. The mint must be backed
        // the same way production mints are: sync -> transfer -> settle
        // (credits the minter +amount), then mint (debits the minter -amount),
        // leaving a zero net delta and supply == reserves.
        vault.sync(currency);
        token.transfer(address(vault), amount);
        vault.settle(currency);
        vault.mint(currency, to, amount);
        return "";
    }
}

/// @title VaultSolvencyFormalProof
/// @notice Halmos / Forge-Symbolic formal proof verifying ERC-6909 claim conservation and physical solvency.
contract VaultSolvencyFormalProof is Test {
    SupaVault public vault;
    ClaimMinter public minter;
    FormalMockERC20 public token;
    Currency public curr;
    address public alice = address(0xAAAA);
    address public bob = address(0xBBBB);

    function setUp() external {
        vault = new SupaVault(address(this));
        token = new FormalMockERC20();
        curr = Currency.wrap(address(token));
        minter = new ClaimMinter(vault, token);
        vault.setPoolManager(address(minter), true);
        // Fund the minter up to the largest mint the property ranges over
        // (int128.max, the vault's per-call bound); the property assumes
        // initialBalAlice <= int128.max so the funding always covers it.
        token.mint(address(minter), uint256(uint128(type(int128).max)));
    }

    /// @notice Proves theorem: Claim transfer is balance-conserving (sum of balances invariant).
    /// @dev Bounds: initialBalAlice is capped at int128.max because the vault
    /// bounds every per-call mint/settle to int128 (C-01 fix); larger mints
    /// revert SafeCastOverflow by design and are outside this property.
    function check_claimsTransferConservation(uint128 initialBalAlice, uint128 transferAmount) external {
        vm.assume(initialBalAlice > 0);
        vm.assume(initialBalAlice <= uint128(type(int128).max));
        vm.assume(initialBalAlice >= transferAmount);

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
