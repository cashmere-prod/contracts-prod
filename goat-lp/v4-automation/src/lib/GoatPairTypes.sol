// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// GoatPairTypes: types shared by the pair table (`GoatV4PairRegistry`) and the meter (`GoatV4SourceMeter`). The
// founding pair data uses the same types.

/// @notice USD feed rule of one currency. Answers have 8 decimals (`decimals() == 8` at listing and on every read).
struct FeedRule {
    /// @dev Chainlink proxy address (not the aggregator; the proxy is pinned).
    address feed;
    /// @dev Maximum age (s): the feed's own heartbeat plus a margin. Registry upper bound `MAX_FEED_AGE` (25 h).
    uint32 maxAge;
    /// @dev Stock/RWA feed (US stock 24/5 calendar): fail-closed at the weekly close, in the first hour after the
    ///      reopening, and while relying on a round written before this week's open.
    bool marketHours;
    /// @dev Lower answer bound (8 decimals, > 0).
    uint64 minAnswer;
    /// @dev Upper answer bound (8 decimals); cannot exceed `BAD_ROUND_CEILING` ($1,000,000): an early filter for broken rounds.
    uint64 maxAnswer;
}

/// @notice An ALLOWED v4 pool of the pair: the key fields the pair does not fix, and the measured fill depth. On a pool
///         outside the list, swap configs and runs revert `PoolNotAllowed`; withdraw-only exits also run unlisted on
///         hookless static pools.
struct PoolSpec {
    /// @dev `PoolKey.fee`: a static fee or the dynamic-fee flag (0x800000, an allowlisted hooked pool).
    uint24 fee;
    int24 tickSpacing;
    address hooks;
    /// @dev MEASURED: the swap fillable from spot to anchor ∓ G, the smaller of the two directions (whole USD).
    ///      Informational (keeper / frontend size warning); on chain only its lower bound (`MIN_POOL_FILL_USD`) and the
    ///      ±100-tick walk are enforced. NOT semantic: refreshing it does not bump the pair version.
    uint32 fillUsd;
}

/// @notice Pool-based price source of a Chainlink (CL) pair. `kind`: 0 NONE (withdraw-only pair), 1 V3 (a v3 pool of
///         the same pair; K, short-TWAP and source-spot checks), 2 POKE (a listed v4 pool of the pair tracked by our
///         poke oracle; K against the medians, the newest buckets' lo/hi against the gate), 6 V3DERIVED (the path
///         c0 -> Q -> c1 over two canonical v3 legs sharing Q in {USDG, WETH}; the kind-1 checks on the path price).
struct SourceSpec {
    uint8 kind;
    /// @dev kind 1: the v3 pool (factory identity; its tokens are the pair's tokens, native → WETH). 0 for other kinds.
    address v3Pool;
    /// @dev kind 2: the poolId tracked by the poke oracle; must be one of the pair's `pools[]`. 0 for other kinds.
    bytes32 pokePool;
    /// @dev K (ticks): |anchor − TWAP900| (V3) or |anchor − medMid| (POKE) <= K; G <= K <= 300. 0 for NONE.
    int24 vetoTicks;
    /// @dev kind 6 (CL_V3DERIVED): the Q -> c1 leg, canonical v3 pool {Q, c1} (native -> WETH); `v3Pool` is then the
    ///      c0 -> Q leg {c0, Q}, Q in {USDG, WETH}, and `pokePool` is 0. Every other kind: 0 (`BadPairEntry` otherwise).
    address v3Pool2;
}

/// @notice Chainlink anchor, source, gate and pool rules of a v4 currency pair (currency0 < currency1; native =
///         address(0)): a CL row.
struct PairConfig {
    FeedRule feed0;
    FeedRule feed1;
    /// @dev Gate G (ticks): |spot − anchor| <= G, in [GATE_MIN, GATE_MAX].
    int24 gate;
    SourceSpec source;
    /// @dev Allowed v4 pools (1 … `MAX_POOLS`).
    PoolSpec[] pools;
}

/// @notice Pair of a currency X WITHOUT Chainlink (an NC row). The other side H has Chainlink (the hard side: the
///         budget unit and the USD view). The anchor comes from the TWAP source; swap flows are budgeted.
struct NcPairConfig {
    /// @dev Chainlink rule of the hard currency H.
    FeedRule hardFeed;
    /// @dev Whether X is currency0 (else currency1).
    bool ncIs0;
    /// @dev 1 V3SAME (a v3 pool of the same pair), 2 V3DERIVED (an X/H′ v3 pool × the H′/H feed ratio), 3 POKE (poke median).
    uint8 srcKind;
    /// @dev 1: the same pair's v3 pool; 2: the X/H′ v3 pool. 0 for 3.
    address srcPool;
    /// @dev 3: the poolId tracked by the poke oracle, one of `pools[]`. 0 for 1 and 2.
    bytes32 pokePool;
    /// @dev 2: the feed rule of H′. Must be all zero for 1 and 3.
    FeedRule srcFeed;
    /// @dev X is a feedless official stock token: the anchor follows the US session calendar (no round check).
    bool xMarketHours;
    /// @dev Gate G (ticks): [GATE_MIN, GATE_MAX].
    int24 gate;
    /// @dev Initial budget (burst) in H's raw units; 0 is refused. NOT semantic. `type(uint128).max` = UNLIMITED (the
    ///      default for the founding NC rows).
    uint128 capHard;
    /// @dev A SEPARATE bucket for the X leg, in X's OWN raw units (never converted with the anchor price); 0 is refused;
    ///      may be UNLIMITED. NOT semantic.
    uint128 capX;
    /// @dev Slow reference (SR, the "price speed limit"): follows the source's TWAP900 by at most this many ticks per
    ///      hour ([SR_RATE_MIN, SR_RATE_MAX]). NOT semantic: owner or guardian LOWERS it immediately; a raise waits 24 h.
    uint16 slowRate;
    PoolSpec[] pools;
}

/// @notice Stored entry (5 slots). `gate != 0` <=> the pair is listed. `srcKind` (combined encoding): 0 NONE, 1 CL+V3, 2 CL+POKE,
///         3 NC+V3SAME, 4 NC+V3DERIVED, 5 NC+POKE, 6 CL+V3DERIVED (two v3 legs through Q). On an NC row X's feed fields are 0.
struct PairEntry {
    // slot 0
    address feed0;
    uint32 maxAge0;
    uint8 flags0; // bit0 session rule, bit1 ERC-8056 multiplier rule (detected on chain at listing)
    uint8 dec0; // token decimals (native = 18)
    int24 gate;
    // slot 1
    address feed1;
    uint32 maxAge1;
    uint8 flags1;
    uint8 dec1;
    int24 vetoTicks;
    // slot 2
    uint64 min0;
    uint64 max0;
    uint64 min1;
    uint64 max1;
    // slot 3
    address vetoPool; // v3 source (CL+V3, V3SAME, V3DERIVED); 0 otherwise
    bool vetoFlip; // the v3 source's token order is the inverse of the anchor orientation (V3DERIVED: X is the source's token1)
    uint32 epoch; // entry version (bumped only by a semantic change)
    uint8 srcKind;
    // slot 4 (CL_V3DERIVED only, zero on every other kind). On kind 6 slot 3 holds leg 1: vetoPool = the c0 -> Q leg,
    // vetoFlip = its token0 is Q (hop orientation log(Q raw / c0 raw)).
    address vetoPool2; // the Q -> c1 leg
    bool vetoFlip2; // its token0 is c1 (hop orientation log(c1 raw / Q raw))
}

/// @notice Source-specific fields of an NC row (outside `PairEntry`). The POKE pool (CL and NC) has its own registry mapping.
struct NcSource {
    // slot 0
    address srcFeed; // V3DERIVED: the H′ feed
    uint32 srcMaxAge;
    uint8 srcFlags;
    uint8 srcDec; // decimals of H′
    bool ncIs0;
    bool xMarketHours;
    // slot 1
    uint64 srcMin;
    uint64 srcMax;
}

/// @notice Leaky swap budget per pair, two buckets. Each bucket: `cap` 0 = swap flows OFF, `type(uint128).max` =
///         UNLIMITED (no accounting), otherwise a bucket (burst `cap`, fully drained in `SWAP_CAP_WINDOW` s). The hard
///         bucket counts in H's raw units, the X bucket in X's OWN raw units (the principal legs are counted separately;
///         the anchor price is not used in the accounting). CL row: both buckets UNLIMITED or both 0. Kept apart from
///         the semantic entry.
struct SwapBudget {
    uint128 cap;
    uint128 used;
    uint64 at;
    uint128 capX;
    uint128 usedX;
    uint64 atX;
}

/// @notice Slow reference (SR; NC rows only): a trail that follows the source's TWAP900 (NC POKE: medMid) by at most
///         `rate` ticks per hour. `at`: the time the allowance is "paid" up to (rounded up; idle time beyond `SR_MAX_DT` is forfeited).
struct NcSlow {
    int24 tick;
    uint32 at;
    uint16 rate;
}

/// @notice Hook entry, keyed by poolId in `GoatV4PairRegistry`. Shared by the registry and the Steward. Three slots.
///         An entry exists <=> `codehash != 0` (every kind).
///         kind 1 SIGNED_FEE, 2 EXTERNAL_VENUE, 3 CONST_TAX, 4 PONSV2_TERMS (0 and 5-255 refused).
struct HookEntry {
    // slot 0
    bytes32 codehash; // the hook's pinned runtime hash (re-checked on every read)
    // slot 1
    uint24 pinnedFee; // k1 pinned cap (== live maxFee at add); k3 composite fee; k4 key.fee + 100(h + c); k2 0
    uint24 absMaxFee; // k1 ABSOLUTE_MAX_FEE(); k3 == pinnedFee; k4 key.fee + 200_000; k2 0
    uint16 maxSlippageBps; // 10 ... 100
    uint8 kind;
    uint24 feeCeiling; // k1/k3/k4: clamp of the user max; k2 0
    uint16 requiredBits; // uint160(hook) & 0x3FFF == requiredBits (every kind)
    // slot 2
    address taxRecipient; // k3: bound recipient or the hook itself; 0 for kinds 1, 2, 4
    uint16 recipientCodeOffset; // k3: byte offset of taxRecipient in the pinned runtime; 0 otherwise and for the self case
}
