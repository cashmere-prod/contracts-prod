// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {RangeOutOfBounds} from "./GoatV4Errors.sol";

/**
 * @notice New range (centred on the anchor, same width) and one-sided principal.
 */
library GoatRecenterMath {
    /// @notice Integer division rounding toward negative infinity (ts > 0).
    function floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) q -= 1;
    }

    /// @notice Smallest usable tick on the `ts` grid (at or above MIN_TICK).
    function minUsableTick(int24 ts) internal pure returns (int24) {
        return int24(-floorDiv(-int256(TickMath.MIN_TICK), ts) * ts);
    }

    /// @notice Largest usable tick on the `ts` grid.
    function maxUsableTick(int24 ts) internal pure returns (int24) {
        return int24(floorDiv(int256(TickMath.MAX_TICK), ts) * ts);
    }

    /**
     * @notice New range centred on the anchor tick:
     *   newLower = nearest((anchorTick − W/2) / ts) · ts,  newUpper = newLower + W
     * @dev "Nearest" rounds half up. The centre is at most ts/2 (plus 1/2 when W is odd) from the anchor. The spot
     *      price is never read. A result outside the usable tick range is not clamped: it reverts `RangeOutOfBounds`.
     */
    function centredRange(int24 anchorTick, int24 width, int24 ts) internal pure returns (int24 lo, int24 hi) {
        int256 raw = int256(anchorTick) - int256(width) / 2;
        int256 q = floorDiv(raw, ts);
        int256 r = raw - q * ts; // 0 <= r < ts
        if (2 * r >= ts) q += 1;
        int256 lo256 = q * ts;
        int256 hi256 = lo256 + width;
        if (lo256 < minUsableTick(ts) || hi256 > maxUsableTick(ts)) revert RangeOutOfBounds();
        lo = int24(lo256);
        hi = int24(hi256);
    }

    /**
     * @notice Principal of a one-sided burn, rounded down like the pool's own liquidity removal.
     * @dev Lower side (price below the range): the position is 100% token0. Upper side: 100% token1.
     *      Source: v4-core `SqrtPriceMath.sol:261-290` (removal uses roundUp = false).
     */
    function oneSidedPrincipal(bool upperSide, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 p0, uint256 p1)
    {
        uint160 sa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(tickUpper);
        if (upperSide) p1 = SqrtPriceMath.getAmount1Delta(sa, sb, liquidity, false);
        else p0 = SqrtPriceMath.getAmount0Delta(sa, sb, liquidity, false);
    }
}
