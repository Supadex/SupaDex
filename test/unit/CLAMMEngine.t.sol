// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";

contract CLAMMEngineTest is Test {
    CLAMMEngine public engine;
    PoolKey public key;
    PoolId public poolId;

    function setUp() public {
        engine = new CLAMMEngine(address(this));
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

        (BalanceDelta delta,) = engine.modifyLiquidity(key, params, address(this));
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

    function test_clammRejectsUnauthorizedCaller() public {
        engine.initialize(key, 1 << 96);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        engine.initialize(key, 1 << 96);
    }

    // ------------------------------------------------------------------ Issue 4: maxLiquidityPerTick
    function _mod(int24 lo, int24 hi, int128 l) internal {
        engine.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: l, salt: 0}),
            address(this)
        );
    }

    /// Matches Uniswap v3's tickSpacingToMaxLiquidityPerTick reference values.
    function test_maxLiquidityPerTick_matchesReference() public view {
        assertEq(engine.maxLiquidityPerTick(1), 191757530477355301479181766273477);
        assertEq(engine.maxLiquidityPerTick(10), 1917569901783203986719870431555990);
        assertEq(engine.maxLiquidityPerTick(60), 11505743598341114571880798222544994);
        assertEq(engine.maxLiquidityPerTick(200), 38350317471085141830651933667504588);
    }

    function test_maxLiquidityPerTick_capEnforcedCumulatively() public {
        engine.initialize(key, 1 << 96);
        uint128 cap = engine.maxLiquidityPerTick(60);
        uint128 half = cap / 2;
        _mod(-120, 120, int128(half));
        _mod(-120, 240, int128(cap - half)); // tick -120 now exactly at the cap: allowed (positive control)
        vm.expectRevert(
            abi.encodeWithSelector(
                PoolErrors.TickLiquidityOverflow.selector, int24(-120), uint256(cap) + 1, uint256(cap)
            )
        );
        _mod(-120, 60, 1);
        // other ticks unaffected; removal at the cap works
        _mod(-60, 60, 1);
        _mod(-120, 120, -int128(half));
        _mod(-120, 60, 1); // room again after removal
    }

    function test_tickNotSpaced() public {
        engine.initialize(key, 1 << 96);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.TickNotSpaced.selector, int24(-61), int24(60)));
        _mod(-61, 120, 1000);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.TickNotSpaced.selector, int24(121), int24(60)));
        _mod(-120, 121, 1000);
    }

    /// Issue 7: crossing a huge empty gap costs O(1) per bitmap level, not O(gap / spacing).
    function test_gas_emptyGapCrossingBounded() public {
        key.tickSpacing = 1;
        engine.initialize(key, 1 << 96);
        _mod(-10, 10, 1e18);
        _mod(-800_000 + 0, -799_000, 1e18); // ~800k empty ticks away (spacing 1)
        uint256 g = gasleft();
        engine.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 1e17, sqrtPriceLimitX96: TickMathLib.MIN_SQRT_RATIO + 1
            }),
            key.fee,
            0
        );
        uint256 used = g - gasleft();
        emit log_named_uint("gas: swap across ~790k empty ticks (spacing 1)", used);
        assertLt(used, 500_000, "gap crossing is bounded");
    }
}
