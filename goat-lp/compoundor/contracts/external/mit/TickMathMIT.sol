// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/**
 * @notice `getSqrtRatioAtTick`, ported to Solidity 0.7.6 from the MIT-licensed `TickMath` of
 *         Uniswap v4-core (`src/libraries/TickMath.sol`, `getSqrtPriceAtTick`).
 *
 * @dev Why this exists: the Uniswap v3-core `TickMath` is GPL-2.0-or-later, and a contract that
 *      imports it becomes a derivative work under the GPL, while this project is MIT. v4-core
 *      publishes the same algorithm under MIT, so it is used as the source.
 *
 * @dev Port differences (language version only; the math is unchanged):
 *      - The v4 code targets 0.8 and uses `unchecked` blocks and a custom error. Arithmetic in
 *        0.7.6 is already unchecked, so `unchecked` is dropped, and `require` replaces the
 *        custom error.
 *      - The memory annotation on `assembly` blocks needs 0.8.13 or later; plain `assembly` is used.
 *      - The function keeps the v3 name `getSqrtRatioAtTick` to match the call sites in this tree.
 *
 * @dev The output of this port matches the v3-core original bit for bit, at the bounds of the tick
 *      range and under fuzzing.
 */
library TickMathMIT {
    /// @dev Smallest tick that can be passed to `getSqrtRatioAtTick`
    int24 internal constant MIN_TICK = -887272;
    /// @dev Largest tick that can be passed to `getSqrtRatioAtTick`
    int24 internal constant MAX_TICK = 887272;

    /// @dev `getSqrtRatioAtTick(MIN_TICK)`
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev `getSqrtRatioAtTick(MAX_TICK)`
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /**
     * @notice Returns sqrt(1.0001^tick) as a Q64.96 number.
     * @param tick the tick for which to compute sqrt(1.0001^tick)
     * @return sqrtPriceX96 square root of the token1/token0 price ratio, as a Q64.96
     */
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick;
        assembly {
            tick := signextend(2, tick)
            // mask = 0 if tick >= 0, -1 if tick < 0
            let mask := sar(255, tick)
            // in both cases |tick| = mask ^ (tick + mask)
            absTick := xor(mask, add(mask, tick))
        }
        require(absTick <= uint256(int256(MAX_TICK)), "T");

        // The tick is split into bits; for each set bit i the factor 1/sqrt(1.0001^(2^i)) is
        // applied (Q128.128). The constants are rounded to the nearest integer.
        uint256 price;
        assembly {
            price := xor(shl(128, 1), mul(xor(shl(128, 1), 0xfffcb933bd6fad37aa2d162d1a594001), and(absTick, 0x1)))
        }
        if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;

        assembly {
            // if tick > 0, price = type(uint256).max / price
            if sgt(tick, 0) { price := div(not(0), price) }
            // Q128.128 -> Q128.96: divide by 1<<32 rounding up, so that getTickAtSqrtRatio(output)
            // stays consistent. Adding 2^32 - 1 cannot overflow because `price` fits in 192 bits.
            sqrtPriceX96 := shr(32, add(price, sub(shl(32, 1), 1)))
        }
    }
}
