// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VolatilityTWAPOracle} from "../../contract/plugins/native/VolatilityTWAPOracle.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";

contract VolatilityTWAPOracleTest is Test {
    VolatilityTWAPOracle internal oracle;
    PoolId internal poolId;

    function setUp() public {
        oracle = new VolatilityTWAPOracle();
        poolId = PoolId.wrap(keccak256("TEST_POOL"));
    }

    function test_initializeOracle() public {
        (uint16 index, uint16 cardinality) = oracle.initialize(poolId, 1000, 50);
        assertEq(index, 0);
        assertEq(cardinality, 1);

        (uint16 curIndex, uint16 curCard, uint16 curNext) = oracle.states(poolId);
        assertEq(curIndex, 0);
        assertEq(curCard, 1);
        assertEq(curNext, 1);
    }

    function test_cannotDoubleInitialize() public {
        oracle.initialize(poolId, 1000, 50);
        vm.expectRevert(PluginErrors.InvalidCardinality.selector);
        oracle.initialize(poolId, 1000, 50);
    }

    function test_growAndWriteObservations() public {
        oracle.initialize(poolId, 1000, 100);
        oracle.grow(poolId, 5);

        // Advance block timestamp
        vm.warp(1012);
        (uint16 index1, uint16 card1) = oracle.write(poolId, 1012, 120, 1_000_000);
        assertEq(index1, 1);
        assertEq(card1, 2);

        vm.warp(1024);
        (uint16 index2, uint16 card2) = oracle.write(poolId, 1024, 150, 1_000_000);
        assertEq(index2, 2);
        assertEq(card2, 3);
    }

    function test_observeHistoricalTicks() public {
        oracle.initialize(poolId, 1000, 100);
        oracle.grow(poolId, 10);

        vm.warp(1010);
        oracle.write(poolId, 1010, 100, 1_000_000);

        vm.warp(1020);
        oracle.write(poolId, 1020, 100, 1_000_000);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 20; // 1000
        secondsAgos[1] = 0; // 1020

        (int56[] memory tickCumulatives, ) = oracle.observe(poolId, secondsAgos);
        assertEq(tickCumulatives.length, 2);
        // delta tick cumulative across 20s at tick 100 should be 20 * 100 = 2000
        assertEq(tickCumulatives[1] - tickCumulatives[0], 2000);
    }

    function test_getInstantaneousVolatility() public {
        oracle.initialize(poolId, 1000, 100);
        oracle.grow(poolId, 5);

        vm.warp(1012);
        oracle.write(poolId, 1012, 150, 1_000_000);

        // Volatility over 12s with tick jump from 100 to 150
        uint256 vol = oracle.getInstantaneousVolatility(poolId, 12);
        assertTrue(vol > 0);
    }
}
