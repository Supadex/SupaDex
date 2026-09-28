// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PathKeyLib} from "../../contract/periphery/libraries/PathKeyLib.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PeripheryErrors} from "../../contract/errors/PeripheryErrors.sol";

contract PathKeyLibTest is Test {
    using PathKeyLib for bytes;

    Currency tokenA = Currency.wrap(address(0x1000));
    Currency tokenB = Currency.wrap(address(0x2000));
    Currency tokenC = Currency.wrap(address(0x3000));

    function externalDecodeFirstPool(bytes memory path) external pure {
        path.decodeFirstPool();
    }

    function externalGetFirstPoolKey(bytes memory path) external pure {
        path.getFirstPoolKey();
    }

    function test_encodeAndDecodeSingleHop() public view {
        bytes memory path = PathKeyLib.encodeHop(tokenA, tokenB, 3000, 60, address(0), CurveType.CLAMM);

        assertEq(path.numPools(), 1);
        assertFalse(path.hasMultiplePools());

        (Currency cIn, Currency cOut, uint24 fee, int24 tickSpacing, address plugin, CurveType curve) =
            path.decodeFirstPool();

        assertEq(Currency.unwrap(cIn), Currency.unwrap(tokenA));
        assertEq(Currency.unwrap(cOut), Currency.unwrap(tokenB));
        assertEq(fee, 3000);
        assertEq(tickSpacing, 60);
        assertEq(plugin, address(0));
        assertTrue(curve == CurveType.CLAMM);

        (PoolKey memory poolKey, Currency inCur, Currency outCur, bool zeroForOne) = path.getFirstPoolKey();
        assertEq(Currency.unwrap(poolKey.currency0), Currency.unwrap(tokenA));
        assertEq(Currency.unwrap(poolKey.currency1), Currency.unwrap(tokenB));
        assertEq(Currency.unwrap(inCur), Currency.unwrap(tokenA));
        assertEq(Currency.unwrap(outCur), Currency.unwrap(tokenB));
        assertTrue(zeroForOne);
    }

    function test_encodeAndDecodeMultiHop() public view {
        bytes memory hop1 = PathKeyLib.encodeHop(tokenA, tokenB, 3000, 60, address(0), CurveType.CLAMM);

        bytes memory multiPath = abi.encodePacked(
            hop1, abi.encodePacked(uint24(500), int24(10), address(0x999), uint8(CurveType.BIN_AMM), tokenC)
        );

        assertEq(multiPath.numPools(), 2);
        assertTrue(multiPath.hasMultiplePools());

        (PoolKey memory key1,,,) = multiPath.getFirstPoolKey();
        assertEq(key1.fee, 3000);

        bytes memory remaining = multiPath.skipToken();
        assertEq(remaining.numPools(), 1);
        assertFalse(remaining.hasMultiplePools());

        (PoolKey memory key2,,,) = remaining.getFirstPoolKey();
        assertEq(key2.fee, 500);
        assertEq(key2.plugin, address(0x999));
        assertTrue(key2.curveType == CurveType.BIN_AMM);
    }

    function test_invalidPathReverts() public {
        bytes memory shortPath = hex"1234";
        vm.expectRevert(PeripheryErrors.InvalidPath.selector);
        this.externalDecodeFirstPool(shortPath);
    }

    function test_identicalCurrenciesReverts() public {
        bytes memory path = PathKeyLib.encodeHop(tokenA, tokenA, 3000, 60, address(0), CurveType.CLAMM);

        vm.expectRevert(PeripheryErrors.IdenticalCurrencies.selector);
        this.externalGetFirstPoolKey(path);
    }
}
