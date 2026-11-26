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
    // T-1: second currency so the invariant covers the SUM over currencies,
    // not just one currency in isolation.
    MockSolvencyToken public token2;
    Currency public currency2;
    uint256 public totalMintedClaims2;

    constructor(SupaVault _vault, MockSolvencyToken _token) {
        vault = _vault;
        token = _token;
        currency = Currency.wrap(address(_token));
        token2 = new MockSolvencyToken();
        currency2 = Currency.wrap(address(token2));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        if (action == 0) {
            // Sync + pay + settle + Mint Claim
            vault.sync(currency);
            token.mint(address(vault), amount);
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
        } else if (action == 2) {
            vault.sync(currency2);
            token2.mint(address(vault), amount);
            vault.settle(currency2);
            vault.mint(currency2, address(this), amount);
            totalMintedClaims2 += amount;
        } else if (action == 3) {
            if (amount > totalMintedClaims2) amount = totalMintedClaims2;
            if (amount > 0) {
                vault.burn(currency2, amount);
                vault.take(currency2, address(this), amount);
                totalMintedClaims2 -= amount;
            }
        }
        return "";
    }

    function mintClaims(uint256 amount) external {
        // Full uint256 domain, including magnitudes that would wrap an unchecked delta (C-01 / T-1).
        // Amounts above int128.max revert inside the unlock; successful mints stay backed by a settle.
        amount = bound(amount, 1, type(uint256).max);
        try vault.unlock(abi.encode(uint8(0), amount)) {} catch {}
    }

    function burnClaims(uint256 amount) external {
        if (totalMintedClaims == 0) return;
        // The per-call burn bound is int128.max; the ghost total can exceed
        // it across many mints, so cap the fuzzed amount there (amounts above
        // it revert in the vault by design, not by bug).
        uint256 cap = totalMintedClaims > uint256(uint128(type(int128).max))
            ? uint256(uint128(type(int128).max))
            : totalMintedClaims;
        amount = bound(amount, 1, cap);
        vault.unlock(abi.encode(uint8(1), amount));
    }

    function mintClaims2(uint256 amount) external {
        // Full uint256 domain, including magnitudes that would wrap an unchecked delta (C-01 / T-1).
        amount = bound(amount, 1, type(uint256).max);
        try vault.unlock(abi.encode(uint8(2), amount)) {} catch {}
    }

    function burnClaims2(uint256 amount) external {
        if (totalMintedClaims2 == 0) return;
        // Same int128 per-call cap as burnClaims (see above).
        uint256 cap = totalMintedClaims2 > uint256(uint128(type(int128).max))
            ? uint256(uint128(type(int128).max))
            : totalMintedClaims2;
        amount = bound(amount, 1, cap);
        vault.unlock(abi.encode(uint8(3), amount));
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
        assertGe(vault.reservesOf(Currency.wrap(address(token))), vault.claimSupplyOf(Currency.wrap(address(token))));
        assertGe(physicalBalance, vault.reservesOf(Currency.wrap(address(token))));
    }

    /// @notice T-1: the claims <= reserves bound holds for the SUM over every
    /// currency, so claims in one currency cannot be backed by reserves of
    /// another. (Per-currency bounds are asserted in invariant_vaultSolvency.)
    function invariant_claimsSupplySumWithinReservesSum() public view {
        Currency c0 = Currency.wrap(address(token));
        Currency c1 = handler.currency2();
        uint256 claimsSum = vault.claimSupplyOf(c0) + vault.claimSupplyOf(c1);
        uint256 reservesSum = vault.reservesOf(c0) + vault.reservesOf(c1);
        uint256 physicalSum = token.balanceOf(address(vault)) + handler.token2().balanceOf(address(vault));
        assertLe(claimsSum, reservesSum, "sum of claims exceeds sum of reserves");
        assertLe(reservesSum, physicalSum, "sum of reserves exceeds physical balance");
        assertEq(vault.claimSupplyOf(c0), handler.totalMintedClaims(), "ghost claim supply drifted (currency 0)");
        assertEq(vault.claimSupplyOf(c1), handler.totalMintedClaims2(), "ghost claim supply drifted (currency 1)");
    }
}
