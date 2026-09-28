// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {BinMathLib} from "../../contract/libraries/BinMathLib.sol";

contract BinAMMEngineTest is Test {
    BinAMMEngine public engine;
    PoolKey public key;

    function setUp() public {
        engine = new BinAMMEngine();
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 10,
            plugin: address(0),
            curveType: CurveType.BIN_AMM
        });
    }

    function test_binAMMLifecycle() public {
        engine.initialize(key, 1 << 96);

        // Add liquidity to center bin
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: int24(uint24(BinMathLib.CENTER_BIN_ID)),
            tickUpper: 0,
            liquidityDelta: 100_000 ether,
            salt: bytes32(0)
        });

        (BalanceDelta delta,) = engine.modifyLiquidity(key, params);
        assertEq(delta.amount0(), int128(int256(100_000 ether)));
        assertEq(delta.amount1(), int128(int256(100_000 ether)));

        // Swap
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1000 ether, sqrtPriceLimitX96: 0});

        BalanceDelta swapDelta = engine.swap(key, swapParams, key.fee);
        assertEq(swapDelta.amount0(), 1000 ether);
        assertTrue(swapDelta.amount1() < 0);
    }
}
