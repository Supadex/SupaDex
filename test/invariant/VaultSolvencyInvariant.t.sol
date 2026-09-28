// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";

contract MockSolvencyToken {
    string public name = "Solvency Token";
    string public symbol = "SLV";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockSolvencyToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultSolvencyHandler is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    MockSolvencyToken public token;
    Currency public currency;
    uint256 public totalMintedClaims;

    constructor(SupaVault _vault, MockSolvencyToken _token) {
        vault = _vault;
        token = _token;
        currency = Currency.wrap(address(_token));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        if (action == 0) {
            // Settle + Mint Claim
            vault.settle(currency);
            vault.mint(currency, address(this), amount);
            totalMintedClaims += amount;
        } else if (action == 1) {
            // Burn Claim + Take
            if (amount > totalMintedClaims) amount = totalMintedClaims;
            if (amount > 0) {
                vault.burn(currency, amount);
                vault.take(currency, address(this), amount);
                totalMintedClaims -= amount;
            }
        }
        return "";
    }

    function mintClaims(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000 ether);
        token.mint(address(vault), amount);
        vault.unlock(abi.encode(uint8(0), amount));
    }

    function burnClaims(uint256 amount) external {
        if (totalMintedClaims == 0) return;
        amount = bound(amount, 1, totalMintedClaims);
        vault.unlock(abi.encode(uint8(1), amount));
    }
}

contract VaultSolvencyInvariantTest is StdInvariant, Test {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    MockSolvencyToken public token;
    VaultSolvencyHandler public handler;

    function setUp() public {
        vault = new SupaVault(address(this));
        token = new MockSolvencyToken();
        handler = new VaultSolvencyHandler(vault, token);

        targetContract(address(handler));
    }

    /// @notice Invariant: Physical token balance held by Vault must always be >= total outstanding ERC-6909 claims.
    function invariant_vaultSolvency() public view {
        uint256 physicalBalance = token.balanceOf(address(vault));
        uint256 claimsTotal = vault.balanceOf(address(handler), Currency.wrap(address(token)).toId());
        assertGe(physicalBalance, claimsTotal);
    }
}
