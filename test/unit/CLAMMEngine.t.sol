// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";

contract CLAMMEngineTest is Test {
    CLAMMEngine public engine;
    PoolKey public key;
    PoolId public poolId;

    function setUp() public {
        engine = new CLAMMEngine();
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        poolId = key.toId();
    }

    function test_clammInitialize() public {
        uint160 initialSqrtPriceX96 = 1 << 96; // Price = 1.0 (Tick = 0)
        int24 tick = engine.initialize(key, initialSqrtPriceX96);
        assertEq(tick, 0);
    }

    function test_clammModifyLiquidityAndSwap() public {
        uint160 initialSqrtPriceX96 = 1 << 96; // Price = 1.0
        engine.initialize(key, initialSqrtPriceX96);

        // Add liquidity around tick 0: [-120, 120]
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: 1_000_000, salt: bytes32(0)
        });

        (BalanceDelta delta,) = engine.modifyLiquidity(key, params);
        assertTrue(delta.amount0() > 0);
        assertTrue(delta.amount1() > 0);

        // Execute Swap: exactInput zeroForOne
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: 1000, sqrtPriceLimitX96: TickMathLib.MIN_SQRT_RATIO + 1
        });

        (BalanceDelta swapDelta,) = engine.swap(key, swapParams, key.fee, 0);
        assertEq(swapDelta.amount0(), 1000);
        assertTrue(swapDelta.amount1() < 0);
    }
}
