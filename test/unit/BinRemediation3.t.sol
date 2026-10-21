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
import {FullMathLib} from "../../contract/libraries/FullMathLib.sol";
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";

/// @notice Edith remediation-3 condition 4: BIN gas for many non-empty bins (documented, not capped), composition
///         invariant (above active: token0 only, below active: token1 only) under random adds and swaps, and
///         rounding of the half/half seed of an empty active bin.
contract BinRemediation3Test is Test {
    uint256 constant SCALE = 1 << 128;
    BinAMMEngine engine;
    PoolKey key;
    PoolId pid;

    function setUp() public {
        engine = new BinAMMEngine(address(this));
    }

    function _key(int24 step) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: step,
            plugin: address(0),
            curveType: CurveType.BIN_AMM
        });
    }

    function _init(int24 step, int24 targetId) internal returns (int24 active) {
        key = _key(step);
        pid = key.toId();
        uint256 p = engine.getPriceFromId(targetId, uint16(uint24(step)));
        engine.initialize(key, uint160(BinMathLib.priceX128ToSqrtPriceX96(p)), "");
        active = engine.getActiveBinId(pid);
    }

    function _add(int24 lo, int24 hi, uint128 shares, bytes32 salt) internal returns (BalanceDelta d) {
        (d,) = engine.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(shares)), salt: salt
            }),
            address(this)
        );
    }

    function _swap(bool zeroForOne, int256 amount) internal returns (BalanceDelta d) {
        (d,) = engine.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: 0}),
            key.fee,
            0
        );
    }

    function extAdd(int24 lo, int24 hi, uint128 shares) external returns (BalanceDelta) {
        return _add(lo, hi, shares, 0);
    }

    // ------------------------------------------------------------------ gas (documented; no per-swap bin cap)

    function _gasCrossing(uint256 nBins) internal returns (uint256 gasUsed) {
        _init(10, 0);
        // nBins one-share dust bins below the active bin (token1 only), added 64 at a time.
        int24 top = -1;
        int24 bottom = -int24(int256(nBins));
        for (int24 hi = top; hi >= bottom; hi -= 64) {
            int24 lo = hi - 63 < bottom ? bottom : hi - 63;
            _add(lo, hi, 1, bytes32(uint256(uint24(-hi))));
        }
        uint256 g0 = gasleft();
        _swap(true, 1e18);
        gasUsed = g0 - gasleft();
        assertLe(engine.getActiveBinId(pid), bottom, "swap crossed every dust bin");
    }

    function test_gas_64_nonEmptyBins() public {
        uint256 g = _gasCrossing(64);
        emit log_named_uint("BIN swap crossing 64 non-empty bins, gas", g);
        emit log_named_uint("  per bin", g / 64);
        assertLt(g, 4_000_000);
    }

    function test_gas_256_nonEmptyBins() public {
        uint256 g = _gasCrossing(256);
        emit log_named_uint("BIN swap crossing 256 non-empty bins, gas", g);
        emit log_named_uint("  per bin", g / 256);
        assertLt(g, 14_000_000);
    }

    function test_gas_640_nonEmptyBins() public {
        uint256 g = _gasCrossing(640);
        emit log_named_uint("BIN swap crossing 640 non-empty bins, gas", g);
        emit log_named_uint("  per bin", g / 640);
        // Edith measured 24.18M (via-IR). Linear in non-empty bins crossed, like v3 initialized ticks. The swapper pays
        // it, and sqrtPriceLimitX96 / amount bound it. Not a block-stuffing vector against other users.
        assertLt(g, 30_000_000, "below a 30M block gas limit at 640 bins");
    }

    // ------------------------------------------------------------------ composition invariant

    function _checkComposition(int24 lo, int24 hi) internal view {
        int24 a = engine.getActiveBinId(pid);
        for (int24 b = lo; b <= hi; b++) {
            (uint128 r0, uint128 r1) = engine.getBinReserves(pid, b);
            if (b > a) assertEq(r1, 0, "above active: no token1");
            if (b < a) assertEq(r0, 0, "below active: no token0");
        }
    }

    function testFuzz_compositionAfterAddsAndSwaps(
        uint8 stepSeed,
        int16 targetSeed,
        uint64[4] memory shares,
        int8[4] memory offs,
        uint96 swapAmt,
        bool dir
    ) public {
        int24 step = int24(uint24(bound(stepSeed, 1, 200)));
        int24 a0 = _init(step, int24(bound(int256(targetSeed), -2000, 2000)));
        int24 lo = a0 - 80;
        int24 hi = a0 + 80;
        for (uint256 i; i < 4; i++) {
            uint128 sh = uint128(bound(shares[i], 2, 1e24));
            int24 c = a0 + int24(bound(int256(offs[i]), -40, 40));
            _add(c - 20, c + 20, sh, bytes32(i));
        }
        _checkComposition(lo, hi);
        _swap(dir, int256(bound(swapAmt, 1, 1e24)));
        _checkComposition(lo, hi);
        _swap(!dir, int256(bound(uint256(swapAmt) / 3 + 1, 1, 1e24)));
        _checkComposition(lo, hi);
        // A later add at the (moved) active bin keeps the invariant too.
        int24 a1 = engine.getActiveBinId(pid);
        _add(a1 - 3, a1 + 3, 1e6, bytes32(uint256(99)));
        _checkComposition(lo, hi);
    }

    // ------------------------------------------------------------------ seed rounding (empty bins)

    /// @dev Value of a deposit in token1 units at the bin price: amount1 + amount0 * price.
    function _value(uint256 a0, uint256 a1, uint256 price) internal pure returns (uint256) {
        return a1 + FullMathLib.mulDiv(a0, price, SCALE);
    }

    function testFuzz_seedRounding_neverUnderpays(uint8 stepSeed, int16 targetSeed, uint128 shares, int8 off) public {
        int24 step = int24(uint24(bound(stepSeed, 1, 200)));
        int24 a = _init(step, int24(bound(int256(targetSeed), -2000, 2000)));
        shares = uint128(bound(shares, 1, 1e30));
        int24 b = a + int24(bound(int256(off), -3, 3));
        uint256 price = engine.getPriceFromId(b, uint16(uint24(step)));
        (uint256 q0, uint256 q1) = engine.quoteAddLiquidity(pid, b, b, shares);
        if (q0 > uint256(uint128(type(int128).max)) || q1 > uint256(uint128(type(int128).max))) {
            // Reserves are uint128 and deltas int128: an unrepresentable seed is refused with a named error.
            vm.expectRevert(SafeCastLib.SafeCastOverflow.selector);
            this.extAdd(b, b, shares);
            return;
        }
        BalanceDelta d = _add(b, b, shares, 0);
        assertEq(uint256(int256(d.amount0())), q0, "quote == charge");
        assertEq(uint256(int256(d.amount1())), q1);
        uint256 v = _value(q0, q1, price);
        // Shares are denominated in token1 value. A seeding LP never pays less than `shares` of value (rounded up)...
        assertGe(v + 1, shares, "seed charges at least the share value (1 wei mulDiv floor in the check)");
        // ...and overpays by at most one token0 wei of value (+1 for rounding of this check).
        assertLe(v, uint256(shares) + FullMathLib.mulDivRoundingUp(1, price, SCALE) + 1, "rounding bounded");
        if (b == a) {
            // half/half: token1 part is ceil(shares/2); token0 part is ceil(floor(shares/2) / price)
            assertEq(q1, uint256(shares) - uint256(shares) / 2);
            assertEq(q0, FullMathLib.mulDivRoundingUp(uint256(shares) / 2, SCALE, price));
        } else if (b > a) {
            assertEq(q1, 0);
        } else {
            assertEq(q0, 0);
            assertEq(q1, shares);
        }
        // Immediate exit returns no more than was paid (rounding against the LP).
        (BalanceDelta r,) = engine.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: b, tickUpper: b, liquidityDelta: -int256(uint256(shares)), salt: 0
            }),
            address(this)
        );
        assertLe(uint256(int256(-r.amount0())), q0);
        assertLe(uint256(int256(-r.amount1())), q1);
    }

    function test_seedRounding_oneShareActiveBin() public {
        int24 a = _init(25, 0);
        BalanceDelta d = _add(a, a, 1, 0);
        // half = 0 -> token0 part 0, token1 part 1: a 1-share seed of the active bin costs exactly 1 wei token1.
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 1);
    }
}
