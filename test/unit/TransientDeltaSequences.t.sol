// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";

contract SeqToken {
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

/// @dev Executes an arbitrary sequence of vault operations inside ONE unlock.
/// Op kinds (mod 5): 0 = mint to self, 1 = mint to a second recipient,
/// 2 = burn own claims, 3 = take, 4 = settle (funds the vault first).
/// Any single op may revert (zero amount, int128 bound, insufficient balance /
/// reserves); a revert aborts the whole unlock, which is an acceptable outcome
/// for the property under test ("always reverts OR stays solvent").
contract DeltaSequenceActor is IUnlockCallback {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SeqToken public token;
    Currency public currency;
    address public constant OTHER = address(0x1);

    constructor(SupaVault _vault, SeqToken _token) {
        vault = _vault;
        token = _token;
        currency = Currency.wrap(address(_token));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8[] memory kinds, uint256[] memory amounts) = abi.decode(data, (uint8[], uint256[]));
        require(kinds.length == amounts.length, "len");
        for (uint256 i; i < kinds.length; i++) {
            uint8 kind = kinds[i] % 5;
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            if (kind == 0) {
                vault.mint(currency, address(this), amount);
            } else if (kind == 1) {
                vault.mint(currency, OTHER, amount);
            } else if (kind == 2) {
                vault.burn(currency, amount);
            } else if (kind == 3) {
                vault.take(currency, address(this), amount);
            } else {
                vault.sync(currency);
                token.mint(address(this), amount);
                token.transfer(address(vault), amount);
                vault.settle(currency);
            }
        }
        return "";
    }

    function run(uint8[] memory kinds, uint256[] memory amounts) external {
        vault.unlock(abi.encode(kinds, amounts));
    }
}

/// @title T-1: delta arithmetic over SEQUENCES of mint/burn/take/settle
/// @notice C-01's wrap needed several large mints in one unlock. Single-delta
/// tests cannot catch it: only a sequence can drive the running transient delta
/// through zero (or past an int128 bound) while leaving claims outstanding.
/// Property: every sequence either reverts the unlock or leaves the vault
/// solvent — zero transient delta, lock released, claims <= reserves <=
/// physical balance.
contract TransientDeltaSequencesTest is Test {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SeqToken public token;
    DeltaSequenceActor public actor;
    Currency public currency;

    function setUp() public {
        vault = new SupaVault(address(this));
        token = new SeqToken();
        actor = new DeltaSequenceActor(vault, token);
        currency = Currency.wrap(address(token));
    }

    function _assertSolvent() internal view {
        assertEq(vault.getCurrencyDelta(address(actor), currency), 0, "delta not settled");
        assertFalse(vault.isUnlocked(), "lock not released");
        assertLe(vault.claimSupplyOf(currency), vault.reservesOf(currency), "claims exceed reserves");
        assertLe(vault.reservesOf(currency), token.balanceOf(address(vault)), "reserves exceed balance");
        assertGe(
            token.balanceOf(address(vault)),
            vault.claimSupplyOf(currency),
            "physical balance below outstanding claims"
        );
    }

    function _run(uint8[] memory kinds, uint256[] memory amounts) internal returns (bool reverted) {
        try actor.run(kinds, amounts) {} catch {
            reverted = true;
        }
    }

    /// @notice Fuzz over 8-op sequences with full-range uint128 amounts. One in
    /// four amounts is biased into a small range so the fuzzer also explores
    /// multi-step SUCCESSFUL sequences; the rest stay full-range (including
    /// near-int128.max magnitudes that must revert or stay backed).
    function testFuzz_sequenceAlwaysRevertsOrStaysSolvent(uint8[8] memory rawKinds, uint128[8] memory rawAmounts)
        public
    {
        uint8[] memory kinds = new uint8[](8);
        uint256[] memory amounts = new uint256[](8);
        for (uint256 i; i < 8; i++) {
            kinds[i] = rawKinds[i];
            uint256 a = uint256(rawAmounts[i]);
            amounts[i] = (a % 4 == 0) ? (a % 1_000_000 + 1) : a;
        }
        bool reverted = _run(kinds, amounts);
        if (!reverted) _assertSolvent();
    }

    /// @notice The C-01 wrap shape, post-fix: three extreme mints with no
    /// backing settle. Must revert (checked delta arithmetic / unsettled delta /
    /// claims-exceed-reserves) and leave zero claims outstanding.
    function test_wrapTripleStillReverts() public {
        uint8[] memory kinds = new uint8[](3);
        uint256[] memory amounts = new uint256[](3);
        kinds[0] = 0;
        kinds[1] = 0;
        kinds[2] = 0;
        amounts[0] = uint256(uint128(type(int128).max));
        amounts[1] = uint256(uint128(type(int128).max));
        amounts[2] = 2;
        vm.expectRevert();
        actor.run(kinds, amounts);
        assertEq(vault.claimSupplyOf(currency), 0, "unbacked claims survived a reverted unlock");
        assertEq(vault.reservesOf(currency), 0);
    }

    /// @notice A single mint above the int128 per-call bound reverts.
    function test_singleMintAboveInt128Reverts() public {
        uint8[] memory kinds = new uint8[](1);
        uint256[] memory amounts = new uint256[](1);
        kinds[0] = 0;
        amounts[0] = uint256(uint128(type(int128).max)) + 1;
        vm.expectRevert(SafeCastLib.SafeCastOverflow.selector);
        actor.run(kinds, amounts);
    }

    /// @notice A fully-backed settle -> mint -> burn -> take round trip at the
    /// int128 maximum succeeds and leaves the vault exactly empty.
    function test_int128MaxBackedRoundTrip() public {
        uint256 max = uint256(uint128(type(int128).max));
        uint8[] memory kinds = new uint8[](4);
        uint256[] memory amounts = new uint256[](4);
        kinds[0] = 4; // settle
        kinds[1] = 0; // mint to self
        kinds[2] = 2; // burn
        kinds[3] = 3; // take
        amounts[0] = max;
        amounts[1] = max;
        amounts[2] = max;
        amounts[3] = max;
        actor.run(kinds, amounts);
        assertEq(vault.claimSupplyOf(currency), 0);
        assertEq(vault.reservesOf(currency), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        _assertSolvent();
    }

    /// @notice A balanced mixed sequence succeeds and leaves claims == reserves.
    function test_backedMixedSequenceStaysSolvent() public {
        // settle 1e18, mint 1e18 to self, burn 5e17, take 5e17.
        uint8[] memory kinds = new uint8[](4);
        uint256[] memory amounts = new uint256[](4);
        kinds[0] = 4;
        kinds[1] = 0;
        kinds[2] = 2;
        kinds[3] = 3;
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;
        amounts[2] = 0.5 ether;
        amounts[3] = 0.5 ether;
        actor.run(kinds, amounts);
        _assertSolvent();
        assertEq(vault.claimSupplyOf(currency), 0.5 ether);
        assertEq(vault.reservesOf(currency), 0.5 ether);
        assertEq(vault.balanceOf(address(actor), currency.toId()), 0.5 ether);
    }

    /// @notice Minting beyond reserves with the delta zeroed by a burn of other
    /// claims still fails the end-of-unlock backing check.
    function test_mintBeyondReservesReverts() public {
        // settle 100, mint 100 to self (claims == reserves), then mint 1 more:
        // delta is -1, so unlock reverts on the unsettled delta.
        uint8[] memory kinds = new uint8[](3);
        uint256[] memory amounts = new uint256[](3);
        kinds[0] = 4;
        kinds[1] = 0;
        kinds[2] = 0;
        amounts[0] = 100;
        amounts[1] = 100;
        amounts[2] = 1;
        vm.expectRevert();
        actor.run(kinds, amounts);
        assertEq(vault.claimSupplyOf(currency), 0);
    }
}
