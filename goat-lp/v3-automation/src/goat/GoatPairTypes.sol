// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Part of Goat LP, not derived from Revert Finance. Row types of GoatPairTable, declared at file level so that the
// founding-row libraries use the same types.

// A token's USD feed (two per pair: token0/USD and token1/USD)
struct FeedCfg {
    address proxy; // Chainlink PROXY, not the aggregator (the aggregator behind it can change without an event)
    uint8 feedDecimals; // must equal proxy.decimals() (checked at listing and at every read)
    uint8 tokenDecimals; // must equal token.decimals() (checked at listing)
    bool marketHours; // US stock 24/5 class: closed on the UTC weekend, needs the weekly open round, holidays
    uint32 maxAge; // the feed's own heartbeat plus a margin (seconds)
    int64 minAnswer; // in feed decimals; answers outside [minAnswer, maxAnswer] fail closed (bad round, rescale)
    int64 maxAnswer;
}

struct PairCfg {
    FeedCfg feed0; // token0/USD
    FeedCfg feed1; // token1/USD
    address vetoPool; // v3 pool of the same pair for the 900 s TWAP veto; REQUIRED (address(0) is rejected)
    uint16 gate; // G for pools with fee <= 0.3%: |spot - anchor| <= gate, inclusive (ticks)
    uint16 gateHighFee; // G for pools with fee > 0.3% (1%, wider no-arbitrage band); 0 = tier not covered
}

struct PairRow {
    address token0;
    address token1;
    PairCfg cfg;
}

// A pair row without a Chainlink price for the pair (NC row). Swap flows can run on any pair with a usable TWAP source;
// Chainlink is optional per row. The anchor is the 900 s TWAP of a pinned v3 REFERENCE pool of the same pair (as in
// Revert, a pool TWAP; in addition the short-TWAP and source spot gate, the execution gate and the floor from the
// anchor apply). Each pair has a leaky swap budget (SwapBudget) that limits the swap volume priced from the reference
// pool: the burst is the configured cap and it refills over SWAP_CAP_WINDOW. The budget is counted in the pair's "hard"
// leg (the token with a Chainlink price).
struct NcCfg {
    address refPool; // pinned v3 reference pool of THIS pair (cardinality >= 1,800, depth >= MIN_VETO_DEPTH_USD)
    uint16 gate; // G for execution tiers with fee <= 0.3% (ticks)
    uint16 gateHighFee; // G for the 1% tier (0 = not covered)
    bool capIn0; // budget unit: true = raw token0, false = raw token1; must be the hard leg (Chainlink price)
    bool marketHours; // official stock token or a stock hard feed: the calendar (weekend, closed hours) fails closed
    // speed of the slow reference (SR, a price speed limit): SR follows the reference's 900 s TWAP by at most slowRate
    // ticks per hour; within [150, 4000], set per row
    uint16 slowRate;
    uint128 cap; // initial burst (raw hard-leg units); 0 is rejected (to close swaps: lowerSwapCap(..., 0, 0))
    // the X leg's own budget, in raw units of X (NO conversion at the anchor price); 0 is not accepted
    uint128 capX;
    FeedCfg hardFeed; // hard leg's Chainlink feed, used ONLY to value the depth (VD4) at listing
}

struct NcRow {
    address token0;
    address token1;
    NcCfg cfg;
}

// Per-pair swap budget, kept apart from the row (changing a budget does not change the row). cap: 0 = swap flows
// CLOSED, type(uint128).max = UNLIMITED (no accounting, no writes), otherwise a leaky bucket (used, at). Each pair has
// TWO budgets: hard-leg input in swapBudget (raw hard units) and X input in swapBudgetX (raw X units); on a CL row both
// are 0 or UNLIMITED.
struct SwapBudget {
    uint128 cap;
    uint128 used;
    uint64 at;
}
