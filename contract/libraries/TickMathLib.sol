// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolErrors} from "../errors/PoolErrors.sol";

/**
 * @title TickMathLib
 * @notice Computes sqrtPriceX96 for a given tick, and tick for a given sqrtPriceX96.
 */
library TickMathLib {
    /**
     * @dev The minimum tick that may be passed to #getSqrtRatioAtTick.
     */
    int24 internal constant MIN_TICK = -887272;
    /**
     * @dev The maximum tick that may be passed to #getSqrtRatioAtTick.
     */
    int24 internal constant MAX_TICK = 887272;

    /**
     * @dev The minimum value that can be returned from #getSqrtRatioAtTick (4295128739).
     */
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /**
     * @dev The maximum value that can be returned from #getSqrtRatioAtTick.
     */
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /**
     * @notice Calculates sqrt(1.0001^tick) * 2^96.
     */
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK))) revert PoolErrors.TickOutOfBounds(tick);

            uint256 ratio =
                absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e2139) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcb) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941ccf) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926643) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254bf) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52860) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3052) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a3) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e53) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f2) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d8) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e4) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f6) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa5) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x09aa508b5b7a84e1c677de54f3e99bc8) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x005d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x00002216e584f5fa1ea926041bedfe97) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x00000000048a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Round up if division has remainder
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /**
     * @notice Calculates the greatest tick such that getSqrtRatioAtTick(tick) <= sqrtPriceX96.
     */
    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        unchecked {
            if (sqrtPriceX96 < MIN_SQRT_RATIO || sqrtPriceX96 > MAX_SQRT_RATIO) {
                revert PoolErrors.PriceLimitOutOfBounds(sqrtPriceX96);
            }

            uint256 price = uint256(sqrtPriceX96) << 32;

            uint256 r = price;
            uint256 msb = 0;

            assembly {
                let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
                msb := or(msb, f)
                r := shr(f, r)
            }
            assembly {
                let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
                msb := or(msb, f)
                r := shr(f, r)
            }
            assembly {
                let f := shl(5, gt(r, 0xFFFFFFFF))
                msb := or(msb, f)
                r := shr(f, r)
            }
            assembly {
                let f := shl(4, gt(r, 0xFFFF))
                msb := or(msb, f)
                r := shr(f, r)
            }
            assembly {
                let f := shl(3, gt(r, 0xFF))
                msb := or(msb, f)
                r := shr(f, r)
            }
            assembly {
                let f := shl(2, gt(r, 0xF))
                msb := or(msb, f)
                r := shr(f, r)
            }
            assembly {
                let f := shl(1, gt(r, 0x3))
                msb := or(msb, f)
                r := shr(f, r)
            }
            assembly {
                let f := gt(r, 0x1)
                msb := or(msb, f)
            }

            if (msb >= 128) r = price >> (msb - 127);
            else r = price << (127 - msb);

            int256 log_2 = (int256(msb) - 128) << 64;

            assembly {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(63, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(62, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(61, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(60, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(59, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(58, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(57, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(56, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(55, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(54, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(53, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(52, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(51, f))
                r := shr(f, r)

                r := shr(127, mul(r, r))
                f := shr(128, r)
                log_2 := or(log_2, shl(50, f))
            }

            int256 log_sqrt10001 = log_2 * 255738958999603826347141; // 128.128 representation of log_2(1.0001)

            int24 approx = int24(log_sqrt10001 >> 128);
            int24 t0 = approx + 1;
            int24 t1 = approx;
            int24 t2 = approx - 1;

            if (t0 <= MAX_TICK && getSqrtRatioAtTick(t0) <= sqrtPriceX96) {
                tick = t0;
            } else if (t1 >= MIN_TICK && getSqrtRatioAtTick(t1) <= sqrtPriceX96) {
                tick = t1;
            } else if (t2 >= MIN_TICK && getSqrtRatioAtTick(t2) <= sqrtPriceX96) {
                tick = t2;
            } else {
                tick = MIN_TICK;
            }
        }
    }
}
