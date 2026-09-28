// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";

contract Slot0Test is Test {
    using Slot0Library for Slot0;

    function test_packAndUnpackSlot0() public pure {
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price
        int24 tick = 0;
        uint24 protocolFee = 100;
        uint24 dynamicFee = 3000;
        bool initialized = true;

        Slot0 slot0 = Slot0Library.pack(sqrtPriceX96, tick, protocolFee, dynamicFee, initialized);

        assertEq(slot0.sqrtPriceX96(), sqrtPriceX96);
        assertEq(slot0.tick(), tick);
        assertEq(slot0.protocolFee(), protocolFee);
        assertEq(slot0.dynamicFee(), dynamicFee);
        assertTrue(slot0.isInitialized());
    }

    function test_setters() public pure {
        Slot0 slot0 = Slot0Library.pack(100, 10, 50, 2000, true);

        slot0 = slot0.setSqrtPriceX96(500);
        assertEq(slot0.sqrtPriceX96(), 500);

        slot0 = slot0.setTick(-100);
        assertEq(slot0.tick(), -100);

        slot0 = slot0.setProtocolFee(200);
        assertEq(slot0.protocolFee(), 200);

        slot0 = slot0.setDynamicFee(5000);
        assertEq(slot0.dynamicFee(), 5000);
    }
}
