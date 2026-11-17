// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Part of Goat LP, not derived from Revert Finance.
// Source pool depth (VD4): a walk of VD4_TICKS ticks in each direction that crosses initialized ticks (applying each
// tick's liquidityNet). Crossing ticks means a narrow position only counts over its own range. VD4 is the smaller of
// two bounds, the same measure as the v4 source meter: VD4 = min(fac * W, W_cap), where W is the plain walk,
// fac = min(1, L_tw1800 / L_now) and W_cap the same walk with every segment's liquidity clipped to L_tw1800. L_tw and
// L_now see in-range liquidity only: fac discounts liquidity just added at the current tick, the clip discounts
// liquidity just added anywhere else within the walk. GoatPairTable.sourceDepth exposes the plain walk and L_tw for
// off-chain monitoring, and clippedDepth the clipped walk.
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

    // the result of a walk: the plain amounts (down0, up1), the same amounts with every segment's liquidity clipped to
    // the walk's cap (clip0, clip1), L_now, and ok = false when a direction had more than MAX_WALK_TICKS initialized
    // ticks (callers fail closed: the table with InvalidPair(9), sourceDepth with WalkTooLong)
    struct Depth {
        uint256 down0;
        uint256 up1;
        uint256 clip0;
        uint256 clip1;
        uint128 lNow;
        bool ok;
    }

    // walk of +-VD4_TICKS crossing ticks, with the segments clipped to `cap` for the clipped amounts
    function walk(IUniswapV3Pool pool, uint256 cap) internal view returns (Depth memory) {
        return walkUntil(pool, cap, type(uint256).max, type(uint256).max);
    }

    // The same walk, ending a direction once its clipped amount reaches stop0 (down) or stop1 (up). The walk only adds
    // and a plain amount is never below its clipped amount, so a clipped amount at or above its stop is a proven lower
    // bound of both full amounts, and a clipped amount below its stop means both amounts are the full walk's.
    function walkUntil(IUniswapV3Pool pool, uint256 cap, uint256 stop0, uint256 stop1)
        internal
        view
        returns (Depth memory d)
    {
        (uint160 sqrtP, int24 tick,,,,,) = pool.slot0();
        d.lNow = pool.liquidity();
        int24 ts = pool.tickSpacing();
        Walk memory w = Walk(pool, ts, sqrtP, d.lNow, cap, 0, 0, 0, stop0);
        bool okDown = _down(w, tick);
        (d.down0, d.clip0) = (w.amt, w.clip);
        w = Walk(pool, ts, sqrtP, d.lNow, cap, 0, 0, 0, stop1);
        d.ok = _up(w, tick) && okDown;
        (d.up1, d.clip1) = (w.amt, w.clip);
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
        uint256 cap; // segment liquidity cap of the clipped amount
        uint256 amt; // accumulated input (raw), plain
        uint256 clip; // accumulated input (raw), each segment's L clipped to cap
        uint256 n; // number of initialized ticks crossed
        uint256 stop; // the walk ends once clip reaches this
    }

    // one segment down to sqrt price st (a clipped L is below 2^128 since it is below the segment's L)
    function _segDown(Walk memory w, uint160 st) private pure {
        uint256 a = _amt0(w.L, st, w.s);
        w.amt += a;
        w.clip += w.L > w.cap ? _amt0(uint128(w.cap), st, w.s) : a;
        w.s = st;
    }

    // one segment up to sqrt price st
    function _segUp(Walk memory w, uint160 st) private pure {
        uint256 a = _amt1(w.L, w.s, st);
        w.amt += a;
        w.clip += w.L > w.cap ? _amt1(uint128(w.cap), w.s, st) : a;
        w.s = st;
    }

    // down: initialized ticks t = cc * ts with end < t <= tick (cc in (cEnd, c]), in descending order; each crossing
    // does L -= net
    function _down(Walk memory w, int24 tick) private view returns (bool) {
        int24 end = tick - VD4_TICKS;
        if (end < TickMath.MIN_TICK) end = TickMath.MIN_TICK;
        int24 c = _compress(tick, w.ts);
        int24 cLo = _compress(end, w.ts) + 1;
        for (int24 wd = c >> 8; wd >= cLo >> 8 && w.clip < w.stop; --wd) {
            if (!_wordDown(w, wd, c, cLo)) return false;
        }
        uint160 sEnd = TickMath.getSqrtRatioAtTick(end);
        if (sEnd < w.s && w.clip < w.stop) _segDown(w, sEnd);
        return true;
    }

    function _wordDown(Walk memory w, int24 wd, int24 c, int24 cLo) private view returns (bool) {
        uint256 bm = w.pool.tickBitmap(int16(wd));
        int24 base = wd << 8;
        bm &= _mask(wd == (cLo >> 8) ? uint256(uint24(cLo - base)) : 0, wd == (c >> 8) ? uint256(uint24(c - base)) : 255);
        while (bm != 0 && w.clip < w.stop) {
            uint8 b = BitMath.mostSignificantBit(bm);
            bm &= ~(uint256(1) << b);
            if (++w.n > MAX_WALK_TICKS) return false;
            int24 t = (base + int24(uint24(b))) * w.ts;
            uint160 st = TickMath.getSqrtRatioAtTick(t);
            if (st < w.s) _segDown(w, st);
            w.L = _applyNet(w.L, _net(w.pool, t), false);
        }
        return true;
    }

    // up: initialized ticks t = cc * ts with tick < t <= hi (cc in [c + 1, cHi]), in ascending order; each crossing
    // does L += net
    function _up(Walk memory w, int24 tick) private view returns (bool) {
        int24 hi = tick + VD4_TICKS;
        if (hi > TickMath.MAX_TICK) hi = TickMath.MAX_TICK;
        int24 cLo = _compress(tick, w.ts) + 1;
        int24 cHi = _compress(hi, w.ts);
        for (int24 wd = cLo >> 8; wd <= cHi >> 8 && w.clip < w.stop; ++wd) {
            if (!_wordUp(w, wd, cLo, cHi)) return false;
        }
        uint160 sHi = TickMath.getSqrtRatioAtTick(hi);
        if (sHi > w.s && w.clip < w.stop) _segUp(w, sHi);
        return true;
    }

    function _wordUp(Walk memory w, int24 wd, int24 cLo, int24 cHi) private view returns (bool) {
        uint256 bm = w.pool.tickBitmap(int16(wd));
        int24 base = wd << 8;
        bm &= _mask(wd == (cLo >> 8) ? uint256(uint24(cLo - base)) : 0, wd == (cHi >> 8) ? uint256(uint24(cHi - base)) : 255);
        while (bm != 0 && w.clip < w.stop) {
            uint8 b = BitMath.leastSignificantBit(bm);
            bm &= ~(uint256(1) << b);
            if (++w.n > MAX_WALK_TICKS) return false;
            int24 t = (base + int24(uint24(b))) * w.ts;
            uint160 st = TickMath.getSqrtRatioAtTick(t);
            if (st > w.s) _segUp(w, st);
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
