// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract StableAMMEngineTest is Test {
    StableAMMEngine public engine;
    PoolKey public key;

    function setUp() public {
        engine = new StableAMMEngine();
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 400, // 0.04% stable fee
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        });
    }

    function test_stableAMMLifecycle() public {
        engine.initialize(key, 1 << 96);

        // Add 1,000,000 to each reserve
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: 0, tickUpper: 0, liquidityDelta: 1_000_000 ether, salt: bytes32(0)
        });

        (BalanceDelta delta,) = engine.modifyLiquidity(key, params);
        assertEq(delta.amount0(), int128(int256(1_000_000 ether)));
        assertEq(delta.amount1(), int128(int256(1_000_000 ether)));

        // Swap 10,000 token0 for token1
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10_000 ether, sqrtPriceLimitX96: 0});

        BalanceDelta swapDelta = engine.swap(key, swapParams, key.fee);
        assertEq(swapDelta.amount0(), 10_000 ether);
        // Pegged curve with fee should yield close to 10_000 * (1 - 0.0004) = ~9,996
        assertTrue(-swapDelta.amount1() > 9_900 ether);
    }
}
