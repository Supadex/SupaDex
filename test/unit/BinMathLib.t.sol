// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BinMathLib} from "../../contract/libraries/BinMathLib.sol";

contract BinMathLibTest is Test {
    function test_centerBinPriceIsOne() public pure {
        uint24 centerBinId = 8388608;
        uint16 binStep = 10; // 10 bps
        uint256 price = BinMathLib.getPriceFromId(centerBinId, binStep);
        // At center bin, price equals 1 << 128
        assertEq(price, 1 << 128);
    }

    function test_swapAmountInBin() public pure {
        uint256 binPrice = 1 << 128; // 1:1 price
        uint256 amountIn = 1000 ether;

        uint256 amountOutZeroForOne = BinMathLib.getSwapAmountInBin(amountIn, binPrice, true);
        assertEq(amountOutZeroForOne, 1000 ether);

        uint256 amountOutOneForZero = BinMathLib.getSwapAmountInBin(amountIn, binPrice, false);
        assertEq(amountOutOneForZero, 1000 ether);
    }
}
