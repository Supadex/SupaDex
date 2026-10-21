// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";

/// @dev Exposes StableAMM `_spotSqrtPriceX96` for M4 regression coverage.
contract StableSqrtHarness is StableAMMEngine {
    constructor(address pm) StableAMMEngine(pm) {}

    function spot(uint256 r0, uint256 r1) external pure returns (uint160) {
        return _spotSqrtPriceX96(r0, r1);
    }
}

contract MockDecToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

contract StableAMMEngineTest is Test {
    StableAMMEngine public engine;
    PoolKey public key;

    function setUp() public {
        engine = new StableAMMEngine(address(this));
        address a = address(new MockDecToken(18));
        address b = address(new MockDecToken(18));
        (a, b) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
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

        (BalanceDelta delta,) = engine.modifyLiquidity(key, params, address(this));
        assertEq(delta.amount0(), int128(int256(1_000_000 ether)));
        assertEq(delta.amount1(), int128(int256(1_000_000 ether)));

        // Swap 10,000 token0 for token1
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10_000 ether, sqrtPriceLimitX96: 0});

        (BalanceDelta swapDelta,) = engine.swap(key, swapParams, key.fee, 0);
        assertEq(swapDelta.amount0(), 10_000 ether);
        // Pegged curve with fee should yield close to 10_000 * (1 - 0.0004) = ~9,996
        assertTrue(-swapDelta.amount1() > 9_900 ether);
    }

    /// M4: spot sqrt price is always inside TickMath bounds (clamped, never truncated).
    function test_M4_spotSqrtPriceClampedInBounds() public {
        StableSqrtHarness h = new StableSqrtHarness(address(this));
        uint160 lo = h.spot(type(uint128).max, 1);
        uint160 hi = h.spot(1, type(uint128).max);
        assertTrue(lo > TickMathLib.MIN_SQRT_RATIO && lo < TickMathLib.MAX_SQRT_RATIO);
        assertTrue(hi > TickMathLib.MIN_SQRT_RATIO && hi < TickMathLib.MAX_SQRT_RATIO);
        assertEq(h.spot(1e18, 1e18), uint160(1 << 96));
    }

    /// Equal decimals are required (ADR-0001 assumption; decimal scaling is SDX-013).
    function test_initializeRevertsOnDecimalsMismatch() public {
        address a = address(new MockDecToken(6));
        address b = address(new MockDecToken(18));
        (a, b) = a < b ? (a, b) : (b, a);
        PoolKey memory k = key;
        k.currency0 = Currency.wrap(a);
        k.currency1 = Currency.wrap(b);
        vm.expectRevert();
        engine.initialize(k, 1 << 96);
    }
}
