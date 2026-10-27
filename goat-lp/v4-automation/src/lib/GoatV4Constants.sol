// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @notice Robinhood Chain (4663) fixed addresses and compile-time constants shared by the contracts. There are no
 *         setters; changing a value needs a new deployment.
 */
library GoatV4Constants {
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Upgradeable EIP-1967 proxy (not WETH9; its admin can change its behaviour): a trust assumption, see `IGoatWeth`.
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address internal constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    /// @dev v3 WETH/USDG 0.01% pool (`factory.getPool(WETH, USDG, 100)`): the V3 source of the founding ETH/USDG and
    ///      WETH/USDG rows. Not read in src (row data).
    address internal constant VETO_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    /// @dev Uniswap v3 factory (4663); a source pool's identity is confirmed with `getPool`. Enabled fee tiers 100/500/3000/10000.
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    /// @dev Gate G is set per pair in `GoatV4PairRegistry` (100 in the founding ETH/USDG entry).

    /// @dev The PoolManager protocol fee can be at most 1000 pips (0.1%) per direction. The floor ALWAYS deducts this
    ///      share; it is not read in the transaction (general floor policy).
    uint24 internal constant PROTOCOL_FEE_HEADROOM_PIPS = 1000;

    // ---------------------------------------------------------------- founding hook allowlist
    // One entry: FablesRampETH, on the ETH (native)/USDG pool only.
    address internal constant FOUNDING_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    bytes32 internal constant FOUNDING_POOL_ID = 0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551;
    bytes32 internal constant FOUNDING_CODEHASH = 0x0430617b26dfc5c3f6be1e1733304c6050c6b6ba9d0fb950b57070b5b2a96db4;
    int24 internal constant FOUNDING_TICK_SPACING = 10;
    /// @dev The hook's fee cap compiled into its bytecode (immutable). Checked when the entry is seeded or listed.
    uint24 internal constant FOUNDING_ABS_MAX_FEE = 20_000;
    /// @dev Default pinned cap of the founding entry. The entry is seeded by `registry.seedFoundingHooks(live maxFee)`,
    ///      so this value is not read in src.
    uint24 internal constant FOUNDING_PINNED_FEE = 6000;
    /// @dev The owner's slippage cap on this pool. Total tolerance = the hook's fixed fee ceiling (60 bps =
    ///      `FOUNDING_FEE_CEILING`, 6000 pips) + about 40 bps.
    uint16 internal constant FOUNDING_MAX_SLIPPAGE_BPS = 40;
    /// @dev Kind-1 entry values: `feeCeiling` 6000 clamps any user max; `requiredBits` = the low 14 bits of the hook
    ///      address (0x06a8…6080 & 0x3FFF).
    uint24 internal constant FOUNDING_FEE_CEILING = 6000;
    uint16 internal constant FOUNDING_REQUIRED_BITS = 0x2080;

    // ---------------------------------------------------------------- hook entry framework
    /// @dev Upper bound of a user-signed max swap fee (100,000 pips = 10 %); kinds 3 / 4 clamp `feeCeiling` to it. Read by
    ///      the registry (entry ceilings) and the Steward (`maxSwapFeePips`).
    uint24 internal constant MAX_USER_SWAP_FEE = 100_000;
    /// @dev An entry pool needs a ±100-tick walk AND a listed `fillUsd` of at least $4,000 at queue, apply and seed. The
    ///      same value as `MIN_SOURCE_DEPTH_USD`.
    uint32 internal constant ENTRY_MIN_WALK_USD = 4_000;
    /// @dev Kind 4: the only admitted PonsV2MemeHook runtime.
    bytes32 internal constant KIND4_CODEHASH = 0xc21b1e6c1b45403e81a581f22ed6d9c747997af1cfdac1b1dc9f4b1d346a10db;
    /// @dev Kind 4: `launches(bytes32)` of the pinned runtime, read with a fixed gas stipend; the record is 13 ABI words
    ///      (416 B): word 0 registered, 2 memecoin, 7 creatorTaxBps (c), 10 hookFeeBps (h).
    bytes4 internal constant KIND4_LAUNCHES_SELECTOR = 0xad091230;
    uint256 internal constant KIND4_LAUNCHES_GAS = 40_000;
    uint256 internal constant KIND4_LAUNCHES_SIZE = 416;

    // ---------------------------------------------------------------- founding red list
    /// @dev RED_HOOK: a hook refused from the start.
    address internal constant RED_FOUNDING_HOOK = 0xc52fc52698479E42F0dA9a8a75296EC3871454c0;
    /// @dev RED_TOKEN: FUNI (ERC-404; paying it out can exhaust the gas limit, on hookless pools too).
    address internal constant RED_FOUNDING_TOKEN = 0xA65D0267c8637fcC46fF91E48De766721c750FE3;
    /// @dev RED_CODEHASH: a runtime shared by a family of hooks.
    bytes32 internal constant RED_FOUNDING_CODEHASH_A = 0x8c522be50541ce573326359be951707cca6bef398911a822c94df7b6886dae60;
    /// @dev RED_CODEHASH: a second refused runtime.
    bytes32 internal constant RED_FOUNDING_CODEHASH_B = 0xa0a51b6d7da272dc55d59176390a3df328612bd4c006a4cda944879021f78e61;

    // ---------------------------------------------------------------- pair table and meter (shared by both)
    int24 internal constant GATE_MIN = 100;
    int24 internal constant GATE_MAX = 140;
    int24 internal constant VETO_TICKS_MAX = 300;
    uint32 internal constant MIN_FEED_AGE = 1 hours;
    uint32 internal constant MAX_FEED_AGE = 25 hours;
    uint64 internal constant BAD_ROUND_CEILING = 1_000_000e8;
    uint8 internal constant MAX_TOKEN_DECIMALS = 30;
    uint256 internal constant MAX_POOLS = 8;
    /// @dev Exec-pool floor (whole USD): every listed pool needs a declared `fillUsd` >= this value and a measured
    ///      ±100-tick walk >= this value (meter `_checkPoolsShape` / `_checkExecPools`, `R_POOL_WALK`).
    uint32 internal constant MIN_POOL_FILL_USD = 500;
    /// @dev Source TWAP windows and the extreme-price bound (|tick| <= NC_MAX_ABS_TICK).
    uint32 internal constant VETO_WINDOW = 900;
    uint32 internal constant GATE_TWAP_SLOW = 60;
    uint32 internal constant GATE_TWAP_FAST = 10;
    int24 internal constant NC_MAX_ABS_TICK = 800_000;
    /// @dev VD4 (the ±100-tick walk across initialized ticks × a time weight) and source usability.
    int24 internal constant VD4_TICKS = 100;
    uint32 internal constant VD4_TW_WINDOW = 1800;
    uint256 internal constant MAX_WALK_TICKS = 256;
    /// @dev Source depth floor (USD): a V3 / POKE source's VD4, or a CL_V3DERIVED path's min(VD50_1, VD50_2, H). VD4 is
    ///      the only depth rule.
    uint256 internal constant MIN_SOURCE_DEPTH_USD = 4_000;
    /// @dev A pre-filter, NOT a guarantee: with at most one observation per second N slots cover only N − 1 s, so a ring
    ///      of 1,800 does not always satisfy `observe(VD4_TW_WINDOW = 1800)`. The binding check is the meter's own
    ///      `observe([1800, 900, 60, 10, 0])` call (try/catch -> `SourceUnusable(R_OBSERVE)`, fail-closed, only at
    ///      listing / seeding). At run time the registry reads only 900 s (`VETO_WINDOW`) and shorter windows, which a
    ///      ring of 1,800 always covers. Raising this to 1,801 would only exclude sources with exactly 1,800 slots.
    uint16 internal constant MIN_SOURCE_CARDINALITY = 1800;
    /// @dev Poke window: the last 15 complete slots, EACH with a registered poke.
    uint256 internal constant POKE_WINDOW = 15;
    uint8 internal constant FLAG_MARKET_HOURS = 1;
    uint8 internal constant FLAG_UI_SCALED = 2;
    /// @dev Slow reference: rate range (ticks per hour) and the longest time counted between pokes (a longer gap is
    ///      forfeited: it cannot be saved up and spent in a single poke).
    uint16 internal constant SR_RATE_MIN = 150;
    uint16 internal constant SR_RATE_MAX = 4000;
    uint256 internal constant SR_MAX_DT = 300;
    /// @dev Combined source-kind encoding (`PairEntry.srcKind`).
    uint8 internal constant SRC_NONE = 0;
    uint8 internal constant SRC_CL_V3 = 1;
    uint8 internal constant SRC_CL_POKE = 2;
    uint8 internal constant SRC_NC_V3SAME = 3;
    uint8 internal constant SRC_NC_V3DERIVED = 4;
    uint8 internal constant SRC_NC_POKE = 5;
    /// @dev CL row whose pool-based check is the path c0 -> Q -> c1 over two canonical v3 legs sharing Q (USDG or
    ///      WETH). Numbered after the NC kinds: CL vs NC is the explicit set {3, 4, 5} (`GoatV4PairRegistry._isNc`),
    ///      never an ordering of `srcKind`.
    uint8 internal constant SRC_CL_V3DERIVED = 6;
    /// @dev A leg's CURRENT ring. With at most one observation per second N slots cover N - 1 s, so 1,801 slots
    ///      guarantee the listing's observe(1800) by construction (MIN_SOURCE_CARDINALITY is only a pre-filter).
    uint16 internal constant MIN_LEG_CARDINALITY = 1801;
    /// @dev Half of VD4_TICKS. Moving the path D ticks moves one leg by at least D / 2, so the path's push depth is the
    ///      smaller leg depth over ±D/2.
    int24 internal constant VD4_LEG_TICKS = 50;
    /// @dev Each leg's fee is 100, 500 or 3000 pips and the two fees sum to at most this (it bounds how far the path
    ///      price can drift inside both fee bands).
    uint24 internal constant MAX_LEG_FEE_SUM = 3500;
}
