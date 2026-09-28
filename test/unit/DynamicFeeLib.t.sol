// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DynamicFeeLib} from "../../contract/libraries/DynamicFeeLib.sol";

contract DynamicFeeLibTest is Test {
    function test_baseFeeNoVolatility() public pure {
        uint24 baseFee = 3000; // 0.30%
        uint24 updatedFee = DynamicFeeLib.computeDynamicFee(baseFee, baseFee, 0, 100, 12);
        assertEq(updatedFee, baseFee);
    }

    function test_volatilitySpike() public pure {
        uint24 baseFee = 3000;
        // 100 ticks movement
        uint24 updatedFee = DynamicFeeLib.computeDynamicFee(baseFee, baseFee, 100, 0, 12);
        // Base + 100 * 50 = 3000 + 5000 = 8000 (0.80%)
        assertEq(updatedFee, 8000);
    }

    function test_feeDecayOverTime() public pure {
        uint24 baseFee = 3000;
        uint24 lastFee = 7000; // was elevated
        // After 12 seconds (1 half-life), excess of 4000 decays by half to 2000 => 5000
        uint24 updatedFee = DynamicFeeLib.computeDynamicFee(baseFee, lastFee, 0, 12, 12);
        assertEq(updatedFee, 5000);

        // After 24 seconds (2 half-lives), excess of 4000 decays to 1000 => 4000
        updatedFee = DynamicFeeLib.computeDynamicFee(baseFee, lastFee, 0, 24, 12);
        assertEq(updatedFee, 4000);
    }
}
