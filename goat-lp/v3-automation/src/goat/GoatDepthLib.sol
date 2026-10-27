// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Part of Goat LP, not derived from Revert Finance.
// Source pool depth (VD4): a walk of VD4_TICKS ticks in each direction that crosses initialized ticks (applying each
// tick's liquidityNet), times a time weight min(1, L_tw1800 / L_now). Crossing ticks means a narrow position only
// counts over its own range, and the time weight discounts liquidity added just before the measurement.
// GoatPairTable.sourceDepth exposes the same computation for off-chain monitoring.
//
// Amounts (raw units): down0 = token0 input needed to push the price VD4_TICKS down, up1 = token1 input needed to push
// it VD4_TICKS up. Per segment: down = floor(floor(L * 2^96 * (sA - sB) / sA) / sB), up = floor(L * (sB - sA) / 2^96),
// each rounded down separately. At most MAX_WALK_TICKS initialized ticks per direction (otherwise WalkTooLong, fail
// closed; within +-100 ticks there can be at most 101 for any tick spacing, so the limit is only a backstop).

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/BitMath.sol";

library GoatDepthLib {
    int24 internal constant VD4_TICKS = 100;
    uint32 internal constant VD4_TW_WINDOW = 1800;
    uint256 internal constant MAX_WALK_TICKS = 256;
    uint256 internal constant Q96 = 2 ** 96;

    error WalkTooLong();

    // walk of +-VD4_TICKS crossing ticks; returns (down0, up1, L_now, tick, ok). ok = false: more than MAX_WALK_TICKS
    // initialized ticks in one direction (callers fail closed: the table with InvalidPair(9), sourceDepth with
    // WalkTooLong)
    function walk(IUniswapV3Pool pool)
        internal
        view
        returns (uint256 down0, uint256 up1, uint128 lNow, int24 tick, bool ok)
    {
        uint160 sqrtP;
        (sqrtP, tick,,,,,) = pool.slot0();
        lNow = pool.liquidity();
        int24 ts = pool.tickSpacing();
        bool okDown;
        (down0, okDown) = _down(pool, ts, tick, sqrtP, lNow);
        (up1, ok) = _up(pool, ts, tick, sqrtP, lNow);
        ok = ok && okDown;
    }

    // L_tw = 1800 * 2^128 / (spl(now) - spl(now - 1800)) (harmonic mean from secondsPerLiquidity; the uint160
    // wrap-around is handled). If observe fails this REVERTS (the listing caller turns it into InvalidPair). A zero
    // difference gives 0 (fail closed).
    function timeWeightedL(IUniswapV3Pool pool) internal view returns (uint128) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = VD4_TW_WINDOW;
        (, uint160[] memory spl) = pool.observe(ago);
        return twFromSpl(spl[0], spl[1]);
    }

    function twFromSpl(uint160 splOld, uint160 splNew) internal pure returns (uint128) {
        uint160 d;
        unchecked {
            d = splNew - splOld;
        }
        if (d == 0) return 0;
        uint256 x = (uint256(VD4_TW_WINDOW) << 128) / d;
        return x > type(uint128).max ? type(uint128).max : uint128(x);
    }

    // time weight: usd * min(1, lTw / lNow); lNow = 0 gives 0 (the price sits in a liquidity gap: fail closed)
    function applyTimeWeight(uint256 usd, uint128 lNow, uint128 lTw) internal pure returns (uint256) {
        if (lNow == 0) return 0;
        if (lTw >= lNow) return usd;
        return FullMath.mulDiv(usd, lTw, lNow);
    }

    // floor(t / ts) (rounds toward negative infinity)
    function _compress(int24 t, int24 ts) private pure returns (int24 c) {
        c = t / ts;
        if (t < 0 && t % ts != 0) c--;
    }

    function _amt0(uint128 L, uint160 sLo, uint160 sHi) private pure returns (uint256) {
        return FullMath.mulDiv(uint256(L) << 96, sHi - sLo, sHi) / sLo;
    }

    function _amt1(uint128 L, uint160 sLo, uint160 sHi) private pure returns (uint256) {
        return FullMath.mulDiv(L, sHi - sLo, Q96);
    }

    function _applyNet(uint128 L, int128 net, bool up) private pure returns (uint128) {
        int256 x = up ? int256(uint256(L)) + int256(net) : int256(uint256(L)) - int256(net);
        if (x <= 0) return 0;
        return uint128(uint256(x));
    }

    // walk state (a memory struct to keep the stack shallow)
    struct Walk {
        IUniswapV3Pool pool;
        int24 ts;
        uint160 s; // current sqrt price
        uint128 L; // current in-range liquidity
        uint256 amt; // accumulated input (raw)
        uint256 n; // number of initialized ticks crossed
    }

    // down: initialized ticks t = cc * ts with end < t <= tick (cc in (cEnd, c]), in descending order; each crossing
    // does L -= net
    function _down(IUniswapV3Pool pool, int24 ts, int24 tick, uint160 sqrtP, uint128 L)
        private
        view
        returns (uint256, bool)
    {
        Walk memory w = Walk(pool, ts, sqrtP, L, 0, 0);
        int24 end = tick - VD4_TICKS;
        if (end < TickMath.MIN_TICK) end = TickMath.MIN_TICK;
        int24 c = _compress(tick, ts);
        int24 cLo = _compress(end, ts) + 1;
        for (int24 wd = c >> 8; wd >= cLo >> 8; --wd) {
            if (!_wordDown(w, wd, c, cLo)) return (0, false);
        }
        uint160 sEnd = TickMath.getSqrtRatioAtTick(end);
        if (sEnd < w.s) w.amt += _amt0(w.L, sEnd, w.s);
        return (w.amt, true);
    }

    function _wordDown(Walk memory w, int24 wd, int24 c, int24 cLo) private view returns (bool) {
        uint256 bm = w.pool.tickBitmap(int16(wd));
        int24 base = wd << 8;
        bm &= _mask(wd == (cLo >> 8) ? uint256(uint24(cLo - base)) : 0, wd == (c >> 8) ? uint256(uint24(c - base)) : 255);
        while (bm != 0) {
            uint8 b = BitMath.mostSignificantBit(bm);
            bm &= ~(uint256(1) << b);
            if (++w.n > MAX_WALK_TICKS) return false;
            int24 t = (base + int24(uint24(b))) * w.ts;
            uint160 st = TickMath.getSqrtRatioAtTick(t);
            if (st < w.s) {
                w.amt += _amt0(w.L, st, w.s);
                w.s = st;
            }
            w.L = _applyNet(w.L, _net(w.pool, t), false);
        }
        return true;
    }

    // up: initialized ticks t = cc * ts with tick < t <= hi (cc in [c + 1, cHi]), in ascending order; each crossing
    // does L += net
    function _up(IUniswapV3Pool pool, int24 ts, int24 tick, uint160 sqrtP, uint128 L)
        private
        view
        returns (uint256, bool)
    {
        Walk memory w = Walk(pool, ts, sqrtP, L, 0, 0);
        int24 hi = tick + VD4_TICKS;
        if (hi > TickMath.MAX_TICK) hi = TickMath.MAX_TICK;
        int24 cLo = _compress(tick, ts) + 1;
        int24 cHi = _compress(hi, ts);
        for (int24 wd = cLo >> 8; wd <= cHi >> 8; ++wd) {
            if (!_wordUp(w, wd, cLo, cHi)) return (0, false);
        }
        uint160 sHi = TickMath.getSqrtRatioAtTick(hi);
        if (sHi > w.s) w.amt += _amt1(w.L, w.s, sHi);
        return (w.amt, true);
    }

    function _wordUp(Walk memory w, int24 wd, int24 cLo, int24 cHi) private view returns (bool) {
        uint256 bm = w.pool.tickBitmap(int16(wd));
        int24 base = wd << 8;
        bm &= _mask(wd == (cLo >> 8) ? uint256(uint24(cLo - base)) : 0, wd == (cHi >> 8) ? uint256(uint24(cHi - base)) : 255);
        while (bm != 0) {
            uint8 b = BitMath.leastSignificantBit(bm);
            bm &= ~(uint256(1) << b);
            if (++w.n > MAX_WALK_TICKS) return false;
            int24 t = (base + int24(uint24(b))) * w.ts;
            uint160 st = TickMath.getSqrtRatioAtTick(t);
            if (st > w.s) {
                w.amt += _amt1(w.L, w.s, st);
                w.s = st;
            }
            w.L = _applyNet(w.L, _net(w.pool, t), true);
        }
        return true;
    }

    // mask of the bit range [lo, hi]
    function _mask(uint256 lo, uint256 hi) private pure returns (uint256) {
        return (hi == 255 ? type(uint256).max : (uint256(1) << (hi + 1)) - 1) & ~((uint256(1) << lo) - 1);
    }

    function _net(IUniswapV3Pool pool, int24 t) private view returns (int128 net) {
        (, net,,,,,,) = pool.ticks(t);
    }
}
