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
        // At price = 1, amount0 == amount1
        assertEq(delta.amount0(), int128(int256(100_000 ether)));
        assertEq(delta.amount1(), int128(int256(100_000 ether)));

        // Swap
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1000 ether, sqrtPriceLimitX96: 0});

        (BalanceDelta swapDelta,) = engine.swap(key, swapParams, key.fee, 0);
        assertEq(swapDelta.amount0(), 1000 ether);
        assertTrue(swapDelta.amount1() < 0);
    }

    /// @dev ETH(18)/USDT(6)-style: ~3000 USDT per ETH → raw price ≈ 3e-9
    function test_binAMMUnequalDecimalsPricing() public {
        // Match frontend priceToSqrtPriceX96(3000, 18, 6):
        // adjusted = 3000 * 10^(6-18) = 3e-9; sqrtPriceX96 = sqrt(adjusted) * 2^96
        uint256 adjustedX18 = 3e9; // 3e-9 * 1e18
        uint256 sqrtAdjustedX9 = sqrt(adjustedX18); // sqrt(3e-9)*1e9
        uint160 sqrtPriceX96 = uint160((sqrtAdjustedX9 << 96) / 1e9);

        engine.initialize(key, sqrtPriceX96);
        uint24 activeId = engine.getActiveBinId(key.toId());
        assertTrue(activeId < BinMathLib.CENTER_BIN_ID, "active bin should be below center for price << 1");

        // Deposit 20 ether of token0 — token1 ≈ 20e18 * 3e-9 = 6e10 (≈ 60000 of 6-dec)
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: int24(uint24(activeId)),
            tickUpper: 0,
            liquidityDelta: 20 ether,
            salt: bytes32(0)
        });
        (BalanceDelta delta,) = engine.modifyLiquidity(key, params);
        assertEq(delta.amount0(), int128(int256(20 ether)));
        uint256 token1Pulled = uint256(int256(delta.amount1()));
        assertTrue(token1Pulled > 1e9, "must pull meaningful token1");
        assertTrue(token1Pulled < 5e11, "token1 should be ~1e10-1e11 scale for 6-dec @ ~3k");

        // Sell 20e6 token1 for token0 — expect ~0.006 ETH out (not dust)
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: int256(20e6), sqrtPriceLimitX96: 0});
        (BalanceDelta swapDelta,) = engine.swap(key, swapParams, key.fee, 0);
        assertTrue(swapDelta.amount0() < 0, "should receive token0");
        uint256 ethOut = uint256(int256(-swapDelta.amount0()));
        assertTrue(ethOut > 1e15, "20 USDT should buy > 0.001 ETH at ~3000");
        assertTrue(ethOut < 5e16, "20 USDT should buy < 0.05 ETH at ~3000");
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
