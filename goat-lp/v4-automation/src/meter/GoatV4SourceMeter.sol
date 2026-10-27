// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GoatV4Constants as K} from "../lib/GoatV4Constants.sol";
import {GoatAnchorLib} from "../lib/GoatAnchorLib.sol";
import {FeedRule, PoolSpec, PairConfig, NcPairConfig, PairEntry, NcSource} from "../lib/GoatPairTypes.sol";
import {
    IGoatChainlinkFeed,
    IGoatV3PoolObserve,
    IGoatV3PoolDepth,
    IGoatV3Factory,
    IGoatErc20Decimals,
    IGoatScaledUiToken,
    IGoatPokeOracle,
    PokeWindow
} from "../interfaces/GoatV4External.sol";
import "../lib/GoatV4Errors.sol";

/**
 * @notice All listing-time checks of a pair row and the VD4 depth measure. STATELESS: no owner, no storage, no setters.
 *         `GoatV4PairRegistry` relies on it only at LISTING (queue, apply, founding seed) through an immutable address;
 *         run-time reads stay in the registry. Off-chain checks can call the same views with `eth_call`, so the
 *         on-chain and off-chain measures are one and the same code.
 *
 * @dev VD4: a simulated swap from the current tick 100 ticks down (token0 in) and 100 ticks up (token1 in), crossing
 *      EVERY initialized tick on the way with its `liquidityNet` (v3: `tickBitmap` / `ticks`; v4: PoolManager
 *      `extsload`, state slots +4 / +5). At most `MAX_WALK_TICKS` initialized ticks per direction; more is fail-closed.
 *      Time weight: on a v3 source `L_tw = 1800·2^128 / Δspl` (observe([1800, 0])), on a POKE source the window's
 *      smallest liquidity (`minL`); `fac = min(1, L_tw / L_now)`. `L_tw` / `minL` and `L_now` only see in-range
 *      liquidity: `fac` discounts liquidity just added at the current tick, but not liquidity added elsewhere within
 *      ±100 ticks. The SOURCE VD4 is therefore the smaller of two bounds: VD4 = min(fac · W, W_cap), where
 *      W = min(value(down), value(up)) (whole USD) is the raw walk and W_cap the same walk with EVERY segment's
 *      liquidity clipped to `min(L_seg, L_tw)` (POKE: `minL`). Recently added liquidity, in range or not, is never
 *      counted above the time-weighted in-range level in any segment, and VD4 never exceeds `fac · W`.
 *      The exec-pool walk (floor $500, `K.MIN_POOL_FILL_USD`) and the `v3Depth` / `v4Depth` views are the raw,
 *      unclipped walk. There is no relative "deepest tier" rule.
 *      CL_V3DERIVED (kind 6): the path c0 -> Q -> c1 over two canonical v3 legs is measured per leg with the same
 *      formula at ±50 ticks (VD50) and ±100 ticks (VD4); path depth = min(VD50_1, VD50_2, VD4_1 * VD4_2 / (VD4_1 + VD4_2)).
 *
 * @dev Errors: a structural defect is `BadPairEntry`, a usability defect `SourceUnusable(reason)` (reason codes below).
 *
 * @dev The v3 core is not imported (GPL); the interfaces are our own.
 */
contract GoatV4SourceMeter {
    // ------------------------------------------------------------------ reason codes (`SourceUnusable`)

    uint8 public constant R_RING = 1; // v3 source ring < 1,800 (a CL_V3DERIVED leg: < 1,801)
    uint8 public constant R_OBSERVE = 2; // observe([1800, 900, 60, 10, 0]) failed
    uint8 public constant R_DEPTH = 3; // source depth < K.MIN_SOURCE_DEPTH_USD ($4,000; CL_V3DERIVED: the path depth)
    uint8 public constant R_CALM = 4; // |spot − TWAP900| (POKE: |v4 spot − medMid| or the spread) > G
    uint8 public constant R_EXTREME = 5; // extreme price: |tick| > 800,000
    uint8 public constant R_POOL_WALK = 6; // an exec pool's ±100-tick walk < $500 (K.MIN_POOL_FILL_USD)
    uint8 public constant R_POKE_GAP = 7; // the poke window is not 15/15 registered
    uint8 public constant R_WALK_BOUND = 8; // more than 256 initialized ticks in one direction
    uint8 public constant R_LIQ = 9; // inconsistent liquidity (negative while crossing)
    uint8 public constant R_ANCHOR = 10; // CL: |feed anchor − TWAP900| (POKE: − medMid) > vetoTicks

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant POOLS_SLOT = 6;
    /// @dev Selector compared against in the ERC-8056 probe (in no interface): bytes4(keccak256("goatV4MeterNoSuchSelector()")).
    bytes4 internal constant NO_SUCH_SELECTOR = 0xd9d3824a;
    /// @dev FIXED gas budget of each ERC-8056 probe, so the classification does not depend on the caller's gas.
    uint256 internal constant PROBE_GAS = 300_000;
    /// @dev Minimum `gasleft` before a probe, so the callee gets the full PROBE_GAS under the 63/64 rule (+ cold access / memory margin).
    uint256 internal constant PROBE_GAS_FLOOR = PROBE_GAS + PROBE_GAS / 63 + 20_000;
    /// @dev `Error(string)` and `Panic(uint256)` selectors: for these the error key is the WHOLE data (the message / code tells them apart).
    bytes4 internal constant ERR_STRING = 0x08c379a0;
    bytes4 internal constant ERR_PANIC = 0x4e487b71;

    IPoolManager public constant POOL_MANAGER = IPoolManager(K.POOL_MANAGER);
    /// @notice Oracle of the POKE sources (must be the registry's; the registry constructor checks it).
    IGoatPokeOracle public immutable POKE_ORACLE;

    /// @dev Walk context: a v3 pool, or the state slot of a v4 poolId.
    struct Walk {
        bool v4;
        address pool;
        uint256 state;
        int24 ts;
        uint256 cap; // segment liquidity cap (source: L_tw / minL; raw walk: type(uint256).max)
        int24 span; // walk length each way (VD4_TICKS; a CL_V3DERIVED leg's VD50 uses VD4_LEG_TICKS)
    }

    /// @dev Listing valuation: the USD prices (8 decimals) and units of the pair's two currencies. On an NC row (`nc`)
    ///      the X leg is first converted into the hard token's RAW units with the anchor tick `a` (log(c1 raw / c0 raw)),
    ///      then valued with the hard feed, so X's unit price is never rounded to 8 decimals; X's `usd` field is unused.
    struct Px {
        uint256 usd0;
        uint256 usd1;
        uint256 unit0;
        uint256 unit1;
        bool nc;
        bool ncIs0;
        int24 a;
    }

    constructor(address pokeOracle_) {
        if (pokeOracle_.code.length == 0) revert BadDeployment();
        POKE_ORACLE = IGoatPokeOracle(pokeOracle_);
    }

    // ================================================================== DEPTH (VD4)

    /// @notice ±100-tick walk of a v3 pool (raw units) and its liquidity measures.
    function v3Depth(address pool) public view returns (uint256 down0, uint256 up1, uint128 lNow, uint256 lTw) {
        return _v3Depth(pool, false, K.VD4_TICKS);
    }

    /// @dev `capTw`: each segment's liquidity is clipped to `lTw` (source VD4); otherwise the raw walk. `span`: ticks
    ///      each way.
    function _v3Depth(address pool, bool capTw, int24 span)
        internal
        view
        returns (uint256 down0, uint256 up1, uint128 lNow, uint256 lTw)
    {
        (uint160 sp, int24 tick,,,,,) = IGoatV3PoolObserve(pool).slot0();
        lNow = IGoatV3PoolDepth(pool).liquidity();
        uint32[] memory ago = new uint32[](2);
        ago[0] = K.VD4_TW_WINDOW;
        (, uint160[] memory spl) = IGoatV3PoolObserve(pool).observe(ago);
        uint256 d;
        unchecked {
            d = uint160(spl[1] - spl[0]);
        }
        lTw = d == 0 ? type(uint256).max : (uint256(K.VD4_TW_WINDOW) << 128) / d;
        Walk memory w =
            Walk(false, pool, 0, IGoatV3PoolDepth(pool).tickSpacing(), capTw ? lTw : type(uint256).max, span);
        (down0, up1) = _walk(w, sp, tick, lNow);
    }

    /// @notice ±100-tick walk of a v4 pool (raw units) and its current liquidity (`extsload`; v4 has no time weight).
    function v4Depth(bytes32 poolId, int24 ts) public view returns (uint256 down0, uint256 up1, uint128 lNow) {
        return _v4Depth(poolId, ts, type(uint256).max);
    }

    /// @dev `cap`: segment liquidity cap (POKE source: the window's `minL`; raw walk: type(uint256).max).
    function _v4Depth(bytes32 poolId, int24 ts, uint256 cap)
        internal
        view
        returns (uint256 down0, uint256 up1, uint128 lNow)
    {
        uint256 st = uint256(keccak256(abi.encode(poolId, POOLS_SLOT)));
        uint256 w0 = uint256(POOL_MANAGER.extsload(bytes32(st)));
        uint160 sp = uint160(w0);
        if (sp == 0) revert BadPairEntry();
        lNow = uint128(uint256(POOL_MANAGER.extsload(bytes32(st + 3))));
        (down0, up1) = _walk(Walk(true, address(0), st, ts, cap, K.VD4_TICKS), sp, int24(uint24(w0 >> 160)), lNow);
    }

    function _walk(Walk memory w, uint160 sp, int24 tick, uint128 l)
        internal
        view
        returns (uint256 down0, uint256 up1)
    {
        down0 = _walkDown(w, sp, tick, l);
        up1 = _walkUp(w, sp, tick, l);
    }

    /// @dev Down (token0 in): target = tick − span; every initialized tick in (target, t] is crossed (L −= net).
    function _walkDown(Walk memory w, uint160 sp, int24 tick, uint128 l0) internal view returns (uint256 amt) {
        int24 target = tick - w.span < TickMath.MIN_TICK ? TickMath.MIN_TICK : tick - w.span;
        uint160 cur = sp;
        int256 l = int256(uint256(l0));
        int24 t = tick;
        for (uint256 crossed;;) {
            (int24 next, bool init) = _nextBelow(w, t, target);
            uint160 sn = TickMath.getSqrtPriceAtTick(next);
            if (sn < cur) {
                amt += SqrtPriceMath.getAmount0Delta(sn, cur, _capL(l, w.cap), false);
                cur = sn;
            }
            if (!init) return amt;
            l -= _net(w, next);
            if (l < 0) revert SourceUnusable(R_LIQ);
            if (++crossed > K.MAX_WALK_TICKS) revert SourceUnusable(R_WALK_BOUND);
            t = next - 1;
        }
    }

    /// @dev Up (token1 in): target = tick + span; every initialized tick in (t, target) is crossed (L += net).
    function _walkUp(Walk memory w, uint160 sp, int24 tick, uint128 l0) internal view returns (uint256 amt) {
        int24 target = tick + w.span > TickMath.MAX_TICK ? TickMath.MAX_TICK : tick + w.span;
        uint160 cur = sp;
        int256 l = int256(uint256(l0));
        int24 t = tick;
        for (uint256 crossed;;) {
            (int24 next, bool init) = _nextAbove(w, t, target);
            uint160 sn = TickMath.getSqrtPriceAtTick(next);
            if (sn > cur) {
                amt += SqrtPriceMath.getAmount1Delta(cur, sn, _capL(l, w.cap), false);
                cur = sn;
            }
            if (!init) return amt;
            l += _net(w, next);
            if (l < 0) revert SourceUnusable(R_LIQ);
            if (++crossed > K.MAX_WALK_TICKS) revert SourceUnusable(R_WALK_BOUND);
            t = next;
        }
    }

    /// @dev The largest initialized tick at or below t and ABOVE the target; otherwise (target, false).
    function _nextBelow(Walk memory w, int24 t, int24 target) internal view returns (int24 next, bool init) {
        int24 c = _compress(t, w.ts);
        int24 cMin = _compress(target, w.ts);
        uint256 mask = _maskBelowOrAt(uint8(uint24(c % 256)));
        while (true) {
            int16 word = int16(c >> 8);
            uint256 m = _bitmap(w, word) & mask;
            if (m != 0) {
                int24 found = (int24(word) * 256 + int24(uint24(BitMath.mostSignificantBit(m)))) * w.ts;
                return found > target ? (found, true) : (target, false);
            }
            c = int24(word) * 256 - 1;
            if (c < cMin) return (target, false);
            mask = type(uint256).max;
        }
    }

    /// @dev The smallest initialized tick ABOVE t and BELOW the target; otherwise (target, false).
    function _nextAbove(Walk memory w, int24 t, int24 target) internal view returns (int24 next, bool init) {
        int24 c = _compress(t, w.ts) + 1;
        int24 cMax = _compress(target, w.ts);
        if (c > cMax) return (target, false);
        uint256 mask = ~((uint256(1) << uint8(uint24(c % 256))) - 1);
        while (true) {
            int16 word = int16(c >> 8);
            uint256 m = _bitmap(w, word) & mask;
            if (m != 0) {
                int24 found = (int24(word) * 256 + int24(uint24(BitMath.leastSignificantBit(m)))) * w.ts;
                return found < target ? (found, true) : (target, false);
            }
            c = (int24(word) + 1) * 256;
            if (c > cMax) return (target, false);
            mask = type(uint256).max;
        }
    }

    /// @dev Segment liquidity clipped to the cap (l >= 0; the caller checks). If cap < l then cap < 2^128.
    function _capL(int256 l, uint256 cap) internal pure returns (uint128) {
        uint256 u = uint256(l);
        return uint128(u < cap ? u : cap);
    }

    function _maskBelowOrAt(uint8 bit) internal pure returns (uint256) {
        return (uint256(1) << bit) - 1 + (uint256(1) << bit);
    }

    /// @dev Compression rounding toward negative infinity (tick / ts).
    function _compress(int24 t, int24 ts) internal pure returns (int24 c) {
        c = t / ts;
        if (t < 0 && t % ts != 0) c--;
    }

    function _bitmap(Walk memory w, int16 word) internal view returns (uint256) {
        if (!w.v4) return IGoatV3PoolDepth(w.pool).tickBitmap(word);
        return uint256(POOL_MANAGER.extsload(keccak256(abi.encode(int256(word), w.state + 5))));
    }

    function _net(Walk memory w, int24 t) internal view returns (int256) {
        if (!w.v4) {
            (, int128 net,,,,,,) = IGoatV3PoolDepth(w.pool).ticks(t);
            return net;
        }
        uint256 v = uint256(POOL_MANAGER.extsload(keccak256(abi.encode(int256(t), w.state + 4))));
        return int128(int256(v >> 128));
    }

    // ================================================================== VALUATION

    /// @dev Whole USD of a raw amount (8-decimal answer, `unit` = 10^decimals).
    function _usd(uint256 amt, uint256 usd8, uint256 unit) internal pure returns (uint256) {
        return FullMath.mulDiv(amt, usd8, unit * 1e8);
    }

    /// @dev Value of a raw amount `amt` of X in the other token's raw units; `tick` = log_{1.0001}(other raw / X raw).
    function _xToOther(uint256 amt, int24 tick) internal pure returns (uint256) {
        uint160 s = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(FullMath.mulDiv(amt, s, Q96), s, Q96);
    }

    /// @dev Walk value: min(value(down), value(up)); `isC1` tells whether each direction's input is the pair's currency1
    ///      (by flow direction), `px` is the pair price.
    function _minUsd(uint256 a, bool aIsC1, uint256 b, bool bIsC1, Px memory px) internal pure returns (uint256) {
        uint256 va = _legUsd(a, aIsC1, px);
        uint256 vb = _legUsd(b, bIsC1, px);
        return va < vb ? va : vb;
    }

    /// @dev Whole USD of one leg. The X leg of an NC row: first into the hard token's raw units (anchor `a`), then the hard feed.
    function _legUsd(uint256 amt, bool isC1, Px memory px) internal pure returns (uint256) {
        if (px.nc && isC1 != px.ncIs0) {
            return px.ncIs0
                ? _usd(_xToOther(amt, px.a), px.usd1, px.unit1)
                : _usd(_xToOther(amt, -px.a), px.usd0, px.unit0);
        }
        return isC1 ? _usd(amt, px.usd1, px.unit1) : _usd(amt, px.usd0, px.unit0);
    }

    /// @dev Time weight: the value with min(1, lTw / lNow) applied (lNow = 0 → 0).
    function _fac(uint256 v, uint256 lTw, uint256 lNow) internal pure returns (uint256) {
        if (lNow == 0) return 0;
        return lTw >= lNow ? v : FullMath.mulDiv(v, lTw, lNow);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ================================================================== STRUCTURAL CHECKS

    function _decimals(address token) internal view returns (uint8 d) {
        d = token == address(0) ? 18 : IGoatErc20Decimals(token).decimals();
        if (d > K.MAX_TOKEN_DECIMALS) revert BadPairEntry();
    }

    /// @dev ERC-8056 detection: if `effectiveAt()` returns 32 bytes, the multiplier rule is turned on. Fail-closed:
    ///      (1) Each probe runs with a FIXED `PROBE_GAS`, and `gasleft() >= PROBE_GAS_FLOOR` is required first
    ///          (`BadPairEntry` otherwise), so the result does not depend on the caller's gas: with enough gas every
    ///          call gives the same class, with too little it reverts (gas estimation stays monotone).
    ///      (2) A probe that reverts after using more than half of its budget (out of gas) gives `BadPairEntry`.
    ///      (3) If `effectiveAt` reverts, the token is asked again with a selector it does NOT have (`NO_SUCH_SELECTOR`).
    ///          "Not scaled" is read only when both reverts are the SAME error (`_sameError`): an empty revert, a
    ///          diamond's `FacetNotFound()`, or a custom error whose only difference is the word that echoes the selector
    ///          asked (`FunctionNotFound(bytes4)`). For `Error(string)` and `Panic` the WHOLE data is compared
    ///          ("paused" ≠ "Diamond: Function does not exist"). If the unknown selector succeeds or the errors differ:
    ///          `BadPairEntry`.
    ///      Remaining assumption (a probe cannot tell the cases apart): a scaled token that refuses `effectiveAt` with
    ///      revert data byte-identical to an unknown selector's (or the same custom error differing only in the echoed
    ///      selector word) while `decimals()` works is read as not scaled. When a stock row is listed, the owner checks
    ///      the stored FLAG_UI_SCALED bit against whether the token implements ERC-8056.
    function _isScaled(address token) internal view returns (bool) {
        if (token == address(0)) return false;
        (bool ok, bytes memory ret) = _probe(token, IGoatScaledUiToken.effectiveAt.selector);
        if (ok) return ret.length == 32;
        (bool ok2, bytes memory ret2) = _probe(token, NO_SUCH_SELECTOR);
        if (ok2 || !_sameError(ret, ret2)) revert BadPairEntry();
        return false;
    }

    /// @dev A single probe with a fixed budget (see `_isScaled` (1)-(2)).
    function _probe(address token, bytes4 sel) internal view returns (bool ok, bytes memory ret) {
        if (gasleft() < PROBE_GAS_FLOOR) revert BadPairEntry();
        uint256 g0 = gasleft();
        (ok, ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeWithSelector(sel));
        if (!ok && g0 - gasleft() > PROBE_GAS / 2) revert BadPairEntry();
    }

    /// @dev Whether two revert payloads are the same error: byte-equal; or the same length, the same custom error selector
    ///      (NOT Error / Panic), in 32-byte word layout, with every differing word being the `effectiveAt` selector in `a`
    ///      and the `NO_SUCH_SELECTOR` selector in `b` (left-aligned bytes4), i.e. the error only echoes the selector asked.
    function _sameError(bytes memory a, bytes memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        if (keccak256(a) == keccak256(b)) return true;
        if (a.length < 4 || (a.length - 4) % 32 != 0) return false;
        bytes32 wa;
        bytes32 wb;
        assembly ("memory-safe") {
            wa := mload(add(a, 32))
            wb := mload(add(b, 32))
        }
        bytes4 sel = bytes4(wa);
        if (sel != bytes4(wb) || sel == ERR_STRING || sel == ERR_PANIC) return false;
        bytes32 echoA = bytes32(IGoatScaledUiToken.effectiveAt.selector);
        bytes32 echoB = bytes32(NO_SUCH_SELECTOR);
        uint256 end = a.length + 32;
        for (uint256 o = 36; o < end; o += 32) {
            assembly ("memory-safe") {
                wa := mload(add(a, o))
                wb := mload(add(b, o))
            }
            if (wa != wb && (wa != echoA || wb != echoB)) return false;
        }
        return true;
    }

    /// @dev Structural and live health of a feed rule; returns the current answer (8 decimals). Session and age are NOT checked.
    function _feed(FeedRule memory r) internal view returns (uint256) {
        if (r.feed == address(0) || r.maxAge < K.MIN_FEED_AGE || r.maxAge > K.MAX_FEED_AGE) revert BadPairEntry();
        if (r.minAnswer == 0 || r.minAnswer >= r.maxAnswer || r.maxAnswer > K.BAD_ROUND_CEILING) revert BadPairEntry();
        if (IGoatChainlinkFeed(r.feed).decimals() != 8) revert BadPairEntry();
        (, int256 a,,,) = IGoatChainlinkFeed(r.feed).latestRoundData();
        if (a < int256(uint256(r.minAnswer)) || a > int256(uint256(r.maxAnswer))) revert BadPairEntry();
        return uint256(a);
    }

    function _flags(FeedRule memory r, address token) internal view returns (uint8) {
        return (r.marketHours ? K.FLAG_MARKET_HOURS : 0) | (_isScaled(token) ? K.FLAG_UI_SCALED : 0);
    }

    function poolIdOf(address c0, address c1, PoolSpec memory p) public pure returns (bytes32) {
        return keccak256(abi.encode(c0, c1, p.fee, p.tickSpacing, p.hooks));
    }

    /// @dev Exec pools: 1 … 8, declared fill >= $500 (K.MIN_POOL_FILL_USD), initialized in the PoolManager (sqrtP != 0),
    ///      poolIds UNIQUE.
    function _checkPoolsShape(address c0, address c1, PoolSpec[] memory pools) internal view {
        if (pools.length == 0 || pools.length > K.MAX_POOLS) revert BadPairEntry();
        for (uint256 i; i < pools.length; ++i) {
            if (pools[i].fillUsd < K.MIN_POOL_FILL_USD) revert BadPairEntry();
            bytes32 id = poolIdOf(c0, c1, pools[i]);
            for (uint256 j; j < i; ++j) {
                if (poolIdOf(c0, c1, pools[j]) == id) revert BadPairEntry();
            }
            bytes32 st = keccak256(abi.encode(id, POOLS_SLOT));
            if (uint160(uint256(POOL_MANAGER.extsload(st))) == 0) revert BadPairEntry();
        }
    }

    function _order(address c0, address c1) internal pure {
        if (c0 >= c1 || (c0 == address(0) && c1 == K.WETH)) revert BadPairEntry();
    }

    /// @dev v3 pool: factory identity and tokens {a, b} (native → WETH). Returns whether the pool's token0 is NOT `a`.
    function _v3Identity(address pool, address a, address b) internal view returns (bool flip) {
        if (a == address(0)) a = K.WETH;
        if (b == address(0)) b = K.WETH;
        address t0 = IGoatV3PoolObserve(pool).token0();
        address t1 = IGoatV3PoolObserve(pool).token1();
        if (t0 == a && t1 == b) flip = false;
        else if (t0 == b && t1 == a) flip = true;
        else revert BadPairEntry();
        if (IGoatV3Factory(K.V3_FACTORY).getPool(t0, t1, IGoatV3PoolObserve(pool).fee()) != pool) revert BadPairEntry();
    }

    /// @dev pokePool must be one of the pair's allowed pools; returns that pool's tick spacing.
    function _pokeSpec(address c0, address c1, bytes32 pokePool, PoolSpec[] memory pools) internal pure returns (int24) {
        for (uint256 i; i < pools.length; ++i) {
            if (poolIdOf(c0, c1, pools[i]) == pokePool) return pools[i].tickSpacing;
        }
        revert BadPairEntry();
    }

    /// @dev The ends of the answer bounds lie in the TickMath range and the ratio is < 2^64 (no overflow on reads).
    function _inRange(uint64 u0, uint64 u1, uint8 d0, uint8 d1) internal pure returns (bool) {
        uint256 num = d1 >= d0 ? uint256(u0) * 10 ** (d1 - d0) : uint256(u0);
        uint256 den = d0 > d1 ? uint256(u1) * 10 ** (d0 - d1) : uint256(u1);
        if (num / den >= (1 << 64)) return false;
        uint256 sq = Math.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        return sq >= TickMath.MIN_SQRT_PRICE && sq < TickMath.MAX_SQRT_PRICE;
    }

    // ================================================================== CL ROW

    /**
     * @notice STRUCTURAL entry of a CL row (no usability measure): order, feed rules (live answer within the bounds),
     *         gate, pool shape, decimals, session / multiplier flags, price range, source kind and identity.
     */
    function entryCl(address c0, address c1, PairConfig memory cfg) public view returns (PairEntry memory e) {
        _order(c0, c1);
        _feed(cfg.feed0);
        _feed(cfg.feed1);
        if (cfg.gate < K.GATE_MIN || cfg.gate > K.GATE_MAX) revert BadPairEntry();
        _checkPoolsShape(c0, c1, cfg.pools);
        (e.feed0, e.maxAge0, e.min0, e.max0) = (cfg.feed0.feed, cfg.feed0.maxAge, cfg.feed0.minAnswer, cfg.feed0.maxAnswer);
        (e.feed1, e.maxAge1, e.min1, e.max1) = (cfg.feed1.feed, cfg.feed1.maxAge, cfg.feed1.minAnswer, cfg.feed1.maxAnswer);
        e.gate = cfg.gate;
        e.dec0 = _decimals(c0);
        e.dec1 = _decimals(c1);
        e.flags0 = _flags(cfg.feed0, c0);
        e.flags1 = _flags(cfg.feed1, c1);
        if (!_inRange(e.min0, e.max1, e.dec0, e.dec1) || !_inRange(e.max0, e.min1, e.dec0, e.dec1)) revert BadPairEntry();

        uint8 kind = cfg.source.kind;
        // The second leg exists only on CL_V3DERIVED (never junk in another kind's semantic hash).
        if (kind != K.SRC_CL_V3DERIVED && cfg.source.v3Pool2 != address(0)) revert BadPairEntry();
        if (kind == K.SRC_NONE) {
            if (cfg.source.v3Pool != address(0) || cfg.source.pokePool != 0 || cfg.source.vetoTicks != 0) {
                revert BadPairEntry();
            }
            return e;
        }
        if (cfg.source.vetoTicks < cfg.gate || cfg.source.vetoTicks > K.VETO_TICKS_MAX) revert BadPairEntry();
        e.vetoTicks = cfg.source.vetoTicks;
        if (kind == K.SRC_CL_V3) {
            if (cfg.source.pokePool != 0) revert BadPairEntry();
            e.vetoPool = cfg.source.v3Pool;
            e.vetoFlip = _v3Identity(cfg.source.v3Pool, c0, c1);
        } else if (kind == K.SRC_CL_POKE) {
            if (cfg.source.v3Pool != address(0)) revert BadPairEntry();
            _pokeSpec(c0, c1, cfg.source.pokePool, cfg.pools);
        } else if (kind == K.SRC_CL_V3DERIVED) {
            _pathSpec(c0, c1, cfg, e);
        } else {
            revert BadPairEntry();
        }
        e.srcKind = kind;
    }

    /// @notice FULL listing check of a CL row: the structural entry plus source and pool usability.
    function validateCl(address c0, address c1, PairConfig memory cfg) external view returns (PairEntry memory e) {
        e = entryCl(c0, c1, cfg);
        Px memory px = _clPx(cfg, e);
        _checkExecPools(c0, c1, cfg.pools, px);
        if (e.srcKind == K.SRC_NONE) return e;
        // At listing the source must agree with the feed anchor within the bound of `vetoOf`'s AnchorVetoed rule.
        (, int24 fa) = GoatAnchorLib.pairSqrtPrice(px.usd0, px.usd1, e.dec0, e.dec1);
        if (e.srcKind == K.SRC_CL_V3) {
            _v3SourceUsable(e.vetoPool, cfg.gate);
            _agree(fa, GoatAnchorLib.twapTick(e.vetoPool, K.VETO_WINDOW, e.vetoFlip), e.vetoTicks);
            if (_v3SourceUsd(e.vetoPool, e.vetoFlip, px) < K.MIN_SOURCE_DEPTH_USD) revert SourceUnusable(R_DEPTH);
        } else if (e.srcKind == K.SRC_CL_V3DERIVED) {
            _pathSourceUsable(e, cfg.gate, fa);
            (uint256 v,,) = _pathDepth(e, c0, px);
            if (v < K.MIN_SOURCE_DEPTH_USD) revert SourceUnusable(R_DEPTH);
        } else {
            _pokeSourceUsable(c0, c1, cfg.source.pokePool, cfg.pools, cfg.gate, px);
            _agree(fa, POKE_ORACLE.consult(cfg.source.pokePool).medMid, e.vetoTicks);
        }
    }

    /// @dev |anchor − source| <= vetoTicks (pair orientation, the same ticks as the run-time `vetoOf`), else R_ANCHOR.
    ///      Operations: a stock (marketHours) feed FREEZES at its last value outside the session while a 24/7 pool keeps
    ///      moving, so seed / queue / apply can fail here with `SourceUnusable(R_ANCHOR)` outside the session. Prepare
    ///      and sign founding and listing transactions during the US session.
    function _agree(int24 anchor, int24 src, int24 vetoTicks) internal pure {
        if (int256(anchor) - int256(src) > vetoTicks || int256(src) - int256(anchor) > vetoTicks) {
            revert SourceUnusable(R_ANCHOR);
        }
    }

    /// @notice Depths of a CL row (USD; no threshold applied): the source VD4 and each allowed pool's walk. For operations.
    function clDepthUsd(address c0, address c1, PairConfig memory cfg)
        external
        view
        returns (uint256 srcUsd, uint256[] memory poolUsd)
    {
        PairEntry memory e = entryCl(c0, c1, cfg);
        Px memory px = _clPx(cfg, e);
        poolUsd = new uint256[](cfg.pools.length);
        for (uint256 i; i < cfg.pools.length; ++i) {
            poolUsd[i] = _poolWalkUsd(c0, c1, cfg.pools[i], px);
        }
        if (e.srcKind == K.SRC_CL_V3) srcUsd = _v3SourceUsd(e.vetoPool, e.vetoFlip, px);
        else if (e.srcKind == K.SRC_CL_V3DERIVED) (srcUsd,,) = _pathDepth(e, c0, px);
        else if (e.srcKind == K.SRC_CL_POKE) srcUsd = _pokeDepthUsd(c0, c1, cfg.source.pokePool, cfg.pools, px);
    }

    function _clPx(PairConfig memory cfg, PairEntry memory e) internal view returns (Px memory px) {
        px.usd0 = _answer(cfg.feed0.feed);
        px.usd1 = _answer(cfg.feed1.feed);
        px.unit0 = 10 ** e.dec0;
        px.unit1 = 10 ** e.dec1;
    }

    function _answer(address feed) internal view returns (uint256) {
        (, int256 a,,,) = IGoatChainlinkFeed(feed).latestRoundData();
        return a > 0 ? uint256(a) : 0;
    }

    // ================================================================== NC ROW

    /**
     * @notice STRUCTURAL entry of an NC row: order, hard feed (live), kind, source feed (V3DERIVED only; ZERO otherwise),
     *         gate, both budget buckets > 0, SR rate in [SR_RATE_MIN, SR_RATE_MAX], pool shape, X feedless and not native,
     *         decimals, source identity (factory; tokens {X, H} or {X, H′}), the ERC-8056 source rule. In the entry the
     *         hard side's feed fields are set and X's are 0.
     */
    function entryNc(address c0, address c1, NcPairConfig memory cfg)
        public
        view
        returns (PairEntry memory e, NcSource memory n)
    {
        _order(c0, c1);
        _feed(cfg.hardFeed);
        if (
            cfg.gate < K.GATE_MIN || cfg.gate > K.GATE_MAX || cfg.capHard == 0 || cfg.capX == 0
                || cfg.slowRate < K.SR_RATE_MIN || cfg.slowRate > K.SR_RATE_MAX
        ) revert BadPairEntry();
        _checkPoolsShape(c0, c1, cfg.pools);
        address x = cfg.ncIs0 ? c0 : c1;
        address h = cfg.ncIs0 ? c1 : c0;
        if (x == address(0)) revert BadPairEntry();
        e.dec0 = _decimals(c0);
        e.dec1 = _decimals(c1);
        e.gate = cfg.gate;
        e.vetoTicks = cfg.gate;
        uint8 hf = _flags(cfg.hardFeed, h);
        if (cfg.ncIs0) {
            (e.feed1, e.maxAge1, e.min1, e.max1, e.flags1) =
                (cfg.hardFeed.feed, cfg.hardFeed.maxAge, cfg.hardFeed.minAnswer, cfg.hardFeed.maxAnswer, hf);
        } else {
            (e.feed0, e.maxAge0, e.min0, e.max0, e.flags0) =
                (cfg.hardFeed.feed, cfg.hardFeed.maxAge, cfg.hardFeed.minAnswer, cfg.hardFeed.maxAnswer, hf);
        }
        n.ncIs0 = cfg.ncIs0;
        n.xMarketHours = cfg.xMarketHours;
        bool zeroSrcFeed = cfg.srcFeed.feed == address(0) && cfg.srcFeed.maxAge == 0 && !cfg.srcFeed.marketHours
            && cfg.srcFeed.minAnswer == 0 && cfg.srcFeed.maxAnswer == 0;
        if (cfg.srcKind == 1) {
            if (!zeroSrcFeed || cfg.pokePool != 0) revert BadPairEntry();
            e.vetoPool = cfg.srcPool;
            e.vetoFlip = _v3Identity(cfg.srcPool, c0, c1);
            e.srcKind = K.SRC_NC_V3SAME;
        } else if (cfg.srcKind == 2) {
            if (cfg.pokePool != 0) revert BadPairEntry();
            _feed(cfg.srcFeed);
            address t0 = IGoatV3PoolObserve(cfg.srcPool).token0();
            address t1 = IGoatV3PoolObserve(cfg.srcPool).token1();
            address hs; // H′
            if (t0 == x) hs = t1;
            else if (t1 == x) hs = t0;
            else revert BadPairEntry();
            _v3Identity(cfg.srcPool, t0, t1);
            // source orientation log(H′ raw / X raw): straight if X is token0, else inverted
            e.vetoPool = cfg.srcPool;
            e.vetoFlip = t1 == x;
            (n.srcFeed, n.srcMaxAge, n.srcMin, n.srcMax) =
                (cfg.srcFeed.feed, cfg.srcFeed.maxAge, cfg.srcFeed.minAnswer, cfg.srcFeed.maxAnswer);
            n.srcDec = _decimals(hs);
            n.srcFlags = _flags(cfg.srcFeed, hs);
            // a multiplier (ERC-8056) hard source token only with the pair's own feed (so a read never mixes tokens)
            if (n.srcFlags & K.FLAG_UI_SCALED != 0 && cfg.srcFeed.feed != cfg.hardFeed.feed) revert BadPairEntry();
            uint8 hDec = cfg.ncIs0 ? e.dec1 : e.dec0;
            if (cfg.srcFeed.feed == cfg.hardFeed.feed) {
                // The run-time shortcut (usdS = usdH) reads only the hard rule, so the source rule must EQUAL it.
                if (
                    cfg.srcFeed.maxAge != cfg.hardFeed.maxAge || cfg.srcFeed.marketHours != cfg.hardFeed.marketHours
                        || cfg.srcFeed.minAnswer != cfg.hardFeed.minAnswer
                        || cfg.srcFeed.maxAnswer != cfg.hardFeed.maxAnswer || n.srcFlags != hf || !_inRange(1, 1, n.srcDec, hDec)
                ) revert BadPairEntry();
            } else if (
                // As in entryCl: every (usdS, usdH) pair within the bounds gives a valid price.
                !_inRange(cfg.srcFeed.minAnswer, cfg.hardFeed.maxAnswer, n.srcDec, hDec)
                    || !_inRange(cfg.srcFeed.maxAnswer, cfg.hardFeed.minAnswer, n.srcDec, hDec)
            ) {
                revert BadPairEntry();
            }
            e.srcKind = K.SRC_NC_V3DERIVED;
        } else if (cfg.srcKind == 3) {
            if (!zeroSrcFeed || cfg.srcPool != address(0)) revert BadPairEntry();
            _pokeSpec(c0, c1, cfg.pokePool, cfg.pools);
            e.srcKind = K.SRC_NC_POKE;
        } else {
            revert BadPairEntry();
        }
    }

    /// @notice FULL listing check of an NC row.
    function validateNc(address c0, address c1, NcPairConfig memory cfg)
        external
        view
        returns (PairEntry memory e, NcSource memory n)
    {
        (e, n) = entryNc(c0, c1, cfg);
        (Px memory px, uint256 srcUsd,) = _ncMeasure(c0, c1, cfg, e, n, true);
        if (srcUsd < K.MIN_SOURCE_DEPTH_USD) revert SourceUnusable(R_DEPTH);
        _checkExecPools(c0, c1, cfg.pools, px);
    }

    /// @notice Depths of an NC row (USD; no threshold, no usability checks) and the anchor used to measure them.
    function ncDepthUsd(address c0, address c1, NcPairConfig memory cfg)
        external
        view
        returns (uint256 srcUsd, uint256[] memory poolUsd, int24 anchorTick)
    {
        (PairEntry memory e, NcSource memory n) = entryNc(c0, c1, cfg);
        Px memory px;
        (px, srcUsd, anchorTick) = _ncMeasure(c0, c1, cfg, e, n, false);
        poolUsd = new uint256[](cfg.pools.length);
        for (uint256 i; i < cfg.pools.length; ++i) {
            poolUsd[i] = _poolWalkUsd(c0, c1, cfg.pools[i], px);
        }
    }

    /**
     * @dev NC measurement: the anchor (V3SAME: the source's TWAP900; V3DERIVED: TWAP900(X/H′) + tick(H′/H); POKE: medMid),
     *      the pair price from it (hard side from the feed, X from the anchor) and the source VD4 (USD). `strict`: the
     *      usability rules (ring, windows, calm listing, extreme price, poke completeness) are applied.
     */
    function _ncMeasure(address c0, address c1, NcPairConfig memory cfg, PairEntry memory e, NcSource memory n, bool strict)
        internal
        view
        returns (Px memory px, uint256 srcUsd, int24 a)
    {
        uint256 usdH = _answer(cfg.hardFeed.feed);
        px.unit0 = 10 ** e.dec0;
        px.unit1 = 10 ** e.dec1;
        // a: the pair tick, log(c1 raw / c0 raw)
        if (e.srcKind == K.SRC_NC_POKE) {
            PokeWindow memory w = POKE_ORACLE.consult(cfg.pokePool);
            if (strict) _pokeCalm(w, cfg.pokePool, cfg.gate);
            a = w.medMid;
        } else {
            if (strict) _v3SourceUsable(e.vetoPool, cfg.gate);
            // TWAP900 in the source orientation (V3SAME: the pair orientation; V3DERIVED: log(H′/X)); orient first, then
            // floor: the same function as the run-time `anchorOf`
            int24 ts = GoatAnchorLib.twapTick(e.vetoPool, K.VETO_WINDOW, e.vetoFlip);
            if (e.srcKind == K.SRC_NC_V3SAME) {
                a = ts;
            } else {
                uint256 usdS = _answer(n.srcFeed);
                (, int24 tf) = GoatAnchorLib.pairSqrtPrice(usdS, usdH, n.srcDec, cfg.ncIs0 ? e.dec1 : e.dec0);
                int256 t = int256(ts) + int256(tf); // log(H raw / X raw)
                a = int24(cfg.ncIs0 ? t : -t);
            }
        }
        if (strict && (a > K.NC_MAX_ABS_TICK || a < -K.NC_MAX_ABS_TICK)) revert SourceUnusable(R_EXTREME);
        // pair price: the hard side from the feed; the X leg is converted per amount into the hard token with the anchor
        // (X's unit price is never rounded, `_legUsd`)
        (px.nc, px.ncIs0, px.a) = (true, cfg.ncIs0, a);
        if (cfg.ncIs0) px.usd1 = usdH;
        else px.usd0 = usdH;
        // source VD4
        if (e.srcKind == K.SRC_NC_POKE) {
            srcUsd = _pokeDepthUsd(c0, c1, cfg.pokePool, cfg.pools, px);
        } else if (e.srcKind == K.SRC_NC_V3SAME) {
            srcUsd = _v3SourceUsd(e.vetoPool, e.vetoFlip, px);
        } else {
            srcUsd = _derivedSourceUsd(e.vetoPool, e.vetoFlip, n);
        }
    }

    /// @dev VD4 of a V3DERIVED source, the X/H′ pool: the H′ leg is valued with the H′ feed, the X leg is converted into
    ///      H′ with the source's own TWAP900 (`xIs1`: X is the source's token1).
    function _derivedSourceUsd(address pool, bool xIs1, NcSource memory n) internal view returns (uint256) {
        (uint256 down0, uint256 up1, uint128 lNow, uint256 lTw) = v3Depth(pool);
        (uint256 cDown, uint256 cUp,,) = _v3Depth(pool, true, K.VD4_TICKS);
        int24 tHx = GoatAnchorLib.twapTick(pool, K.VETO_WINDOW, xIs1); // log(H′ raw / X raw), oriented first
        uint256 usdS = _answer(n.srcFeed);
        uint256 unitS = 10 ** n.srcDec;
        return _min(
            _fac(_derivedVal(down0, up1, xIs1, tHx, usdS, unitS), lTw, lNow), _derivedVal(cDown, cUp, xIs1, tHx, usdS, unitS)
        );
    }

    /// @dev V3DERIVED walk value: down0 is the source's token0 input (X if X is token0, else H′); the X leg is converted into H′.
    function _derivedVal(uint256 down0, uint256 up1, bool xIs1, int24 tHx, uint256 usdS, uint256 unitS)
        internal
        pure
        returns (uint256)
    {
        uint256 vDown = xIs1 ? _usd(down0, usdS, unitS) : _usd(_xToOther(down0, tHx), usdS, unitS);
        uint256 vUp = xIs1 ? _usd(_xToOther(up1, tHx), usdS, unitS) : _usd(up1, usdS, unitS);
        return vDown < vUp ? vDown : vUp;
    }

    // ================================================================== SOURCE USABILITY

    /// @dev v3 source: ring >= 1,800, observe([1800, 900, 60, 10, 0]) works, extreme-price bound (spot and TWAP900),
    ///      calm listing |spot − TWAP900| <= G. Returns the TWAP900 and the spot tick in v3 orientation.
    function _v3SourceUsable(address pool, int24 g) internal view returns (int24 t900, int24 spot) {
        (t900, spot) = _v3SourceStruct(pool, K.MIN_SOURCE_CARDINALITY);
        if (int256(spot) - int256(t900) > g || int256(t900) - int256(spot) > g) revert SourceUnusable(R_CALM);
    }

    /// @dev `_v3SourceUsable` without the calm check, with the ring floor as a parameter (1,800 for a single source;
    ///      1,801 for a CL_V3DERIVED leg, whose calm is checked on the path): CURRENT ring, observe([1800, 900, 60, 10, 0])
    ///      and the extreme-price bound on spot and TWAP900 (pool orientation).
    function _v3SourceStruct(address pool, uint16 minCard) internal view returns (int24 t900, int24 spot) {
        uint16 card;
        (, spot,, card,,,) = IGoatV3PoolObserve(pool).slot0();
        if (card < minCard) revert SourceUnusable(R_RING);
        uint32[] memory ago = new uint32[](5);
        (ago[0], ago[1], ago[2], ago[3]) = (K.VD4_TW_WINDOW, K.VETO_WINDOW, K.GATE_TWAP_SLOW, K.GATE_TWAP_FAST);
        try IGoatV3PoolObserve(pool).observe(ago) returns (int56[] memory c, uint160[] memory) {
            if (c.length != 5) revert SourceUnusable(R_OBSERVE);
            int56 d = c[4] - c[1];
            int56 w = int56(uint56(K.VETO_WINDOW));
            int56 t = d / w;
            if (d < 0 && d % w != 0) t--;
            // Range check BEFORE the cast; otherwise a mean wrapped by a non-standard pool (e.g. int24(2^24) == 0) would
            // pass R_EXTREME and R_CALM.
            if (t > K.NC_MAX_ABS_TICK || t < -K.NC_MAX_ABS_TICK) revert SourceUnusable(R_EXTREME);
            t900 = int24(t);
        } catch {
            revert SourceUnusable(R_OBSERVE);
        }
        if (spot > K.NC_MAX_ABS_TICK || spot < -K.NC_MAX_ABS_TICK || t900 > K.NC_MAX_ABS_TICK || t900 < -K.NC_MAX_ABS_TICK)
        {
            revert SourceUnusable(R_EXTREME);
        }
    }

    /// @dev VD4 (USD) of a v3 source holding the pair's tokens: `flip` = the pool's token0 is the pair's currency1.
    function _v3SourceUsd(address pool, bool flip, Px memory px) internal view returns (uint256) {
        (uint256 down0, uint256 up1, uint128 lNow, uint256 lTw) = v3Depth(pool);
        (uint256 cDown, uint256 cUp,,) = _v3Depth(pool, true, K.VD4_TICKS); // segments clipped to L_tw
        // down0: pool token0 = flip ? c1 : c0; up1: pool token1 = flip ? c0 : c1
        return _min(_fac(_minUsd(down0, flip, up1, !flip, px), lTw, lNow), _minUsd(cDown, flip, cUp, !flip, px));
    }

    // ================================================================== CL_V3DERIVED (kind 6)

    /**
     * @dev Structure of the path c0 -> Q -> c1 (`BadPairEntry` on any defect): both legs set, `pokePool` 0; Q = leg 1's
     *      token other than c0 (native -> WETH) and Q in {USDG, WETH}; leg 1 exactly {c0, Q} and leg 2 exactly {Q, c1},
     *      each the factory's canonical pool (`_v3Identity`; Q can never be a pair token: a leg cannot hold one token
     *      twice); fees each in {100, 500, 3000} and summed <= `MAX_LEG_FEE_SUM`. Stores the legs and their hop flips as
     *      the registry reads them: `vetoFlip` = leg 1's token0 is Q, `vetoFlip2` = leg 2's token0 is c1.
     */
    function _pathSpec(address c0, address c1, PairConfig memory cfg, PairEntry memory e) internal view {
        address l1 = cfg.source.v3Pool;
        address l2 = cfg.source.v3Pool2;
        if (cfg.source.pokePool != 0 || l1 == address(0) || l2 == address(0)) revert BadPairEntry();
        address q = _pathQuote(l1, c0);
        (e.vetoPool, e.vetoFlip) = (l1, _v3Identity(l1, c0, q));
        (e.vetoPool2, e.vetoFlip2) = (l2, _v3Identity(l2, q, c1));
        uint24 f1 = IGoatV3PoolObserve(l1).fee();
        uint24 f2 = IGoatV3PoolObserve(l2).fee();
        if (!_legFee(f1) || !_legFee(f2) || f1 + f2 > K.MAX_LEG_FEE_SUM) revert BadPairEntry();
    }

    function _legFee(uint24 f) internal pure returns (bool) {
        return f == 100 || f == 500 || f == 3000;
    }

    /// @dev Q = leg 1's token that is not c0 (native -> WETH); `BadPairEntry` unless Q is USDG or WETH. Leg 1's identity
    ///      ({c0, Q}, canonical) is the caller's `_v3Identity`.
    function _pathQuote(address leg1, address c0) internal view returns (address q) {
        address x = c0 == address(0) ? K.WETH : c0;
        address t0 = IGoatV3PoolObserve(leg1).token0();
        q = t0 == x ? IGoatV3PoolObserve(leg1).token1() : t0;
        if (q != K.USDG && q != K.WETH) revert BadPairEntry();
    }

    /**
     * @dev Listing usability of the path: each leg's CURRENT ring >= 1,801, observe([1800, 900, 60, 10, 0]) and the
     *      extreme-price bound (`_v3SourceStruct`; no per-leg calm check: a common move of Q shifts both legs and cancels
     *      out in the path); then, on `vetoOf`'s own path values: the extreme-price bound on TWAP900 and spot
     *      (`R_EXTREME`), calm |spot - TWAP900| <= G (`R_CALM`) and agreement |feed anchor - TWAP900| <= K (`R_ANCHOR`).
     */
    function _pathSourceUsable(PairEntry memory e, int24 g, int24 fa) internal view {
        _v3SourceStruct(e.vetoPool, K.MIN_LEG_CARDINALITY);
        _v3SourceStruct(e.vetoPool2, K.MIN_LEG_CARDINALITY);
        (int256 t900,,) = GoatAnchorLib.pathTwapRaw(
            e.vetoPool, e.vetoFlip, e.vetoPool2, e.vetoFlip2, K.VETO_WINDOW, K.GATE_TWAP_SLOW, K.GATE_TWAP_FAST
        );
        (uint160 sa,,,,,,) = IGoatV3PoolObserve(e.vetoPool).slot0();
        (uint160 sb,,,,,,) = IGoatV3PoolObserve(e.vetoPool2).slot0();
        int256 spot = GoatAnchorLib.spotTick(sa, e.vetoFlip) + GoatAnchorLib.spotTick(sb, e.vetoFlip2);
        int256 m = K.NC_MAX_ABS_TICK;
        if (t900 > m || t900 < -m || spot > m || spot < -m) revert SourceUnusable(R_EXTREME);
        if (spot - t900 > g || t900 - spot > g) revert SourceUnusable(R_CALM);
        _agree(fa, int24(t900), e.vetoTicks);
    }

    /**
     * @dev Path depth (USD), the "min(VD50_A, VD50_B, H)" rule: `v` = min(VD50 leg 1, VD50 leg 2, H),
     *      H = VD4_1 * VD4_2 / (VD4_1 + VD4_2). VD50: moving the path price D = 100 ticks moves at least one leg by
     *      >= 50 ticks, so the smaller 50-tick leg depth bounds any split from below. H: two legs that both have to stay
     *      moved add up like springs in series. Each leg [VD50, VD4, raw W50, raw W100]; per-leg VD = min(fac * W, W_cap),
     *      the single-source formula. Valued with Chainlink only: the pair token with the row's feed (`px`), Q with
     *      `USDG_USD_FEED` / `ETH_USD_FEED`.
     */
    function _pathDepth(PairEntry memory e, address c0, Px memory px)
        internal
        view
        returns (uint256 v, uint256[4] memory a, uint256[4] memory b)
    {
        address q = _pathQuote(e.vetoPool, c0);
        uint256 usdQ = _answer(q == K.USDG ? K.USDG_USD_FEED : K.ETH_USD_FEED);
        uint256 unitQ = 10 ** _decimals(q);
        // leg 1 {c0, Q}: c0 is its token0 iff the hop is not flipped; leg 2 {Q, c1}: c1 is its token0 iff flipped
        a = _pathLeg(e.vetoPool, !e.vetoFlip, px.usd0, px.unit0, usdQ, unitQ);
        b = _pathLeg(e.vetoPool2, e.vetoFlip2, px.usd1, px.unit1, usdQ, unitQ);
        uint256 s = a[1] + b[1];
        uint256 h = s == 0 ? 0 : FullMath.mulDiv(a[1], b[1], s);
        v = _min(_min(a[0], b[0]), h);
    }

    /// @dev One leg: [VD50, VD4, raw W50, raw W100] (USD); `xIs0`: the leg's token0 is the pair token (else Q).
    function _pathLeg(address pool, bool xIs0, uint256 usdX, uint256 unitX, uint256 usdQ, uint256 unitQ)
        internal
        view
        returns (uint256[4] memory r)
    {
        (uint256 u0, uint256 n0, uint256 u1, uint256 n1) = xIs0 ? (usdX, unitX, usdQ, unitQ) : (usdQ, unitQ, usdX, unitX);
        (r[0], r[2]) = _legVd(pool, K.VD4_LEG_TICKS, u0, n0, u1, n1);
        (r[1], r[3]) = _legVd(pool, K.VD4_TICKS, u0, n0, u1, n1);
    }

    function _legVd(address pool, int24 span, uint256 u0, uint256 n0, uint256 u1, uint256 n1)
        internal
        view
        returns (uint256 vd, uint256 raw)
    {
        (uint256 down0, uint256 up1, uint128 lNow, uint256 lTw) = _v3Depth(pool, false, span);
        (uint256 cDown, uint256 cUp,,) = _v3Depth(pool, true, span);
        raw = _min(_usd(down0, u0, n0), _usd(up1, u1, n1));
        vd = _min(_fac(raw, lTw, lNow), _min(_usd(cDown, u0, n0), _usd(cUp, u1, n1)));
    }

    /// @notice CL_V3DERIVED path depth (USD; no threshold; for operations and keepers): `pathUsd` (the listing rule's
    ///         value) and per leg [VD50, VD4, raw W50, raw W100]. `BadPairEntry` on any other kind.
    function pathDepthUsd(address c0, address c1, PairConfig memory cfg)
        external
        view
        returns (uint256 pathUsd, uint256[4] memory leg1, uint256[4] memory leg2)
    {
        PairEntry memory e = entryCl(c0, c1, cfg);
        if (e.srcKind != K.SRC_CL_V3DERIVED) revert BadPairEntry();
        return _pathDepth(e, c0, _clPx(cfg, e));
    }

    /// @dev POKE source: window 15/15 registered, spread <= G, calm |spot − medMid| <= G, VD4 = min(fac · W, W_cap)
    ///      (fac = min(1, minL / L), W_cap = the walk with segments clipped to minL; see the contract header).
    function _pokeSourceUsable(
        address c0,
        address c1,
        bytes32 pokePool,
        PoolSpec[] memory pools,
        int24 g,
        Px memory px
    ) internal view {
        _pokeCalm(POKE_ORACLE.consult(pokePool), pokePool, g);
        if (_pokeDepthUsd(c0, c1, pokePool, pools, px) < K.MIN_SOURCE_DEPTH_USD) revert SourceUnusable(R_DEPTH);
    }

    /// @dev POKE source listing conditions: window 15/15 registered, spread <= G and calm listing |v4 spot − medMid| <= G.
    function _pokeCalm(PokeWindow memory w, bytes32 pokePool, int24 g) internal view {
        if (w.complete != K.POKE_WINDOW || w.registered != K.POKE_WINDOW) revert SourceUnusable(R_POKE_GAP);
        if (w.spreadMax > g) revert SourceUnusable(R_CALM);
        int256 spot = int24(uint24(uint256(POOL_MANAGER.extsload(keccak256(abi.encode(pokePool, POOLS_SLOT)))) >> 160));
        if (spot - w.medMid > g || w.medMid - spot > g) revert SourceUnusable(R_CALM);
    }

    function _pokeDepthUsd(address c0, address c1, bytes32 pokePool, PoolSpec[] memory pools, Px memory px)
        internal
        view
        returns (uint256)
    {
        int24 ts = _pokeSpec(c0, c1, pokePool, pools);
        uint128 minL = POKE_ORACLE.consult(pokePool).minL;
        (uint256 down0, uint256 up1, uint128 lNow) = v4Depth(pokePool, ts);
        (uint256 cDown, uint256 cUp,) = _v4Depth(pokePool, ts, minL); // segments clipped to minL
        return _min(_fac(_minUsd(down0, false, up1, true, px), minL, lNow), _minUsd(cDown, false, cUp, true, px));
    }

    /// @dev Each exec pool: ±100-tick walk >= $500 (K.MIN_POOL_FILL_USD), valued at the pair price.
    function _checkExecPools(address c0, address c1, PoolSpec[] memory pools, Px memory px) internal view {
        for (uint256 i; i < pools.length; ++i) {
            if (_poolWalkUsd(c0, c1, pools[i], px) < K.MIN_POOL_FILL_USD) revert SourceUnusable(R_POOL_WALK);
        }
    }

    function _poolWalkUsd(address c0, address c1, PoolSpec memory p, Px memory px) internal view returns (uint256) {
        (uint256 down0, uint256 up1,) = v4Depth(poolIdOf(c0, c1, p), p.tickSpacing);
        return _minUsd(down0, false, up1, true, px);
    }
}
