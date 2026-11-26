// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";

contract Mintable {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Runs the C-01 sequences inside an unlock. `unlock` callbacks the caller, so every entry
/// point below calls `vault.unlock` itself.
contract DeltaAttacker is IUnlockCallback {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    Mintable public token;
    Currency public currency;

    constructor(SupaVault _vault, Mintable _token) {
        vault = _vault;
        token = _token;
        currency = Currency.wrap(address(_token));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        uint8 mode = abi.decode(data[:32], (uint8));
        if (mode == 0) {
            // Pre-fix wrap: three mints whose magnitudes sum to 2^256.
            // Unchecked int256 add stored a delta of 0 and left the claims outstanding.
            vault.mint(currency, address(0x1), uint256(type(int256).max));
            vault.mint(currency, address(0x2), uint256(type(int256).max));
            vault.mint(currency, address(0x3), 2);
        } else if (mode == 2) {
            (, uint256 amount) = abi.decode(data, (uint8, uint256));
            vault.sync(currency);
            token.mint(address(this), amount);
            token.transfer(address(vault), amount);
            vault.settle(currency);
            vault.mint(currency, address(this), amount);
        } else if (mode == 3) {
            (, uint256 a, uint256 b, uint256 c) = abi.decode(data, (uint8, uint256, uint256, uint256));
            if (a > 0) vault.mint(currency, address(0x1), a);
            if (b > 0) vault.mint(currency, address(0x2), b);
            if (c > 0) vault.mint(currency, address(0x3), c);
        }
        return "";
    }

    function wrapAttempt() external {
        vault.unlock(abi.encode(uint8(0)));
    }

    function backedMint(uint256 amount) external {
        vault.unlock(abi.encode(uint8(2), amount));
    }

    function unbacked(uint256 a, uint256 b, uint256 c) external {
        vault.unlock(abi.encode(uint8(3), a, b, c));
    }
}

contract VaultDeltaOverflowTest is Test {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    Mintable public token;
    DeltaAttacker public attacker;
    Currency public currency;

    function setUp() public {
        vault = new SupaVault(address(this));
        token = new Mintable();
        attacker = new DeltaAttacker(vault, token);
        currency = Currency.wrap(address(token));
    }

    function test_wrapSequenceReverts() public {
        vm.expectRevert(SafeCastLib.SafeCastOverflow.selector);
        attacker.wrapAttempt();
        assertEq(vault.claimSupplyOf(currency), 0);
        assertEq(vault.reservesOf(currency), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_int128MaxMintIsBacked() public {
        uint256 amount = uint256(uint128(type(int128).max));
        attacker.backedMint(amount);
        assertEq(vault.claimSupplyOf(currency), amount);
        assertEq(vault.reservesOf(currency), amount);
        assertEq(vault.balanceOf(address(attacker), currency.toId()), amount);
        assertLe(vault.claimSupplyOf(currency), vault.reservesOf(currency));
    }

    function test_amountAboveInt128Reverts() public {
        vm.expectRevert(SafeCastLib.SafeCastOverflow.selector);
        attacker.backedMint(uint256(uint128(type(int128).max)) + 1);
    }

    function testFuzz_unbackedMintSequenceReverts(uint128 a, uint128 b, uint128 c) public {
        uint256 x = bound(uint256(a), 1, uint256(uint128(type(int128).max)));
        uint256 y = bound(uint256(b), 0, uint256(uint128(type(int128).max)));
        uint256 z = bound(uint256(c), 0, uint256(uint128(type(int128).max)));
        vm.expectRevert();
        attacker.unbacked(x, y, z);
        assertEq(vault.claimSupplyOf(currency), 0);
    }

    function testFuzz_backedMintStaysSolvent(uint128 raw) public {
        uint256 amount = bound(uint256(raw), 1, uint256(uint128(type(int128).max)));
        attacker.backedMint(amount);
        assertLe(vault.claimSupplyOf(currency), vault.reservesOf(currency));
        assertLe(vault.reservesOf(currency), token.balanceOf(address(vault)));
        assertEq(vault.balanceOf(address(attacker), currency.toId()), amount);
    }
}
