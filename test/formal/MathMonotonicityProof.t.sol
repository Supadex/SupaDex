// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";

/// @title MathMonotonicityFormalProof
/// @notice Halmos / Forge-Symbolic formal proof verifying arithmetic monotonicity and rounding upper bounds.
contract MathMonotonicityFormalProof is Test {
    /// @notice Proves theorem: mulDivRoundingUp(a, b, denominator) >= mulDiv(a, b, denominator)
    function check_mulDivRoundingUpAlwaysGreaterOrEqual(uint128 a, uint128 b, uint128 denominator) external pure {
        if (denominator == 0) return;

        uint256 floorResult = FullMathLib.mulDiv(uint256(a), uint256(b), uint256(denominator));
        uint256 ceilResult = FullMathLib.mulDivRoundingUp(uint256(a), uint256(b), uint256(denominator));

        assert(ceilResult >= floorResult);
        assert(ceilResult - floorResult <= 1);
    }

    /// @notice Proves theorem: SafeCast.toUint128 is strictly identity for any value in [0, 2^128 - 1]
    function check_safeCastIdentityInRange(uint128 x) external pure {
        uint256 extended = uint256(x);
        uint128 castBack = SafeCastLib.toUint128(extended);
        assert(castBack == x);
    }
}
