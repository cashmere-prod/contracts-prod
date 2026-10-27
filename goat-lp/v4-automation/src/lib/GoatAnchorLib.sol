// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGoatChainlinkFeed, IGoatV3PoolObserve, IGoatScaledUiToken} from "../interfaces/GoatV4External.sol";
import {NoAnchor, AnchorVetoed, NcTwapUnavailable} from "./GoatV4Errors.sol";
import {GoatV4Constants as K} from "./GoatV4Constants.sol";

/**
 * @notice Chainlink anchor reads (fail-closed), session and multiplier rules for stock feeds, the pair price from two
 *         USD prices, and the v3 TWAP reads behind the source checks. Used by `GoatV4PairRegistry`.
 *
 * @dev Rule: there is no fallback path. Any defect of a feed reverts `NoAnchor`; any defect of a source read reverts
 *      `AnchorVetoed`. The try/catch around `observe` is not a fallback: it only maps the error to `AnchorVetoed`, and
 *      the catch branch reverts too.
 */
library GoatAnchorLib {
    uint256 internal constant Q192 = 1 << 192;

    /// @dev Unix time 0 was a Thursday, so (t + 3 days) mod 7 days = seconds since Monday 00:00 UTC.
    uint256 internal constant WEEK_SHIFT = 3 days;
    /// @dev The US stock 24/5 session runs from Sunday 20:00 ET to Friday 20:00 ET: Mon 00:00 to Sat 00:00 UTC in summer
    ///      time, Mon 01:00 to Sat 01:00 UTC in winter time. Their intersection counts as open: [Mon 01:00, Sat 00:00) UTC.
    uint256 internal constant SESSION_OPEN = 1 hours;
    uint256 internal constant SESSION_CLOSE = 5 days;
    /// @dev After an ERC-8056 multiplier step, a feed counts as reflecting the step only with a round written at least
    ///      this long AFTER the step took effect.
    uint256 internal constant MULTIPLIER_SETTLE = 1 hours;

    /// @notice Reads and checks a Chainlink feed. Returns the positive answer (8 decimals).
    /// @dev Conditions (each `NoAnchor`): answer > 0, updatedAt != 0, updatedAt <= now, answeredInRound >= roundId,
    ///      now - updatedAt <= maxAge, minAnswer <= answer <= maxAnswer. The age bound is inclusive: age == maxAge
    ///      passes, maxAge + 1 reverts.
    function readFeed(address feed, uint256 maxAge, int256 minAnswer, int256 maxAnswer)
        internal
        view
        returns (uint256 answer_, uint256 updatedAt_)
    {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IGoatChainlinkFeed(feed).latestRoundData();
        if (answer <= 0) revert NoAnchor();
        if (updatedAt == 0 || updatedAt > block.timestamp) revert NoAnchor();
        if (answeredInRound < roundId) revert NoAnchor();
        if (block.timestamp - updatedAt > maxAge) revert NoAnchor();
        if (answer < minAnswer || answer > maxAnswer) revert NoAnchor();
        return (uint256(answer), updatedAt);
    }

    /// @notice Session rule for a stock/RWA feed (fail-closed while the market is closed).
    /// @dev Closed: [Sat 00:00, Mon 01:00) UTC. While open, a round written before the start of this week (Mon 00:00
    ///      UTC), i.e. a feed not yet updated after the reopening, also reverts `NoAnchor`. Holiday hours are in the
    ///      registry's calendar (`closeMarket`); the registry checks them separately after this rule.
    function checkSession(uint256 updatedAt) internal view {
        uint256 intoWeek = checkSessionOpen();
        if (updatedAt < block.timestamp - intoWeek) revert NoAnchor();
    }

    /// @notice Calendar only (`xMarketHours`): the NC anchor of a feedless official stock token reverts `NoAnchor`
    ///         outside [Mon 01:00, Sat 00:00) UTC. Returns the seconds since Monday 00:00 UTC.
    function checkSessionOpen() internal view returns (uint256 intoWeek) {
        intoWeek = (block.timestamp + WEEK_SHIFT) % 7 days;
        if (intoWeek < SESSION_OPEN || intoWeek >= SESSION_CLOSE) revert NoAnchor();
    }

    /// @notice ERC-8056 multiplier rule: if the latest step has taken effect and the feed's round is not at least
    ///         `MULTIPLIER_SETTLE` newer than the step, the feed may not reflect the step yet -> `NoAnchor`. A pending
    ///         (future) step does not affect the price. The multiplier is NOT applied: the answer is already per raw token.
    function checkMultiplier(address token, uint256 updatedAt) internal view {
        uint256 eff = IGoatScaledUiToken(token).effectiveAt();
        if (eff <= block.timestamp && updatedAt < eff + MULTIPLIER_SETTLE) revert NoAnchor();
    }

    /// @notice Sequencer uptime feed (if any). Reverts `NoAnchor` while the sequencer is down or within `grace` seconds
    ///         of a restart. `feed == address(0)` means there is no feed.
    function checkSequencer(address feed, uint256 grace) internal view {
        if (feed == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = IGoatChainlinkFeed(feed).latestRoundData();
        // Chainlink convention: 0 = up, 1 = down. startedAt = the last status change.
        if (answer != 0) revert NoAnchor();
        if (startedAt == 0 || startedAt > block.timestamp) revert NoAnchor();
        if (block.timestamp - startedAt < grace) revert NoAnchor();
    }

    /// @notice Pair price (token1/token0, raw units) from two USD prices.
    /// @dev P* = (usd0 / usd1) · 10^(dec1 − dec0).  sqrtP* = sqrt(usd0·10^max(dec1−dec0,0)·2^192 / (usd1·10^max(dec0−dec1,0))).
    ///      For ETH/USDG (18/6) this is exactly mulDiv(ethUsd, 2^192, usdgUsd·1e12).
    ///      At listing the ends of the answer bounds are checked with the same math, so every answer inside the bounds
    ///      stays within uint160 and the TickMath range.
    function pairSqrtPrice(uint256 usd0, uint256 usd1, uint8 dec0, uint8 dec1)
        internal
        pure
        returns (uint160 sqrtP, int24 tick)
    {
        uint256 num = dec1 >= dec0 ? usd0 * 10 ** (dec1 - dec0) : usd0;
        uint256 den = dec0 > dec1 ? usd1 * 10 ** (dec0 - dec1) : usd1;
        uint256 ratioX192 = FullMath.mulDiv(num, Q192, den);
        sqrtP = uint160(Math.sqrt(ratioX192));
        tick = TickMath.getTickAtSqrtPrice(sqrtP);
    }

    /// @notice Mean tick of a v3 pool over `window` seconds (rounded toward negative infinity), in the requested orientation.
    /// @dev `flip`: mean tick of the inverse price (the cumulative difference is negated; exact). Used by the NC anchor and
    ///      the meter only; if `observe` reverts (short ring, no pool, ...) -> `NcTwapUnavailable` (fail-closed).
    function twapTick(address pool, uint32 window, bool flip) internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        // ago[1] = 0
        try IGoatV3PoolObserve(pool).observe(ago) returns (int56[] memory c, uint160[] memory) {
            if (c.length != 2) revert NcTwapUnavailable();
            return _meanTick(c[1] - c[0], window, flip, false);
        } catch {
            revert NcTwapUnavailable();
        }
    }

    /**
     * @notice Three mean ticks (v4 orientation, rounded toward negative infinity) from a single
     *         `observe([long, slow, fast, 0])` call. A reverting `observe` or a wrong length -> `AnchorVetoed`
     *         (fail-closed, no fallback).
     * @dev A push within the same second (same block or same transaction) does not change these values: v3 `swap`
     *      writes the observation with `slot0Start.tick`, and `observe(0)` returns that second's observation.
     */
    function twapTicks3(address pool, uint32 long_, uint32 slow, uint32 fast, bool flip)
        internal
        view
        returns (int24 tLong, int24 tSlow, int24 tFast)
    {
        uint32[] memory ago = new uint32[](4);
        ago[0] = long_;
        ago[1] = slow;
        ago[2] = fast;
        try IGoatV3PoolObserve(pool).observe(ago) returns (int56[] memory c, uint160[] memory) {
            if (c.length != 4) revert AnchorVetoed();
            tLong = _meanTick(c[3] - c[0], long_, flip, true);
            tSlow = _meanTick(c[3] - c[1], slow, flip, true);
            tFast = _meanTick(c[3] - c[2], fast, flip, true);
        } catch {
            revert AnchorVetoed();
        }
    }

    /**
     * @notice CL_V3DERIVED: the pair's three mean ticks over the path c0 -> Q -> c1, one `observe([long, slow, fast,
     *         0])` per leg in the same call. Hop `a` is log(Q raw / c0 raw) (`fa`: leg a's token0 is Q), hop `b` is
     *         log(c1 raw / Q raw) (`fb`: leg b's token0 is c1); their sum is log(c1 raw / c0 raw), the anchor's orientation.
     *         Fail-closed, no one-leg fallback: a leg's `observe` revert or wrong length, or a mean outside the
     *         extreme-tick bound (|t| <= NC_MAX_ABS_TICK, checked before the int24 cast) -> `AnchorVetoed`. A push within
     *         the same second moves neither leg's cumulatives (v3 writes the pre-swap tick), so it moves neither mean.
     */
    function pathTwapTicks3(address a, bool fa, address b, bool fb, uint32 long_, uint32 slow, uint32 fast)
        internal
        view
        returns (int24 tLong, int24 tSlow, int24 tFast)
    {
        (int256 l, int256 s, int256 f) = pathTwapRaw(a, fa, b, fb, long_, slow, fast);
        tLong = _ns7(l);
        tSlow = _ns7(s);
        tFast = _ns7(f);
    }

    /**
     * @notice CL_V3DERIVED: the path means without the range check (the meter maps an out-of-range mean to `R_EXTREME`).
     *         For each window the two hops' cumulative differences are ADDED in int256 and floored a single time toward
     *         negative infinity: the exact floor of the path's mean log price (rounding each leg first could be up to
     *         1 tick off). Each difference is taken modulo 2^56 like v3's own accumulator (`unchecked`; a legal window
     *         difference is < 2^30), so a wrapped accumulator never reverts. Any leg read failure -> `AnchorVetoed`.
     */
    function pathTwapRaw(address a, bool fa, address b, bool fb, uint32 long_, uint32 slow, uint32 fast)
        internal
        view
        returns (int256 tLong, int256 tSlow, int256 tFast)
    {
        int56[] memory ca = _observe4(a, long_, slow, fast);
        int56[] memory cb = _observe4(b, long_, slow, fast);
        tLong = _floorDiv(_hop(ca, 0, fa) + _hop(cb, 0, fb), long_);
        tSlow = _floorDiv(_hop(ca, 1, fa) + _hop(cb, 1, fb), slow);
        tFast = _floorDiv(_hop(ca, 2, fa) + _hop(cb, 2, fb), fast);
    }

    /// @dev One leg's `observe([long, slow, fast, 0])` cumulatives; a revert or a wrong length -> `AnchorVetoed`.
    function _observe4(address pool, uint32 long_, uint32 slow, uint32 fast) private view returns (int56[] memory c) {
        uint32[] memory ago = new uint32[](4);
        (ago[0], ago[1], ago[2]) = (long_, slow, fast);
        try IGoatV3PoolObserve(pool).observe(ago) returns (int56[] memory c_, uint160[] memory) {
            c = c_;
        } catch {
            revert AnchorVetoed();
        }
        if (c.length != 4) revert AnchorVetoed();
    }

    /// @dev A hop's cumulative difference over window `i` (now minus then, modulo 2^56), negated when flipped.
    function _hop(int56[] memory c, uint256 i, bool flip) private pure returns (int256 d) {
        int56 x;
        unchecked {
            x = c[3] - c[i];
        }
        d = flip ? -int256(x) : int256(x);
    }

    /// @dev floor(d / w) toward -inf.
    function _floorDiv(int256 d, uint32 w) private pure returns (int256 t) {
        int256 ww = int256(uint256(w));
        t = d / ww;
        if (d < 0 && d % ww != 0) t--;
    }

    /// @dev Extreme-tick bound (|t| <= NC_MAX_ABS_TICK) before the int24 cast (fail-closed).
    function _ns7(int256 t) private pure returns (int24) {
        if (t > K.NC_MAX_ABS_TICK || t < -K.NC_MAX_ABS_TICK) revert AnchorVetoed();
        return int24(t);
    }

    /**
     * @notice Floor tick of a v3 sqrtP in the requested orientation, computed from sqrtP (not `slot0.tick`): plain
     *         k = floor(log P); flipped floor(-log P) = -k when P sits exactly on k, else -k - 1. Shared by the registry
     *         (`_spotTickV4`) and the meter, so the meter's path calm check and `vetoOf` compute the same value.
     */
    function spotTick(uint160 sqrtP, bool flip) internal pure returns (int256) {
        int24 k = TickMath.getTickAtSqrtPrice(sqrtP);
        if (!flip) return k;
        return sqrtP == TickMath.getSqrtPriceAtTick(k) ? -int256(k) : -int256(k) - 1;
    }

    /// @dev Mean tick from a cumulative difference; `flip` = inverse price (difference negated); rounded toward negative
    ///      infinity when negative and inexact. A mean outside [MIN_TICK, MAX_TICK] is not wrapped into int24 but reverts
    ///      (`anchor`: `AnchorVetoed`, else `NcTwapUnavailable`; each caller's own error).
    function _meanTick(int56 d, uint32 window, bool flip, bool anchor) private pure returns (int24) {
        if (flip) d = -d;
        int56 w = int56(uint56(window));
        int56 t = d / w;
        if (d < 0 && d % w != 0) t--;
        if (t < TickMath.MIN_TICK || t > TickMath.MAX_TICK) {
            if (anchor) revert AnchorVetoed();
            revert NcTwapUnavailable();
        }
        return int24(t);
    }
}
