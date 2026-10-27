// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {GoatAnchorLib} from "./lib/GoatAnchorLib.sol";
import {GoatV4Constants as K} from "./lib/GoatV4Constants.sol";
import {GoatPonsV2Terms} from "./lib/GoatPonsV2Terms.sol";
import {
    PoolSpec, PairConfig, NcPairConfig, PairEntry, NcSource, SwapBudget, NcSlow, HookEntry
} from "./lib/GoatPairTypes.sol";
import {
    IGoatChainlinkFeed,
    IGoatFeeCapHook,
    IGoatV3PoolObserve,
    IGoatPokeOracle,
    IGoatSourceMeter,
    IGoatStewardRegistryRef,
    PokeWindow
} from "./interfaces/GoatV4External.sol";
import "./lib/GoatV4Errors.sol";

/// @dev The Steward views read by `bindSteward` (the Ownable owner and the Engine's fee recipient).
interface IGoatStewardBindRef {
    function owner() external view returns (address);
    function feeRecipient() external view returns (address);
}

/**
 * @notice Pair table. Per pair: the anchor (Chainlink, or on an NC row a TWAP source), the price source (a v3 pool or the
 *         poke oracle), gate G, the ALLOWED v4 pools, the entry VERSION (bumped only by a semantic change) and, on NC
 *         rows, a leaky swap BUDGET. `GoatV4Steward` reads it on every config and run; the Engine does not.
 *
 * @dev Swap flows run on every pair with a USABLE TWAP source; Chainlink is optional per row. Row kinds
 *      (`PairEntry.srcKind`): CL+V3, CL+POKE, NC+V3SAME, NC+V3DERIVED, NC+POKE and CL+V3DERIVED (kind 6: two canonical
 *      v3 legs through USDG or WETH; a CL row, since `_isNc` is the set {3, 4, 5}). A CL row without a source is a
 *      withdraw-only pair (`ExitOnlyPair`). NC rows have a per-pair budget for swap flows (two buckets: the hard leg H
 *      and the X leg, each in its own raw units, refilled over 3,600 s); the founding default is UNLIMITED, and the
 *      guardian can lower it to a finite cap at any time. On CL rows the budget is only an ON (unlimited) / OFF (0) switch.
 *
 * @dev Every NC row has a SLOW REFERENCE (SR, the "price speed limit"). The SR follows the source's TWAP900 by at most
 *      `rate` ticks per hour (on V3 kinds only while TWAP60, TWAP10 and spot are within G of TWAP900; on POKE the target
 *      is clamp(SR, medLo, medHi)); a swap flow requires |TWAP900 − SR| <= G (POKE: [medLo, medHi] ⊆ [SR − G, SR + G])
 *      (`VetoSlowFar`). Anyone can poke it; the step is counted on the absolute hour grid, so extra pokes neither speed
 *      it up nor slow it down, and a gap between pokes beyond `SR_MAX_DT` is forfeited. CL rows have no SR.
 *
 * @dev Governance: listing (add or change) waits for the 24-hour timelock, and the meter checks the chain AGAIN at
 *      apply; founding rows are seeded by the owner before the seal (every row passes the meter). REMOVAL, pool removal,
 *      queue cancellation and budget LOWERING are immediate (owner or guardian); a budget RAISE needs the owner and 24 h.
 *
 * @dev Fail-closed: every defect of the anchor read reverts (`NoAnchor`, `NcTwapUnavailable`, `PokeHistoryGap`,
 *      `PokeSpreadWide`); a defect of the source checks reverts `AnchorVetoed` / `VetoTwapFar` / `VetoSpotFar`.
 *      Withdraw-only reads none of them.
 *
 * @dev Structure: no proxy, no delegatecall, no receive/fallback; it holds no tokens.
 */
contract GoatV4PairRegistry is Ownable2Step, ReentrancyGuard {
    // ------------------------------------------------------------------ constants

    int24 public constant GATE_MIN = K.GATE_MIN;
    int24 public constant GATE_MAX = K.GATE_MAX;
    int24 public constant VETO_TICKS_MAX = K.VETO_TICKS_MAX;
    uint32 public constant VETO_WINDOW = K.VETO_WINDOW;
    uint32 public constant GATE_TWAP_SLOW = K.GATE_TWAP_SLOW;
    uint32 public constant GATE_TWAP_FAST = K.GATE_TWAP_FAST;
    uint32 public constant MIN_FEED_AGE = K.MIN_FEED_AGE;
    uint32 public constant MAX_FEED_AGE = K.MAX_FEED_AGE;
    uint64 public constant BAD_ROUND_CEILING = K.BAD_ROUND_CEILING;
    uint32 public constant MIN_POOL_FILL_USD = K.MIN_POOL_FILL_USD;
    int24 public constant NC_MAX_ABS_TICK = K.NC_MAX_ABS_TICK;
    /// @notice A budget bucket drains its whole `cap` burst over this many seconds.
    uint256 public constant SWAP_CAP_WINDOW = 3600;
    /// @notice "UNLIMITED" budget (no accounting): the open state of CL rows; on NC rows the owner's choice of no budget limit.
    uint128 public constant CAP_UNLIMITED = type(uint128).max;
    uint256 internal constant SEQUENCER_GRACE = 600;
    uint256 internal constant TIMELOCK = 24 hours;
    /// @notice A queued action expires after eta + 7 days (inclusive).
    uint256 public constant QUEUE_GRACE = 7 days;
    /// @notice A single `closeMarket` call closes at most 96 hours, and the closure may end at most 168 hours (7 days)
    ///         ahead. A reopening range is also at most 168 hours (loop bound).
    uint256 public constant MAX_CLOSURE_HOURS = 96;
    uint256 public constant MAX_CLOSURE_AHEAD_HOURS = 168;
    uint256 internal constant Q96 = 1 << 96;
    /// @notice Hook entry kinds (0 and 5-255 are refused).
    uint8 public constant KIND_SIGNED_FEE = 1;
    uint8 public constant KIND_EXTERNAL_VENUE = 2;
    uint8 public constant KIND_CONST_TAX = 3;
    uint8 public constant KIND_PONSV2_TERMS = 4;
    /// @notice Upper bound of a user max swap fee (pips); kinds 3 / 4 need `feeCeiling` <= this.
    uint24 public constant MAX_USER_SWAP_FEE = K.MAX_USER_SWAP_FEE;
    /// @notice An entry pool's ±100-tick walk at the anchor AND its listed `fillUsd` must be >= this (whole USD) at queue,
    ///         apply and seed (`EntryTooThin(walk)` otherwise). Admission only: after apply the keeper watches depth.
    uint32 public constant ENTRY_MIN_WALK_USD = K.ENTRY_MIN_WALK_USD;
    /// @notice Kind 4: the only admitted PonsV2MemeHook runtime.
    bytes32 public constant KIND4_CODEHASH = K.KIND4_CODEHASH;
    uint24 internal constant DYN_FEE = 0x800000;
    /// @dev Kinds 3 / 4: the entry pool's `key.fee` is static and at most 1 % (the dynamic flag 0x800000 is above it, so
    ///      one comparison refuses both).
    uint24 internal constant ENTRY_MAX_STATIC_FEE = 10_000;
    int24 internal constant ENTRY_MAX_TICK_SPACING = 200;
    uint16 internal constant ENTRY_MIN_SLIPPAGE_BPS = 10;
    uint16 internal constant ENTRY_MAX_SLIPPAGE_BPS = 100;
    /// @notice Fixed gas forwarded to the `ncFeedsOf` self-call of `_slowFrozen`. The caller must hold enough gas to
    ///         forward all of it (else `SrFeedsGas`), so a call that runs short of gas never reads as "frozen".
    uint256 public constant SR_FEEDS_GAS = 250_000;
    /// @dev Gas cap of the `oraclePaused()` read of a FLAG_UI_SCALED token.
    uint256 internal constant ORACLE_PAUSED_GAS = 30_000;

    /// @notice Not enough gas left to forward `SR_FEEDS_GAS` to the feed self-call.
    error SrFeedsGas();

    // ------------------------------------------------------------------ types

    /// @notice Allowed-pool record: the pair and the pair version it was listed under, and its measured fill.
    struct PoolListing {
        bytes32 pair;
        uint32 epoch;
        uint32 fillUsd;
    }

    /// @notice The listed key's hook, and whether the key is outside the Steward's static listed-path policy
    ///         (`GoatV4StewardCore._poolRule`: tickSpacing > 200, or hookless with a fee above 1 % / the dynamic flag), in
    ///         which case no swap flow can ever use the pool. Written by `_commit` with the listing.
    struct VenueTag {
        address hook;
        bool offPolicy;
    }

    /// @notice Anchor: the pair price (mid), the low / high ticks for the user-favourable floor (they differ only on NC POKE) and the USD view.
    struct Quote {
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 usd0; // 8 decimals, per unit of currency0
        uint256 usd1; // 8 decimals, per unit of currency1
        uint256 unit0; // 10^dec0
        uint256 unit1; // 10^dec1
        int24 tickLo; // POKE NC: medLo (the floor when selling token1)
        int24 tickHi; // POKE NC: medHi (the floor when selling token0)
    }

    // ------------------------------------------------------------------ state

    /// @notice Optional sequencer uptime feed; address(0) = none.
    address public immutable sequencerFeed;
    /// @notice Listing meter (stateless; relied on only at listing).
    IGoatSourceMeter public immutable METER;
    /// @notice Oracle of the POKE sources.
    IGoatPokeOracle public immutable POKE_ORACLE;

    mapping(bytes32 => PairEntry) internal _entries;
    /// @notice Queue id → hash of the queued input (apply needs the SAME input).
    mapping(bytes32 => bytes32) internal _pendingHash;
    /// @notice Queue id → time it was queued.
    mapping(bytes32 => uint256) public queuedAt;
    /// @notice Version counter per pair (NOT deleted on removal).
    mapping(bytes32 => uint32) public pairEpoch;
    /// @notice poolId → allowed-pool record.
    mapping(bytes32 => PoolListing) public poolListing;
    mapping(bytes32 => NcSource) internal _nc;
    /// @notice The tracked pool of a POKE row (CL and NC).
    mapping(bytes32 => bytes32) public pokePoolOf;
    /// @notice Swap budget per pair (kept apart from the semantic entry).
    mapping(bytes32 => SwapBudget) public swapBudget;
    /// @notice Semantic hash (kind, feed rules, gate, source); pools, fill and budget excluded.
    mapping(bytes32 => bytes32) public semHash;
    mapping(bytes32 => bytes32[]) internal _poolsOf;
    /// @notice Slow reference of an NC row (empty on a CL row).
    mapping(bytes32 => NcSlow) public ncSlow;

    address public guardian;
    /// @notice The only Steward that can consume the budget (bound a single time).
    address public steward;
    /// @notice Founding seeding is finished; from then on listing only goes through the timelock.
    bool public foundingSealed;
    /// @notice US market holiday hours: a bitmap by hour index (ts / 3600), 1 = closed. During those hours the anchor of
    ///         EVERY session-bound row (`xMarketHours`, or a hard / source / CL feed with `FLAG_MARKET_HOURS`) reverts
    ///         `NoAnchor`, and the SR of an NC row freezes.
    mapping(uint256 => uint256) public closedHourBits;
    /// @notice Time of the last `closeMarket`: a reopening queued BEFORE it cannot clear it.
    uint256 public lastClosureAt;
    // Appended after the earlier storage layout (slots 0-17 unchanged): redList is slot 18, _hookEntry slot 19.
    /// @notice Red list: kind (`RED_HOOK` 1, `RED_CODEHASH` 2, `RED_TOKEN` 3) -> value -> listed. HOOK and TOKEN values are
    ///         `bytes32(uint256(uint160(a)))`. Read by `checkUnlisted` (every withdraw-only admission that does not go
    ///         through a listed in-policy rule) and by the entry checks (`_validateHookEntry` step 5: HOOK and CODEHASH
    ///         at queue, apply and seed).
    mapping(uint8 => mapping(bytes32 => bool)) public redList;
    /// @notice Hook entries by poolId. Queued by hash: no pending copy is stored.
    mapping(bytes32 => HookEntry) internal _hookEntry;
    /// @notice What `_commit` knew about each listed pool's key, for `_anyVenue` (slot 20, appended after the earlier
    ///         layout). Zero = hookless and inside the Steward's static listed-path policy.
    mapping(bytes32 => VenueTag) internal _venueTag;

    // ------------------------------------------------------------------ events

    event PairQueued(address indexed currency0, address indexed currency1, PairConfig cfg, uint256 eta, bool modifiesListed);
    event PairAdded(address indexed currency0, address indexed currency1, PairConfig cfg, uint32 epoch);
    event NcPairQueued(
        address indexed currency0, address indexed currency1, NcPairConfig cfg, uint256 eta, bool modifiesListed
    );
    event NcPairAdded(address indexed currency0, address indexed currency1, NcPairConfig cfg, uint32 epoch);
    event PairRemoved(address indexed currency0, address indexed currency1);
    event PoolRemoved(bytes32 indexed poolId);
    event GuardianSet(address indexed guardian);
    event StewardBound(address indexed steward);
    event FoundingSealed();
    event QueueCancelled(address indexed currency0, address indexed currency1);
    /// @notice `removePool` deleted the pair's pending CL/NC listing queue.
    event ListingQueueCancelled(bytes32 indexed pairId);
    event SwapCapLowered(address indexed currency0, address indexed currency1, uint128 cap, uint128 capX, address by);
    event SwapCapQueued(address indexed currency0, address indexed currency1, uint128 cap, uint128 capX, uint256 eta);
    event SwapCapRaised(address indexed currency0, address indexed currency1, uint128 cap, uint128 capX);
    event SwapBudgetUsed(address indexed currency0, address indexed currency1, uint256 valueHard, uint256 valueX);
    event NcSlowPoked(address indexed currency0, address indexed currency1, int24 twap, int24 slow);
    event SlowRateLowered(address indexed currency0, address indexed currency1, uint16 rate, address by);
    event SlowRateQueued(address indexed currency0, address indexed currency1, uint16 rate, uint256 eta);
    event SlowRateRaised(address indexed currency0, address indexed currency1, uint16 rate);
    /// @notice Holiday calendar events (the same names and fields as the v3 `GoatPairTable`; hour indexes [from, to)).
    event MarketClosureAdded(uint256 fromHour, uint256 toHour);
    event MarketReopenQueued(uint256 fromHour, uint256 toHour, uint256 eta);
    event MarketReopened(uint256 fromHour, uint256 toHour);
    event MarketReopenCancelled(uint256 fromHour, uint256 toHour);
    /// @notice The queued entry travels in the event (no pending copy in storage).
    event HookEntryQueued(bytes32 indexed poolId, address indexed hook, HookEntry entry, uint256 eta);
    event HookEntryAdded(bytes32 indexed poolId, address indexed hook, HookEntry entry);
    event HookEntryRemoved(bytes32 indexed poolId, address by);
    /// @notice Red list events (topics 0x88f8884e / 0x67c15971 / 0xe61edc39). `by` = the deployer for the four founding entries.
    event RedListAdded(uint8 indexed kind, bytes32 indexed value, address by);
    event RedListQueued(uint8 indexed kind, bytes32 indexed value, bool add, uint256 eta);
    event RedListRemoved(uint8 indexed kind, bytes32 indexed value);

    // ------------------------------------------------------------------ constructor

    constructor(address initialOwner, address sequencerFeed_, address meter_, address pokeOracle_)
        Ownable(initialOwner)
    {
        if (meter_.code.length == 0 || pokeOracle_.code.length == 0) revert BadDeployment();
        if (IGoatSourceMeter(meter_).POKE_ORACLE() != pokeOracle_) revert BadDeployment();
        sequencerFeed = sequencerFeed_;
        METER = IGoatSourceMeter(meter_);
        POKE_ORACLE = IGoatPokeOracle(pokeOracle_);
        // Founding red list (one code hash covers a whole family of hooks).
        _redAdd(RED_HOOK, bytes32(uint256(uint160(K.RED_FOUNDING_HOOK))));
        _redAdd(RED_TOKEN, bytes32(uint256(uint160(K.RED_FOUNDING_TOKEN))));
        _redAdd(RED_CODEHASH, K.RED_FOUNDING_CODEHASH_A);
        _redAdd(RED_CODEHASH, K.RED_FOUNDING_CODEHASH_B);
    }

    // ================================================================== ADMINISTRATION

    /// @notice DISABLED: a table without an owner would be frozen for good.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    modifier onlyPendingOwner() {
        if (pendingOwner() != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        _;
    }

    function transferOwnership(address newOwner) public override onlyOwner nonReentrant {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override onlyPendingOwner nonReentrant {
        super.acceptOwnership();
    }

    function setGuardian(address g) external onlyOwner nonReentrant {
        guardian = g;
        emit GuardianSet(g);
    }

    /// @notice Binds, a single time, the Steward that consumes the budget (it must have code and read this registry). The
    ///         Steward's owner must be this registry's owner, its fee recipient must equal `feeRecipient_` (the owner
    ///         multisig states the treasury it expects), and `runtimeHash` must equal the Steward's LIVE `EXTCODEHASH`,
    ///         so only the expected Steward deployment can be bound.
    function bindSteward(address s, address feeRecipient_, bytes32 runtimeHash) external onlyOwner nonReentrant {
        if (steward != address(0) || s.code.length == 0 || feeRecipient_ == address(0) || s.codehash != runtimeHash) {
            revert BadValue();
        }
        if (
            IGoatStewardRegistryRef(s).REGISTRY() != address(this) || IGoatStewardBindRef(s).owner() != owner()
                || IGoatStewardBindRef(s).feeRecipient() != feeRecipient_
        ) revert BadValue();
        steward = s;
        emit StewardBound(s);
    }

    function pairId(address currency0, address currency1) public pure returns (bytes32) {
        return keccak256(abi.encode(currency0, currency1));
    }

    function _qid(bytes32 tag, bytes32 pid) internal pure returns (bytes32) {
        return keccak256(abi.encode(tag, pid));
    }

    /// @notice v4 poolId = keccak256(abi.encode(PoolKey)).
    function poolIdOf(address currency0, address currency1, PoolSpec memory p) public pure returns (bytes32) {
        return keccak256(abi.encode(currency0, currency1, p.fee, p.tickSpacing, p.hooks));
    }

    // ------------------------------------------------------------------ founding seeding (before the seal)

    /**
     * @notice Founding CL rows, seeded by the owner. Every row passes the meter; a pair that is already listed gives
     *         `BadDeployment`. Can be called in batches to stay within the block gas limit. Closed after the seal.
     */
    function seedFounding(address[] calldata c0, address[] calldata c1, PairConfig[] calldata cfg)
        external
        onlyOwner
        nonReentrant
    {
        if (foundingSealed) revert Sealed();
        if (c0.length != cfg.length || c1.length != cfg.length) revert BadValue();
        for (uint256 i; i < cfg.length; ++i) {
            if (_entries[pairId(c0[i], c1[i])].gate != 0) revert BadDeployment();
            _storeCl(c0[i], c1[i], cfg[i], METER.validateCl(c0[i], c1[i], cfg[i]));
        }
    }

    /// @notice Founding NC rows.
    function seedFoundingNc(address[] calldata c0, address[] calldata c1, NcPairConfig[] calldata cfg)
        external
        onlyOwner
        nonReentrant
    {
        if (foundingSealed) revert Sealed();
        if (c0.length != cfg.length || c1.length != cfg.length) revert BadValue();
        for (uint256 i; i < cfg.length; ++i) {
            if (_entries[pairId(c0[i], c1[i])].gate != 0) revert BadDeployment();
            (PairEntry memory e, NcSource memory n) = METER.validateNc(c0[i], c1[i], cfg[i]);
            _storeNc(c0[i], c1[i], cfg[i], e, n);
        }
    }

    /// @notice Closes seeding for good. The Steward does not accept an unsealed registry. Refused (`BadDeployment`)
    ///         until the founding kind-1 hook entry exists (`seedFoundingHooks`), the same precondition the Steward
    ///         constructor checks, so the irreversible seal cannot come before it.
    function sealFounding() external onlyOwner nonReentrant {
        HookEntry storage f = _hookEntry[K.FOUNDING_POOL_ID];
        if (f.kind != KIND_SIGNED_FEE || f.codehash == bytes32(0)) revert BadDeployment();
        foundingSealed = true;
        emit FoundingSealed();
    }

    // ------------------------------------------------------------------ timelocked listing

    /// @dev Consumes a queue entry: the input hash must match, 24 h must have passed and eta + 7 days must not (inclusive).
    function _consume(bytes32 q, bytes32 h) internal {
        uint256 t = queuedAt[q];
        if (t == 0 || _pendingHash[q] != h) revert NotQueued();
        if (block.timestamp < t + TIMELOCK) revert TimelockNotReady();
        if (block.timestamp > t + TIMELOCK + QUEUE_GRACE) revert TimelockExpired();
        _drop(q);
    }

    function _queue(bytes32 q, bytes32 h) internal returns (uint256 eta) {
        _pendingHash[q] = h;
        queuedAt[q] = block.timestamp;
        eta = block.timestamp + TIMELOCK;
    }

    /// @notice Adding or changing a CL row waits for the 24-hour timelock (the meter runs at queue AND at apply). A pair
    ///         with an NC row cannot be written as CL (`removePair` first).
    function queuePair(address currency0, address currency1, PairConfig calldata cfg) external onlyOwner nonReentrant {
        bytes32 pid = pairId(currency0, currency1);
        _notKind(pid, true);
        METER.validateCl(currency0, currency1, cfg);
        uint256 eta = _queue(_qid("PAIR", pid), keccak256(abi.encode(cfg)));
        emit PairQueued(currency0, currency1, cfg, eta, _entries[pid].gate != 0);
    }

    function applyPair(address currency0, address currency1, PairConfig calldata cfg) external onlyOwner nonReentrant {
        bytes32 pid = pairId(currency0, currency1);
        _consume(_qid("PAIR", pid), keccak256(abi.encode(cfg)));
        _notKind(pid, true);
        _storeCl(currency0, currency1, cfg, METER.validateCl(currency0, currency1, cfg));
    }

    /// @notice Adding or changing an NC row waits for the 24-hour timelock. A pair with a CL row cannot be written as NC.
    function queueNcPair(address currency0, address currency1, NcPairConfig calldata cfg)
        external
        onlyOwner
        nonReentrant
    {
        bytes32 pid = pairId(currency0, currency1);
        _ncRewrite(pid, cfg.ncIs0);
        METER.validateNc(currency0, currency1, cfg);
        uint256 eta = _queue(_qid("NC", pid), keccak256(abi.encode(cfg)));
        emit NcPairQueued(currency0, currency1, cfg, eta, _entries[pid].gate != 0);
    }

    function applyNcPair(address currency0, address currency1, NcPairConfig calldata cfg)
        external
        onlyOwner
        nonReentrant
    {
        bytes32 pid = pairId(currency0, currency1);
        _consume(_qid("NC", pid), keccak256(abi.encode(cfg)));
        _ncRewrite(pid, cfg.ncIs0);
        (PairEntry memory e, NcSource memory n) = METER.validateNc(currency0, currency1, cfg);
        _storeNc(currency0, currency1, cfg, e, n);
    }

    /// @dev NC write: a listed CL pair gives `BadPairEntry`; the hard leg (`ncIs0`) of a listed NC row cannot be flipped
    ///      → `HardLegFixed` (at queue and at apply). To change it: `removePair` + `queueNcPair`.
    function _ncRewrite(bytes32 pid, bool ncIs0) internal view {
        _notKind(pid, false);
        if (_entries[pid].gate != 0 && _nc[pid].ncIs0 != ncIs0) revert HardLegFixed();
    }

    /// @dev NC rows are exactly the kinds {3, 4, 5}; every other kind (0, 1, 2 and 6 = CL_V3DERIVED) is a CL row. Every
    ///      CL/NC branch (`_notKind`, `lowerSwapCap`, `_checkRaise`, `anchorOf`, `ncFeedsOf`) uses this set, never an
    ///      ordering of `srcKind`.
    function _isNc(uint8 k) private pure returns (bool) {
        return k == K.SRC_NC_V3SAME || k == K.SRC_NC_V3DERIVED || k == K.SRC_NC_POKE;
    }

    /// @dev `BadPairEntry` if the listed pair is of the other kind (NC while writing CL, CL while writing NC).
    function _notKind(bytes32 pid, bool writingCl) internal view {
        PairEntry storage e = _entries[pid];
        if (e.gate != 0 && _isNc(e.srcKind) == writingCl) revert BadPairEntry();
    }

    /// @notice Immediate (owner or guardian): deletes the entry, the source, the budget and all of the pair's queues. The
    ///         version counter is kept, so a re-added pair gets a new version. Withdraw-only continues on listed hookless
    ///         static pools. The hook entry and pending HOOK queue of every pool of the last listing are deleted as well.
    function removePair(address currency0, address currency1) external onlyOwnerOrGuardian nonReentrant {
        bytes32 pid = pairId(currency0, currency1);
        bool listed = _entries[pid].gate != 0;
        bytes32[] storage ids = _poolsOf[pid];
        for (uint256 i; i < ids.length; ++i) {
            _dropHookEntry(ids[i]); // before the pair state is deleted
        }
        delete _entries[pid];
        delete _nc[pid];
        delete pokePoolOf[pid];
        delete swapBudget[pid];
        delete semHash[pid];
        delete ncSlow[pid];
        // A no-op removal (nothing listed, nothing queued) emits nothing.
        if (_cancel(pid) || listed) emit PairRemoved(currency0, currency1);
    }

    /// @notice Immediate (owner or guardian): removes one allowed pool from the list. The version does not change. Also
    ///         deletes the pair's PENDING CL/NC listing queue, so a refresh queued earlier with the same hash cannot bring
    ///         the pool back silently under the same version; listing it again needs a new 24-hour queue. Budget and SR
    ///         queues stay. The pool's hook entry and pending HOOK queue are deleted as well.
    function removePool(bytes32 poolId) external onlyOwnerOrGuardian nonReentrant {
        bytes32 pid = poolListing[poolId].pair;
        delete poolListing[poolId];
        _dropHookEntry(poolId);
        bytes32 qp = _qid("PAIR", pid);
        bytes32 qn = _qid("NC", pid);
        if (queuedAt[qp] != 0 || queuedAt[qn] != 0) {
            _drop(qp);
            _drop(qn);
            emit ListingQueueCancelled(pid);
        }
        // Only a listed pool emits (its hook entry / queue drop emits on its own in `_dropHookEntry`).
        if (pid != bytes32(0)) emit PoolRemoved(poolId);
    }

    /// @notice Immediate (owner or guardian): deletes the pair's pending CL / NC / budget / SR-rate queues.
    function cancelQueued(address currency0, address currency1) external onlyOwnerOrGuardian nonReentrant {
        _cancel(pairId(currency0, currency1));
        emit QueueCancelled(currency0, currency1);
    }

    /// @dev Drops the pair's four queues; returns whether any of them was pending.
    function _cancel(bytes32 pid) internal returns (bool any) {
        bytes32[4] memory qs = [_qid("PAIR", pid), _qid("NC", pid), _qid("CAP", pid), _qid("SR", pid)];
        for (uint256 i; i < 4; ++i) {
            if (queuedAt[qs[i]] != 0) any = true;
            _drop(qs[i]);
        }
    }

    function _drop(bytes32 q) internal {
        delete queuedAt[q];
        delete _pendingHash[q];
    }

    // ------------------------------------------------------------------ red list

    uint8 public constant RED_HOOK = 1;
    uint8 public constant RED_CODEHASH = 2;
    uint8 public constant RED_TOKEN = 3;

    /// @dev Queue id of a TOKEN add ("REDADD") or a removal of any kind ("REDDEL"); the id is also the queued hash.
    function _redQ(uint8 kind, bytes32 value, bool add) internal pure returns (bytes32) {
        return _qid(add ? bytes32("REDADD") : bytes32("REDDEL"), keccak256(abi.encode(kind, value)));
    }

    /// @dev Lists the value (idempotent) and drops a pending removal of the same entry (a guardian re-add cancels it).
    function _redAdd(uint8 kind, bytes32 value) internal {
        redList[kind][value] = true;
        _drop(_redQ(kind, value, false));
        emit RedListAdded(kind, value, msg.sender);
    }

    /// @notice Immediate (owner or registry guardian): HOOK / CODEHASH values only, each scoped to one hook family. TOKEN
    ///         adds go through `queueRedList` (owner, 24 h). Idempotent. A TOKEN value that is ALREADY listed is accepted
    ///         (idempotent re-add): it drops a pending TOKEN removal, so the guardian can stop that removal.
    function addRedList(uint8 kind, bytes32 value) external onlyOwnerOrGuardian nonReentrant {
        // A HOOK value is a canonical address (high 96 bits 0, as `checkUnlisted` compares it); a CODEHASH value is never
        // address-shaped. Any other encoding would list a value that never matches.
        if (
            kind == RED_TOKEN
                ? !redList[RED_TOKEN][value]
                : (kind != RED_HOOK && kind != RED_CODEHASH) || value == bytes32(0)
                    || (uint256(value) >> 160 == 0) != (kind == RED_HOOK)
        ) revert BadValue();
        _redAdd(kind, value);
    }

    /// @notice Owner, 24 h queue (+7 d grace, inclusive): TOKEN adds (native, WETH and USDG refused) and removals of any
    ///         kind. Validated at queue AND at apply (`_redCheck`).
    function queueRedList(uint8 kind, bytes32 value, bool add) external onlyOwner nonReentrant {
        _redCheck(kind, value, add);
        bytes32 q = _redQ(kind, value, add);
        emit RedListQueued(kind, value, add, _queue(q, q));
    }

    function applyRedList(uint8 kind, bytes32 value, bool add) external onlyOwner nonReentrant {
        bytes32 q = _redQ(kind, value, add);
        _consume(q, q);
        _redCheck(kind, value, add);
        if (add) {
            _redAdd(kind, value);
        } else {
            delete redList[kind][value];
            emit RedListRemoved(kind, value);
        }
    }

    /// @dev add: TOKEN kind, a clean address, not a hub (native 0, WETH, USDG); removal: the entry must be listed.
    function _redCheck(uint8 kind, bytes32 value, bool add) internal view {
        if (add) {
            address t = address(uint160(uint256(value)));
            if (kind != RED_TOKEN || uint256(value) >> 160 != 0 || t == address(0) || t == K.WETH || t == K.USDG) {
                revert BadValue();
            }
        } else if (!redList[kind][value]) {
            revert BadValue();
        }
    }

    function _red(uint8 kind, bytes32 v) private view {
        if (redList[kind][v]) revert RedListedEntry(kind, v);
    }

    /**
     * @notice Unlisted withdraw-only admission (hookless and hooked); reverts in this order:
     *         `RedListedEntry(RED_TOKEN, c0)`, `(RED_TOKEN, c1)`; if `hook != 0`: `(RED_HOOK, hook)`, then
     *         `(RED_CODEHASH, <LIVE EXTCODEHASH>)` (same transaction, never the pin), then `HookCodeMismatch()` if the
     *         pool has an entry (`codehash != 0`) whose pin differs from the live runtime. Storage is read on every call.
     */
    function checkUnlisted(address c0, address c1, address hook, bytes32 poolId) external view {
        _red(RED_TOKEN, bytes32(uint256(uint160(c0))));
        _red(RED_TOKEN, bytes32(uint256(uint160(c1))));
        if (hook != address(0)) {
            bytes32 h = hook.codehash;
            _red(RED_HOOK, bytes32(uint256(uint160(hook))));
            _red(RED_CODEHASH, h);
            bytes32 pin = _hookEntry[poolId].codehash;
            if (pin != bytes32(0) && pin != h) revert HookCodeMismatch();
        }
    }

    // ------------------------------------------------------------------ hook entries

    /// @notice The stored entry (all 9 fields; zero struct = no entry). Existence: `codehash != 0`.
    function hookEntry(bytes32 poolId) external view returns (HookEntry memory) {
        return _hookEntry[poolId];
    }

    /// @notice The pool ids of the pair's last committed listing, in listing order (keeper / UI; exec-pool candidates).
    ///         `removePool` / `removePair` do not prune it: callers confirm each id with `poolInfo` / `ruleOf`.
    function poolsOf(address currency0, address currency1) external view returns (bytes32[] memory) {
        return _poolsOf[pairId(currency0, currency1)];
    }

    /**
     * @notice The Steward's listed-path read: `poolInfo` semantics (exactly `PoolNotAllowed()` when the pool is not
     *         listed at the pair's current epoch) plus, for a hooked pool only, its entry. If an entry exists
     *         (`codehash != 0`) the hook's LIVE runtime must still match it, else `HookCodeMismatch()`. Hookless pools
     *         never read the entry. A zero entry means "listed, no entry".
     */
    function ruleOf(address c0, address c1, bytes32 poolId, address hook)
        external
        view
        returns (int24 gate, uint32 epoch, bool swapOk, bool budgeted, HookEntry memory e)
    {
        (gate, epoch, swapOk, budgeted) = poolInfo(c0, c1, poolId);
        if (hook != address(0)) {
            e = _hookEntry[poolId];
            if (e.codehash != bytes32(0) && hook.codehash != e.codehash) revert HookCodeMismatch();
        }
    }

    /**
     * @notice Seeds the founding 0x06a8 hook entry as kind 1: owner only, before `sealFounding` (`Sealed()` after).
     *         `pinnedCap` must equal the hook's LIVE `maxFee` (kind-1 branch: above -> `HookFeeCapRaised`, below ->
     *         `BadValue`), so the parameter adds no trust; every other field is a constant. Runs the full
     *         `_validateHookEntry` (ETH/USDG with the hooked pool must already be seeded). The Steward constructor
     *         requires this entry (`BadDeployment` otherwise).
     */
    function seedFoundingHooks(uint24 pinnedCap) external onlyOwner nonReentrant {
        if (foundingSealed) revert Sealed();
        PoolKey memory k = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(K.USDG), DYN_FEE, K.FOUNDING_TICK_SPACING, IHooks(K.FOUNDING_HOOK)
        );
        HookEntry memory e = HookEntry(
            K.FOUNDING_CODEHASH,
            pinnedCap,
            K.FOUNDING_ABS_MAX_FEE,
            K.FOUNDING_MAX_SLIPPAGE_BPS,
            KIND_SIGNED_FEE,
            K.FOUNDING_FEE_CEILING,
            K.FOUNDING_REQUIRED_BITS,
            address(0),
            0
        );
        bytes32 pid = _validateHookEntry(k, e);
        if (pid != K.FOUNDING_POOL_ID) revert BadDeployment();
        _hookEntry[pid] = e;
        emit HookEntryAdded(pid, K.FOUNDING_HOOK, e);
    }

    /// @notice Owner, 24 h queue (+7 d grace), keyed by poolId and bound to the hash of `(key, e)`. Re-queueing a poolId
    ///         that already has an entry is the owner's timelocked change; the active entry stays active until apply.
    function queueHookEntry(PoolKey calldata key, HookEntry calldata e) external onlyOwner nonReentrant {
        bytes32 pid = _validateHookEntry(key, e);
        emit HookEntryQueued(pid, address(key.hooks), e, _queue(_qid("HOOK", pid), keccak256(abi.encode(key, e))));
    }

    /// @notice Owner, after 24 h: consumes the exact `(key, e)` hash, then validates AGAIN (the chain may have moved: cap,
    ///         code, listing, bits).
    function applyHookEntry(PoolKey calldata key, HookEntry calldata e) external onlyOwner nonReentrant {
        bytes32 pid = keccak256(abi.encode(key));
        _consume(_qid("HOOK", pid), keccak256(abi.encode(key, e)));
        _validateHookEntry(key, e);
        _hookEntry[pid] = e;
        emit HookEntryAdded(pid, address(key.hooks), e);
    }

    /// @notice Immediate (owner or registry guardian): deletes the entry and drops a pending queue for the pool. Swap
    ///         flows on the pool then fail `PoolNotAllowed`; withdraw-only continues. `HookEntryRemoved` only when an
    ///         entry or a pending queue existed.
    function removeHookEntry(bytes32 poolId) external onlyOwnerOrGuardian nonReentrant {
        // Emit only when an entry or a pending HOOK queue was actually removed, as `_dropHookEntry` does for entries; a
        // no-op removal emits nothing.
        bytes32 q = _qid("HOOK", poolId);
        bool removed = _hookEntry[poolId].codehash != bytes32(0) || queuedAt[q] != 0;
        delete _hookEntry[poolId];
        _drop(q);
        if (removed) emit HookEntryRemoved(poolId, msg.sender);
    }

    /// @dev Entry lifetime: an entry never outlives its pool's listing. Drops the pool's pending HOOK queue and the entry;
    ///      emits `HookEntryRemoved(id, msg.sender)` when either existed. Called by `removePool`, by `removePair` for every
    ///      id of the pair's last listing, and by the `_commit` branch that drops a pool. A later re-list never revives an
    ///      entry: it needs a fresh queue -> 24 h -> apply with full validation.
    function _dropHookEntry(bytes32 id) internal {
        // Emits for a dropped pending HOOK queue too (as `removeHookEntry` does), so an observer tracking
        // `HookEntryQueued` never keeps a stale pending queue after `removePool` / `removePair` / a dropping re-list.
        bytes32 q = _qid("HOOK", id);
        bool removed = _hookEntry[id].codehash != bytes32(0) || queuedAt[q] != 0;
        _drop(q);
        if (removed) {
            delete _hookEntry[id];
            emit HookEntryRemoved(id, msg.sender);
        }
    }

    /**
     * @dev Runs at queue and at apply (and at the founding seed). Each step reverts before the next one is read:
     *      1 hooked + ts, 2 kind, 3 listing, 4 pin, 4b delegation designator, 5 red list, 6 bits + per-kind mask,
     *      7 slippage, 8 depth, 9 kind branch (kind 4: the `launches` terms).
     */
    function _validateHookEntry(PoolKey memory key, HookEntry memory e) internal view returns (bytes32 pid) {
        address hook = address(key.hooks);
        // 1. hooked pool with an admissible tick spacing
        if (hook == address(0) || key.tickSpacing > ENTRY_MAX_TICK_SPACING) revert PoolNotAllowed();
        // 2. kind before any other read
        uint8 kd = e.kind;
        if (kd == 0 || kd > KIND_PONSV2_TERMS) revert BadValue();
        // 3. listed at the pair's CURRENT epoch (exact `PoolNotAllowed` otherwise)
        pid = keccak256(abi.encode(key));
        (address c0, address c1) = (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        poolInfo(c0, c1, pid);
        // 4. pinned runtime; 4b. an EIP-7702 delegation designator is never a hook
        if (e.codehash == bytes32(0) || hook.codehash != e.codehash) revert HookCodeMismatch();
        // A hook without code (pin keccak256("")) is refused like a designator: code it gained later would no longer
        // match the pin and would stop every flow on the pool, withdraw-only exits included.
        uint256 n = hook.code.length;
        if (n == 0 || (n == 23 && bytes3(_codeWord(hook, 0)) == bytes3(0xef0100))) revert HookCodeMismatch();
        // 5. red-list check: the hook address, then the pinned runtime (== live, step 4)
        _red(RED_HOOK, bytes32(uint256(uint160(hook))));
        _red(RED_CODEHASH, e.codehash);
        // 6. permission bits exactly as declared, then the per-kind forbidden mask
        uint16 bits = e.requiredBits;
        if (uint160(hook) & 0x3FFF != bits) revert HookBitsForbidden();
        if (bits & (kd == KIND_SIGNED_FEE ? 0x030F : kd == KIND_PONSV2_TERMS ? 0x030B : 0x0303) != 0) {
            revert HookBitsForbidden();
        }
        // 7. slippage bound
        if (e.maxSlippageBps < ENTRY_MIN_SLIPPAGE_BPS || e.maxSlippageBps > ENTRY_MAX_SLIPPAGE_BPS) revert BadValue();
        // 8. depth rule: measured ±100-tick walk at the anchor AND the listed fill, both >= ENTRY_MIN_WALK_USD ($4,000)
        uint256 walk = _walkUsd(c0, c1, pid, key.tickSpacing);
        if (poolListing[pid].fillUsd < ENTRY_MIN_WALK_USD || walk < ENTRY_MIN_WALK_USD) revert EntryTooThin(walk);
        // 9. kind branch
        if (kd == KIND_SIGNED_FEE) {
            if (key.fee != DYN_FEE) revert PoolNotAllowed();
            if (
                IGoatFeeCapHook(hook).ABSOLUTE_MAX_FEE() != e.absMaxFee || e.pinnedFee == 0 || e.pinnedFee > e.absMaxFee
                    || e.feeCeiling == 0 || e.feeCeiling > e.absMaxFee || e.taxRecipient != address(0)
                    || e.recipientCodeOffset != 0
            ) revert BadValue();
            uint24 live = IGoatFeeCapHook(hook).maxFee(pid);
            if (live > e.pinnedFee) revert HookFeeCapRaised(live, e.pinnedFee);
            if (live != e.pinnedFee) revert BadValue();
        } else if (kd == KIND_EXTERNAL_VENUE) {
            // The own pool is never swapped (its `key.fee` is free); every fee field and the recipient are 0.
            if (
                e.pinnedFee != 0 || e.absMaxFee != 0 || e.feeCeiling != 0 || e.taxRecipient != address(0)
                    || e.recipientCodeOffset != 0
            ) revert BadValue();
        } else if (kd == KIND_CONST_TAX) {
            // A compiled constant tax, pinned by the code hash (step 4). Static `key.fee` <= 1 %; φ = the composite
            // pinned fee: key.fee <= φ == absMaxFee <= feeCeiling <= 100,000.
            if (key.fee > ENTRY_MAX_STATIC_FEE) revert PoolNotAllowed();
            if (
                e.pinnedFee == 0 || e.pinnedFee < key.fee || e.absMaxFee != e.pinnedFee || e.feeCeiling < e.pinnedFee
                    || e.feeCeiling > MAX_USER_SWAP_FEE
            ) revert BadValue();
            // The recipient is BOUND, never typed in by the owner: either the hook itself (tax kept by the pinned hook;
            // offset 0) or the non-zero address whose 20 bytes sit at `recipientCodeOffset` of the pinned runtime (an
            // immutable), and that address has no code (the Engine checks it again right before every swap).
            address r = e.taxRecipient;
            uint256 off = e.recipientCodeOffset;
            if (r == hook) {
                if (off != 0) revert BadValue();
            } else {
                if (r == address(0) || off + 20 > hook.code.length || address(bytes20(_codeWord(hook, off))) != r) {
                    revert BadValue();
                }
                if (r.code.length != 0) revert TaxRecipientHasCode(r);
            }
        } else {
            // The PonsV2MemeHook runtime pinned by `KIND4_CODEHASH`; the tax `100 · (h + c)` is fixed per launch at
            // `registerPool` and read from `launches(poolId)` (never the global `hookFeeBps()`, which only applies to
            // future launches).
            // (a) the compiled runtime only, no recipient, no offset -> `BadValue` BEFORE the fee check
            if (e.codehash != KIND4_CODEHASH || e.taxRecipient != address(0) || e.recipientCodeOffset != 0) {
                revert BadValue();
            }
            // (b) static `key.fee` <= 1 % (the dynamic flag 0x800000 is above it) -> `PoolNotAllowed`
            if (key.fee > ENTRY_MAX_STATIC_FEE) revert PoolNotAllowed();
            // (c) the launch record: 40,000 gas, exactly 416 B, else `HookFeeUnreadable`
            (uint256 reg, uint256 meme, uint256 c, uint256 h) = GoatPonsV2Terms.read(hook, pid);
            // (d) registered, the memecoin is one of the pair's tokens and never 0 (on a native pair c0 == address(0)
            //     would match a zero word), h <= 1000 and h + c <= 2000 (`c > 2000` first: no overflow on a garbage word)
            if (
                reg != 1 || meme == 0 || (meme != uint256(uint160(c0)) && meme != uint256(uint160(c1))) || h > 1000
                    || c > 2000 || h + c > 2000
            ) revert BadValue();
            // (e) pin == key.fee + 100 · (h + c), absMaxFee == key.fee + 200,000, pin <= feeCeiling <= 100,000
            if (
                e.pinnedFee != uint256(key.fee) + 100 * (h + c) || e.absMaxFee != uint256(key.fee) + 200_000
                    || e.feeCeiling < e.pinnedFee || e.feeCeiling > MAX_USER_SWAP_FEE
            ) revert BadValue();
            // (f) zero pin (a zero-tax launch on a 0-fee pool): such pools stay withdraw-only
            if (e.pinnedFee == 0) revert BadValue();
        }
    }

    /// @dev Walk (whole USD): the meter's ±100-tick walk of the entry pool priced at the pair's anchor, the smaller side
    ///      `min(down0 · usd0 / unit0, up1 · usd1 / unit1) / 1e8`. `anchorOf` reverts outside the session or on a stale
    ///      feed, so the owner queues and applies during the session.
    function _walkUsd(address c0, address c1, bytes32 pid, int24 ts) internal view returns (uint256) {
        Quote memory q = this.anchorOf(c0, c1);
        (uint256 down0, uint256 up1,) = METER.v4Depth(pid, ts);
        uint256 a = FullMath.mulDiv(down0, q.usd0, q.unit0 * 1e8);
        uint256 b = FullMath.mulDiv(up1, q.usd1, q.unit1 * 1e8);
        return a < b ? a : b;
    }

    /// @dev 32 bytes of `a`'s runtime at `off` (zero-padded past the end).
    function _codeWord(address a, uint256 off) internal view returns (bytes32 w) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 0)
            extcodecopy(a, p, off, 32)
            w := mload(p)
        }
    }

    // ------------------------------------------------------------------ holiday calendar

    /**
     * @notice Immediate (owner or guardian; it only NARROWS the service): closes the hours [fromHour, toHour) (ts / 3600).
     *         One call closes at most `MAX_CLOSURE_HOURS`; the end is in the future and at most `MAX_CLOSURE_AHEAD_HOURS`
     *         ahead. During those hours the anchor of every session-bound row reverts `NoAnchor` and the SR of NC rows
     *         freezes (`_slowFrozen`). The closure ends by itself; reopening early needs the owner and 24 h
     *         (`queueReopen` → `reopenMarket`).
     */
    function closeMarket(uint256 fromHour, uint256 toHour) external onlyOwnerOrGuardian nonReentrant {
        uint256 nowH = block.timestamp / 1 hours;
        if (
            toHour <= fromHour || toHour - fromHour > MAX_CLOSURE_HOURS || toHour <= nowH
                || toHour > nowH + MAX_CLOSURE_AHEAD_HOURS
        ) revert BadValue();
        for (uint256 h = fromHour; h < toHour; ++h) {
            closedHourBits[h >> 8] |= uint256(1) << (h & 255);
        }
        lastClosureAt = block.timestamp;
        emit MarketClosureAdded(fromHour, toHour);
    }

    /// @notice A reopening WIDENS the service: owner only, 24-hour queue (valid until eta + 7 days). At most 168 hours.
    function queueReopen(uint256 fromHour, uint256 toHour) external onlyOwner nonReentrant {
        if (toHour <= fromHour || toHour - fromHour > MAX_CLOSURE_AHEAD_HOURS) revert BadValue();
        emit MarketReopenQueued(fromHour, toHour, _queue(_rq(fromHour, toHour), bytes32(uint256(1))));
    }

    /// @notice Reopens the queued range. If a closure was added AFTER it was queued, `NotQueued` (queue it again): an old
    ///         reopening queue cannot silently clear a newer holiday closure.
    function reopenMarket(uint256 fromHour, uint256 toHour) external onlyOwner nonReentrant {
        bytes32 q = _rq(fromHour, toHour);
        // '<=': a closure in the same second as the queue (timestamps are whole seconds) also blocks it.
        if (queuedAt[q] <= lastClosureAt) revert NotQueued();
        _consume(q, bytes32(uint256(1)));
        for (uint256 h = fromHour; h < toHour; ++h) {
            closedHourBits[h >> 8] &= ~(uint256(1) << (h & 255));
        }
        emit MarketReopened(fromHour, toHour);
    }

    /// @notice Immediate (owner or guardian): deletes a pending reopening (narrows the service).
    function cancelReopen(uint256 fromHour, uint256 toHour) external onlyOwnerOrGuardian nonReentrant {
        _drop(_rq(fromHour, toHour));
        emit MarketReopenCancelled(fromHour, toHour);
    }

    function _rq(uint256 fromHour, uint256 toHour) internal pure returns (bytes32) {
        return _qid("OPEN", keccak256(abi.encode(fromHour, toHour)));
    }

    /// @dev `NoAnchor` if the current hour is closed in the holiday calendar.
    function _checkHoliday() private view {
        uint256 h = block.timestamp / 1 hours;
        if ((closedHourBits[h >> 8] >> (h & 255)) & 1 != 0) revert NoAnchor();
    }

    /// @dev `xMarketHours` calendar: [Mon 01:00, Sat 00:00) UTC and not a holiday hour.
    function _checkSessionOpen() private view {
        GoatAnchorLib.checkSessionOpen();
        _checkHoliday();
    }

    /// @dev Session-bound feed: the calendar + a round from this week (`GoatAnchorLib.checkSession`), and no holiday hour.
    ///      EVERY hour from the round's hour to the current hour must be open (a pre-holiday round is never accepted after
    ///      the closure ends; a post-closure round is needed). `checkSession` bounds the span to this week (<= 168 h), so
    ///      at most two bitmap words are read.
    function _checkSession(uint256 updatedAt) private view {
        GoatAnchorLib.checkSession(updatedAt);
        uint256 a = updatedAt / 1 hours;
        uint256 b = block.timestamp / 1 hours;
        for (uint256 w = a >> 8; w <= b >> 8; ++w) {
            uint256 bits = closedHourBits[w];
            if (w == a >> 8) bits &= type(uint256).max << (a & 255);
            if (w == b >> 8 && (b & 255) != 255) bits &= (uint256(1) << ((b & 255) + 1)) - 1;
            if (bits != 0) revert NoAnchor();
        }
    }

    // ------------------------------------------------------------------ swap budget (two buckets)

    /**
     * @notice Immediate (owner or guardian): lowers the buckets; each one equal to or below the old value, at least one
     *         STRICTLY below; 0 = swap flows off (withdraw-only continues). On a CL row only (0, 0). Also deletes a
     *         pending raise. Does not touch the version.
     */
    function lowerSwapCap(address currency0, address currency1, uint128 cap, uint128 capX)
        external
        onlyOwnerOrGuardian
        nonReentrant
    {
        bytes32 pid = pairId(currency0, currency1);
        PairEntry storage e = _entries[pid];
        SwapBudget storage b = swapBudget[pid];
        if (
            e.gate == 0 || cap > b.cap || capX > b.capX || (cap == b.cap && capX == b.capX)
                || (!_isNc(e.srcKind) && (cap != 0 || capX != 0))
        ) revert BadValue();
        (b.cap, b.capX) = (cap, capX);
        _drop(_qid("CAP", pid));
        emit SwapCapLowered(currency0, currency1, cap, capX, msg.sender);
    }

    /// @notice RAISING the buckets (UNLIMITED included) needs the owner and 24 h; each one equal to or above the old value,
    ///         at least one STRICTLY above. On a CL row only (UNLIMITED, UNLIMITED).
    function queueSwapCap(address currency0, address currency1, uint128 cap, uint128 capX)
        external
        onlyOwner
        nonReentrant
    {
        bytes32 pid = pairId(currency0, currency1);
        _checkRaise(pid, cap, capX);
        uint256 eta = _queue(_qid("CAP", pid), keccak256(abi.encode(cap, capX)));
        emit SwapCapQueued(currency0, currency1, cap, capX, eta);
    }

    function applySwapCap(address currency0, address currency1, uint128 cap, uint128 capX)
        external
        onlyOwner
        nonReentrant
    {
        bytes32 pid = pairId(currency0, currency1);
        _consume(_qid("CAP", pid), keccak256(abi.encode(cap, capX)));
        _checkRaise(pid, cap, capX);
        SwapBudget storage b = swapBudget[pid];
        (b.cap, b.capX) = (cap, capX);
        emit SwapCapRaised(currency0, currency1, cap, capX);
    }

    function _checkRaise(bytes32 pid, uint128 cap, uint128 capX) internal view {
        PairEntry storage e = _entries[pid];
        SwapBudget storage b = swapBudget[pid];
        if (
            e.gate == 0 || cap < b.cap || capX < b.capX || (cap == b.cap && capX == b.capX)
                || (!_isNc(e.srcKind) && (cap != CAP_UNLIMITED || capX != CAP_UNLIMITED))
        ) revert BadValue();
    }

    /**
     * @notice Takes the principal of a swap-flow OPERATOR run from the pair's buckets (bound Steward only; BEFORE the
     *         Engine call, in the same transaction, so a revert undoes the run). On every NC RECENTER (swap-less
     *         included) and swap EXIT, BOTH legs of the one-sided principal are counted: the hard leg in the hard bucket,
     *         the X leg in the X bucket, each in its OWN raw units (the anchor price is not used in the accounting).
     *         Both buckets UNLIMITED: no-op. Either bucket 0: `SwapsOff`. No room: `SwapBudgetExceeded(value, room)`.
     */
    function consumeSwapBudget(address currency0, address currency1, uint256 p0, uint256 p1) external {
        if (msg.sender != steward) revert NotOperator();
        bytes32 pid = pairId(currency0, currency1);
        SwapBudget storage b = swapBudget[pid];
        (uint128 cap, uint128 capX) = (b.cap, b.capX);
        if (cap == CAP_UNLIMITED && capX == CAP_UNLIMITED) return;
        if (cap == 0 || capX == 0) revert SwapsOff();
        (uint256 vH, uint256 vX) = _nc[pid].ncIs0 ? (p1, p0) : (p0, p1);
        if (cap != CAP_UNLIMITED) {
            (uint256 used, uint256 room) = _level(cap, b.used, b.at);
            if (vH > room) revert SwapBudgetExceeded(vH, room);
            (b.used, b.at) = (uint128(used + vH), uint64(block.timestamp));
        }
        if (capX != CAP_UNLIMITED) {
            (uint256 used, uint256 room) = _level(capX, b.usedX, b.atX);
            if (vX > room) revert SwapBudgetExceeded(vX, room);
            (b.usedX, b.atX) = (uint128(used + vX), uint64(block.timestamp));
        }
        emit SwapBudgetUsed(currency0, currency1, vH, vX);
    }

    /// @notice Preview (Steward `evaluateRun`): the value and room of the FIRST bucket that cannot take the principal
    ///         (hard, then X); (0, max) if both can.
    function previewSwapBudget(address currency0, address currency1, uint256 p0, uint256 p1)
        external
        view
        returns (uint256 value, uint256 room)
    {
        bytes32 pid = pairId(currency0, currency1);
        SwapBudget storage b = swapBudget[pid];
        (uint256 vH, uint256 vX) = _nc[pid].ncIs0 ? (p1, p0) : (p0, p1);
        if (b.cap != CAP_UNLIMITED) {
            (, room) = _level(b.cap, b.used, b.at);
            if (vH > room) return (vH, room);
        }
        if (b.capX != CAP_UNLIMITED) {
            (, room) = _level(b.capX, b.usedX, b.atX);
            if (vX > room) return (vX, room);
        }
        return (0, type(uint256).max);
    }

    /// @notice Budget state (keeper): both buckets' cap, used amount after the leak, and room (UNLIMITED: 0 and max).
    function swapBudgetOf(address currency0, address currency1)
        external
        view
        returns (uint128 cap, uint256 used, uint256 room, uint128 capX, uint256 usedX, uint256 roomX)
    {
        SwapBudget storage b = swapBudget[pairId(currency0, currency1)];
        (cap, capX) = (b.cap, b.capX);
        (used, room) = cap == CAP_UNLIMITED ? (0, type(uint256).max) : _level(cap, b.used, b.at);
        (usedX, roomX) = capX == CAP_UNLIMITED ? (0, type(uint256).max) : _level(capX, b.usedX, b.atX);
    }

    /// @dev A bucket's level after the leak: `used − cap·(now − at)/SWAP_CAP_WINDOW` (>= 0), and the room `cap − used` (>= 0).
    function _level(uint256 cap, uint256 used0, uint64 at) internal view returns (uint256 used, uint256 room) {
        uint256 leak = FullMath.mulDiv(cap, block.timestamp - at, SWAP_CAP_WINDOW);
        used = used0 > leak ? used0 - leak : 0;
        room = cap > used ? cap - used : 0;
    }

    // ------------------------------------------------------------------ slow reference (SR; NC rows only)

    /**
     * @notice Permissionless: moves the SR toward `_srTarget` (V3: TWAP900 while calm; POKE: clamp(SR, medLo, medHi)) by
     *         at most `rate·min(Δt, SR_MAX_DT)/3600` ticks (on the absolute hour grid). Reverts if the source cannot be
     *         read (`NcTwapUnavailable` / `PokeHistoryGap` / `PoolNotAllowed`). The keeper pokes rows that fall behind;
     *         anyone can poke, which neither speeds the SR up nor slows it down (0 in the same block, the grid
     *         telescopes, gaps are forfeited). `SrFeedsGas` if the caller lacks the gas to forward `SR_FEEDS_GAS`.
     *         While the pair's swap flows are CLOSED (`_slowFrozen`) the SR does not move; only `at` becomes now.
     *         "Closed" also covers a closed feed half of the anchor (holiday, stale round, `maxAge`, sequencer).
     */
    function pokeNcSlow(address currency0, address currency1) public returns (int24 slow) {
        bytes32 pid = pairId(currency0, currency1);
        NcSlow storage sr = ncSlow[pid];
        if (sr.rate == 0) revert PoolNotAllowed();
        (int24 t, int24 target, bool calm) = _srTarget(pid, _entries[pid], sr.tick);
        uint32 at;
        (slow, at) = _slowNow(pid, currency0, currency1, sr, target, calm);
        (sr.tick, sr.at) = (slow, at);
        emit NcSlowPoked(currency0, currency1, t, slow);
    }

    /// @notice Batch poke (keeper): if any one reverts, all revert (the keeper simulates first).
    function pokeNcSlowMany(address[] calldata c0, address[] calldata c1) external {
        if (c0.length != c1.length) revert BadValue();
        for (uint256 i; i < c0.length; ++i) {
            pokeNcSlow(c0[i], c1[i]);
        }
    }

    /// @notice SR state (keeper): the stored trail, the value a poke would give NOW (the source is read; while frozen, the
    ///         stored value), the rate and `at`.
    function slowOf(address currency0, address currency1)
        external
        view
        returns (int24 stored, int24 virtualNow, uint16 rate, uint32 at)
    {
        bytes32 pid = pairId(currency0, currency1);
        NcSlow storage sr = ncSlow[pid];
        if (sr.rate == 0) revert PoolNotAllowed();
        (, int24 target, bool calm) = _srTarget(pid, _entries[pid], sr.tick);
        (virtualNow,) = _slowNow(pid, currency0, currency1, sr, target, calm);
        return (sr.tick, virtualNow, sr.rate, sr.at);
    }

    /// @notice Immediate (owner or guardian): lowers the SR rate STRICTLY (>= `SR_RATE_MIN`); deletes a pending raise.
    function lowerSlowRate(address currency0, address currency1, uint16 rate) external onlyOwnerOrGuardian nonReentrant {
        bytes32 pid = pairId(currency0, currency1);
        NcSlow storage sr = ncSlow[pid];
        if (rate >= sr.rate || rate < K.SR_RATE_MIN) revert BadValue();
        sr.rate = rate;
        _drop(_qid("SR", pid));
        emit SlowRateLowered(currency0, currency1, rate, msg.sender);
    }

    /// @notice RAISING the SR rate needs the owner and 24 h (<= `SR_RATE_MAX`). Does not touch the version (the rate is not semantic).
    function queueSlowRate(address currency0, address currency1, uint16 rate) external onlyOwner nonReentrant {
        bytes32 pid = pairId(currency0, currency1);
        _checkRateRaise(pid, rate);
        emit SlowRateQueued(currency0, currency1, rate, _queue(_qid("SR", pid), keccak256(abi.encode(rate))));
    }

    function applySlowRate(address currency0, address currency1, uint16 rate) external onlyOwner nonReentrant {
        bytes32 pid = pairId(currency0, currency1);
        _consume(_qid("SR", pid), keccak256(abi.encode(rate)));
        _checkRateRaise(pid, rate);
        ncSlow[pid].rate = rate;
        emit SlowRateRaised(currency0, currency1, rate);
    }

    function _checkRateRaise(bytes32 pid, uint16 rate) internal view {
        uint16 r = ncSlow[pid].rate;
        if (r == 0 || rate <= r || rate > K.SR_RATE_MAX) revert BadValue();
    }

    /**
     * @dev SR step: the base is `at`, or `now − SR_MAX_DT` if `at` is older than that (the gap is forfeited);
     *      step = floor(rate·now/3600) − floor(rate·base/3600) on the ABSOLUTE hour grid, so consecutive steps telescope
     *      and the total does not depend on when the pokes happen. If the target is within one step: (target, now).
     *      Otherwise the trail moves by the step and `at` = now.
     */
    function _slowStep(NcSlow storage sr, int24 target) internal view returns (int24 slow, uint32 at) {
        uint256 rate = sr.rate;
        uint256 base = sr.at;
        if (block.timestamp - base > K.SR_MAX_DT) base = block.timestamp - K.SR_MAX_DT;
        uint256 step = rate * block.timestamp / 3600 - rate * base / 3600;
        int256 tick = sr.tick;
        int256 d = int256(target) - tick;
        if (d <= int256(step) && -d <= int256(step)) return (target, uint32(block.timestamp));
        slow = int24(d > 0 ? tick + int256(step) : tick - int256(step));
        at = uint32(block.timestamp);
    }

    /**
     * @dev Whether the pair's swap flows are CLOSED. While they are, the SR FREEZES: prices during the closure cannot
     *      move the SR, and after the reopening the SR moves on from its earlier value at rate R. Closed when:
     *      (i)   either bucket is 0 (`consumeSwapBudget` → `SwapsOff`; a single 0 bucket closes the pair's WHOLE swap
     *            flow);
     *      (ii)  the bound Steward has paused the SWAP bit (4), or RECENTER (1) and EXIT (2) together;
     *      (iii) the anchor's FEED half is closed: `ncFeedsOf` reverts. It runs the SAME code as `anchorOf`'s NC branch
     *            (`_ncFeeds`): sequencer, `xMarketHours` calendar + holiday hours, the hard feed and the V3DERIVED source
     *            feed (`_read`: age > maxAge, no round this week, session / holiday, bounds, decimals, multiplier), so
     *            "flows closed" and "SR frozen" always agree;
     *      (iv)  no listed swap venue at the current epoch (`_anyVenue`: every pool removed, or every remaining pool
     *            refused by the Steward's listed swap path: kind-2 external venue, hooked without an entry (after
     *            `removeHookEntry`, before a new HOOK queue is applied), a hook runtime no longer matching its pin, or a
     *            key outside the static policy).
     *      The source's own price shape (`PokeSpreadWide`, the extreme-price bound) does not freeze the SR. If the source
     *      cannot be read (`NcTwapUnavailable` / `PokeHistoryGap`) the poke reverts anyway, so the SR cannot move.
     *      Self-call: a fixed `SR_FEEDS_GAS` is forwarded and `SrFeedsGas` reverts if the caller does not hold that much,
     *      so a call short of gas never reads as frozen (a feed read costing more than `SR_FEEDS_GAS` would keep the SR
     *      frozen: fail-closed).
     */
    function _slowFrozen(bytes32 pid, address currency0, address currency1) internal view returns (bool) {
        SwapBudget storage b = swapBudget[pid];
        if (b.cap == 0 || b.capX == 0) return true;
        address s = steward;
        if (s != address(0)) {
            uint8 m = IGoatStewardRegistryRef(s).pausedModes();
            if (m & 4 != 0 || m & 3 == 3) return true;
        }
        if (!_anyVenue(pid)) return true;
        if (gasleft() < SR_FEEDS_GAS + SR_FEEDS_GAS / 63 + 1000) revert SrFeedsGas();
        try this.ncFeedsOf{gas: SR_FEEDS_GAS}(currency0, currency1) returns (uint256, uint256) {
            return false;
        } catch {
            return true;
        }
    }

    /// @dev Some pool of the pair's last listing is one the Steward's listed path would swap in
    ///      (`GoatV4StewardCore._poolRule`): listed at the current epoch, key inside the static policy, and either hookless
    ///      or hooked with an entry (`codehash != 0`) that is not kind 2 and whose pin still matches the hook's LIVE runtime
    ///      (`ruleOf` reverts `HookCodeMismatch` otherwise). A hooked pool after `removeHookEntry`, before its HOOK queue
    ///      is applied, or with a changed runtime is therefore NOT a venue (the swap flows are closed there too).
    function _anyVenue(bytes32 pid) internal view returns (bool) {
        uint32 ep = _entries[pid].epoch;
        bytes32[] storage ids = _poolsOf[pid];
        for (uint256 i; i < ids.length; ++i) {
            bytes32 id = ids[i];
            PoolListing storage l = poolListing[id];
            if (l.pair != pid || l.epoch != ep) continue;
            VenueTag memory t = _venueTag[id];
            if (t.offPolicy) continue;
            if (t.hook == address(0)) return true;
            HookEntry storage e = _hookEntry[id];
            bytes32 pin = e.codehash;
            if (pin != bytes32(0) && e.kind != KIND_EXTERNAL_VENUE && t.hook.codehash == pin) return true;
        }
        return false;
    }

    /// @dev The SR's current step: frozen → (stored, now) (the frozen time is forfeited); source not calm → the stored
    ///      trail and `at` stay as they are (no step; the accumulation is bounded by `SR_MAX_DT`); otherwise `_slowStep`.
    function _slowNow(bytes32 pid, address currency0, address currency1, NcSlow storage sr, int24 target, bool calm)
        internal
        view
        returns (int24, uint32)
    {
        if (_slowFrozen(pid, currency0, currency1)) return (sr.tick, uint32(block.timestamp));
        if (!calm) return (sr.tick, sr.at);
        return _slowStep(sr, target);
    }

    /**
     * @dev SR target. Returns the reported source tick (`NcSlowPoked.twap`), the target and whether a step is allowed.
     *      POKE: target = clamp(SR, medLo, medHi). Unregistered pokes can only WIDEN bucket lo/hi (medLo only down, medHi
     *      only up), so this target never pulls the SR away from the true price range (at most it stops it).
     *      V3 kinds: target = TWAP900, but a step only while TWAP60, TWAP10 and spot are within G of TWAP900 (the same
     *      checks as `vetoOf`), so short spikes do not advance the SR.
     */
    function _srTarget(bytes32 pid, PairEntry storage e, int24 cur)
        internal
        view
        returns (int24 src, int24 target, bool calm)
    {
        if (e.srcKind == K.SRC_NC_POKE) {
            PokeWindow memory w = _window(pid);
            target = cur < w.medLo ? w.medLo : cur > w.medHi ? w.medHi : cur;
            return (w.medMid, target, true);
        }
        (int24 t900, int24 tSlow, int24 tFast) =
            GoatAnchorLib.twapTicks3(e.vetoPool, VETO_WINDOW, GATE_TWAP_SLOW, GATE_TWAP_FAST, e.vetoFlip);
        (uint160 sp,,,,,,) = IGoatV3PoolObserve(e.vetoPool).slot0();
        int256 g = e.gate;
        int256 ds = int256(t900) - tSlow;
        int256 df = int256(t900) - tFast;
        int256 dp = int256(t900) - _spotTickV4(sp, e.vetoFlip);
        calm = ds <= g && ds >= -g && df <= g && df >= -g && dp <= g && dp >= -g;
        return (t900, t900, calm);
    }

    /// @dev The SR's starting trail at listing (v4 orientation; on V3DERIVED WITHOUT the feed term): V3 kinds TWAP900
    ///      (`NcTwapUnavailable`, fail-closed), POKE the full window's medMid (`PokeHistoryGap`). The walk target is `_srTarget`.
    function _srcTick(bytes32 pid, PairEntry storage e) internal view returns (int24) {
        if (e.srcKind == K.SRC_NC_POKE) return int24(_window(pid).medMid);
        return GoatAnchorLib.twapTick(e.vetoPool, VETO_WINDOW, e.vetoFlip);
    }

    /// @dev SR gate: [lo, hi] ⊆ [SR − G, SR + G] (SR: now, moving toward `target`; while frozen, the stored value), else
    ///      `VetoSlowFar(src, SR)`. V3 kinds: lo = hi = TWAP900 (the caller has already checked calm). POKE: lo = medLo,
    ///      hi = medHi (unregistered pokes can only widen them, which can only close the gate).
    function _slowGate(
        bytes32 pid,
        address currency0,
        address currency1,
        int24 src,
        int24 target,
        int256 lo,
        int256 hi,
        int24 g
    ) private view {
        (int24 slow,) = _slowNow(pid, currency0, currency1, ncSlow[pid], target, true);
        if (lo < int256(slow) - g || hi > int256(slow) + g) revert VetoSlowFar(src, slow);
    }

    // ------------------------------------------------------------------ writes

    function _storeCl(address c0, address c1, PairConfig calldata cfg, PairEntry memory e) internal {
        NcSource memory none;
        emit PairAdded(c0, c1, cfg, _commit(c0, c1, e, none, cfg.source.pokePool, cfg.pools, CAP_UNLIMITED, CAP_UNLIMITED));
    }

    /**
     * @dev NC row: the SR trail is set to the source's CURRENT TWAP900 (POKE: medMid; the meter has just confirmed a calm
     *      listing) only on a NEW listing or when the TRACKED SOURCE changes (kind, v3 source and orientation, poke pool).
     *      A rewrite that tracks the same source (fill refresh, added pools, semantic changes such as the gate) KEEPS the
     *      trail and `at`, so an administrative write never resets the trail. A rewrite NEVER raises the rate (a lower
     *      value is taken; a raise goes through `queueSlowRate`).
     */
    function _storeNc(address c0, address c1, NcPairConfig calldata cfg, PairEntry memory e, NcSource memory n)
        internal
    {
        bytes32 pid = pairId(c0, c1);
        NcSlow storage sr = ncSlow[pid];
        PairEntry storage old = _entries[pid];
        bool sameTrack = sr.rate != 0 && old.srcKind == e.srcKind && old.vetoPool == e.vetoPool
            && old.vetoFlip == e.vetoFlip && pokePoolOf[pid] == cfg.pokePool;
        uint32 ep = _commit(c0, c1, e, n, cfg.pokePool, cfg.pools, cfg.capHard, cfg.capX);
        if (!sameTrack) {
            // A new track on a listed pair never raises the current rate (a guardian reduction made while the source
            // change waited in the queue survives); a raise goes through `queueSlowRate`.
            uint16 r = sr.rate;
            (sr.tick, sr.at, sr.rate) =
                (_srcTick(pid, _entries[pid]), uint32(block.timestamp), r != 0 && r < cfg.slowRate ? r : cfg.slowRate);
        } else if (cfg.slowRate < sr.rate) {
            sr.rate = cfg.slowRate;
        }
        emit NcPairAdded(c0, c1, cfg, ep);
    }

    /**
     * @dev If a listed pair is rewritten with the SAME semantic hash, the version is KEPT (a fill refresh or added /
     *      removed pools do not stop swap configs); a different hash, or re-adding after `removePair`, bumps it. The new
     *      pool set is listed under the current version; pools that drop out of the set lose their record (`PoolRemoved`).
     *      Budget (two buckets): initial values on a new listing; on a listed pair a rewrite NEVER raises the budget
     *      (only `queueSwapCap` does).
     */
    function _commit(
        address c0,
        address c1,
        PairEntry memory e,
        NcSource memory n,
        bytes32 pokePool,
        PoolSpec[] calldata pools,
        uint128 initialCap,
        uint128 initialCapX
    ) internal returns (uint32 ep) {
        bytes32 pid = pairId(c0, c1);
        // Semantic hash: the entry to store (epoch 0; feed rules, flags, gate, K, source, kind) + the NC source + the poke
        // pool. Pools, fill and budget are EXCLUDED.
        bytes32 h = keccak256(abi.encode(e, n, pokePool));
        bool listed = _entries[pid].gate != 0;
        ep = pairEpoch[pid];
        if (!listed || semHash[pid] != h) {
            ep += 1;
            pairEpoch[pid] = ep;
        }
        e.epoch = ep;
        _entries[pid] = e;
        _nc[pid] = n;
        pokePoolOf[pid] = pokePool;
        semHash[pid] = h;

        bytes32[] memory ids = new bytes32[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            ids[i] = poolIdOf(c0, c1, pools[i]);
        }
        bytes32[] storage old = _poolsOf[pid];
        for (uint256 i; i < old.length; ++i) {
            bytes32 id = old[i];
            bool kept;
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == id) kept = true;
            }
            if (!kept) {
                if (poolListing[id].pair == pid) delete poolListing[id];
                _dropHookEntry(id); // the re-list drops the pool, and its entry with it
                emit PoolRemoved(id);
            }
        }
        delete _poolsOf[pid];
        for (uint256 i; i < pools.length; ++i) {
            _poolsOf[pid].push(ids[i]);
            poolListing[ids[i]] = PoolListing(pid, ep, pools[i].fillUsd);
            // The tag is a pure function of the key (hooks, fee and tickSpacing are in the poolId), so it never goes
            // stale, and the common case (hookless, in policy = zero) costs no SSTORE.
            address hk = pools[i].hooks;
            bool off =
                pools[i].tickSpacing > ENTRY_MAX_TICK_SPACING || (hk == address(0) && pools[i].fee > ENTRY_MAX_STATIC_FEE);
            if (hk != address(0) || off) _venueTag[ids[i]] = VenueTag(hk, off);
        }

        SwapBudget storage b = swapBudget[pid];
        if (!listed) {
            (b.cap, b.used, b.at) = (initialCap, 0, uint64(block.timestamp));
            (b.capX, b.usedX, b.atX) = (initialCapX, 0, uint64(block.timestamp));
        } else {
            if (initialCap < b.cap) b.cap = initialCap;
            if (initialCapX < b.capX) b.capX = initialCapX;
        }
    }

    // ================================================================== READS (Steward)

    function _entry(address c0, address c1) internal view returns (PairEntry storage e) {
        e = _entries[pairId(c0, c1)];
        if (e.gate == 0) revert PoolNotAllowed();
    }

    /// @notice The pair's gate G. `PoolNotAllowed` if the pair is not listed.
    function gateOf(address currency0, address currency1) external view returns (int24) {
        return _entry(currency0, currency1).gate;
    }

    /**
     * @notice The Steward's scope read: the pool must be allowed at the pair's CURRENT version, else `PoolNotAllowed`.
     *         Returns the gate G, the entry version, whether swap flows are open (a source exists AND neither bucket is
     *         0) and whether the pair is budgeted (either bucket is not UNLIMITED).
     */
    function poolInfo(address currency0, address currency1, bytes32 poolId)
        public
        view
        returns (int24 gate, uint32 epoch, bool swapOk, bool budgeted)
    {
        bytes32 pid = pairId(currency0, currency1);
        PairEntry storage e = _entries[pid];
        PoolListing storage l = poolListing[poolId];
        if (e.gate == 0 || l.pair != pid || l.epoch != e.epoch) revert PoolNotAllowed();
        SwapBudget storage b = swapBudget[pid];
        (uint128 cap, uint128 capX) = (b.cap, b.capX);
        return (
            e.gate, e.epoch, e.srcKind != K.SRC_NONE && cap != 0 && capX != 0, cap != CAP_UNLIMITED || capX != CAP_UNLIMITED
        );
    }

    /// @notice The stored entry (for keepers, UIs and reviewers).
    function entryOf(address currency0, address currency1) external view returns (PairEntry memory) {
        return _entry(currency0, currency1);
    }

    /// @notice The source-specific fields of an NC row.
    function ncSourceOf(address currency0, address currency1) external view returns (NcSource memory) {
        return _nc[pairId(currency0, currency1)];
    }

    /**
     * @notice Fail-closed anchor (read only by swap flows; NEVER by withdraw-only). CL: sequencer (if any) + both feeds
     *         (age, bounds, session, multiplier). NC: hard feed + source (V3SAME: TWAP900; V3DERIVED: TWAP900(X/H′) +
     *         tick(H′/H); POKE: the medMid of a 15/15 registered window with spread <= G), the `xMarketHours` calendar
     *         and the extreme-price bound (|tick| <= 800,000). Every session-bound path (`xMarketHours`,
     *         `FLAG_MARKET_HOURS` feeds, CL included) also reverts `NoAnchor` during a closed hour of the holiday
     *         calendar (`closeMarket`).
     */
    function anchorOf(address currency0, address currency1) external view returns (Quote memory q) {
        bytes32 pid = pairId(currency0, currency1);
        PairEntry memory e = _entry(currency0, currency1);
        _seq();
        q.unit0 = 10 ** e.dec0;
        q.unit1 = 10 ** e.dec1;
        if (!_isNc(e.srcKind)) {
            q.usd0 = _read(e.feed0, e.maxAge0, e.min0, e.max0, e.flags0, currency0);
            q.usd1 = _read(e.feed1, e.maxAge1, e.min1, e.max1, e.flags1, currency1);
            (q.sqrtPriceX96, q.tick) = GoatAnchorLib.pairSqrtPrice(q.usd0, q.usd1, e.dec0, e.dec1);
            (q.tickLo, q.tickHi) = (q.tick, q.tick);
            return q;
        }
        NcSource memory n = _nc[pid];
        (uint256 usdH, uint256 usdS) = _ncFeeds(e, n, currency0, currency1);
        int256 t;
        if (e.srcKind == K.SRC_NC_POKE) {
            PokeWindow memory w = _window(pid);
            if (w.spreadMax > e.gate) revert PokeSpreadWide(w.spreadMax);
            (t, q.tickLo, q.tickHi) = (w.medMid, w.medLo, w.medHi);
        } else {
            t = GoatAnchorLib.twapTick(e.vetoPool, VETO_WINDOW, e.vetoFlip);
            if (e.srcKind == K.SRC_NC_V3DERIVED) t = _derivedPairTick(e, n, usdH, usdS, t);
            (q.tickLo, q.tickHi) = (int24(t), int24(t));
        }
        if (t > K.NC_MAX_ABS_TICK || t < -K.NC_MAX_ABS_TICK) revert NoAnchor();
        q.tick = int24(t);
        q.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(q.tick);
        // USD view: X's USD price from the anchor (scaled first, so a small X price does not round to zero). The price
        // sqrtP²/2^192 is applied as two sqrtP/Q96 factors (no truncated pX96, no raw pX96·unit0 product), so the quote
        // neither loses precision at deep negative ticks nor overflows at large positive ones within the tick bound.
        uint256 sp = q.sqrtPriceX96;
        if (n.ncIs0) {
            q.usd1 = usdH;
            q.usd0 = FullMath.mulDiv(FullMath.mulDiv(FullMath.mulDiv(q.unit0 * usdH, sp, Q96), sp, Q96), 1, q.unit1);
        } else {
            q.usd0 = usdH;
            q.usd1 = FullMath.mulDiv(FullMath.mulDiv(FullMath.mulDiv(q.unit1 * usdH, Q96, sp), Q96, sp), 1, q.unit0);
        }
    }

    /// @dev V3DERIVED: the source TWAP log(H′/X) + the feed term tick(H′/H) = log(H raw / X raw), negated when X is
    ///      currency1: the pair-orientation tick (`anchorOf`, and the TWAP `vetoOf` reports).
    function _derivedPairTick(PairEntry memory e, NcSource memory n, uint256 usdH, uint256 usdS, int256 t)
        private
        pure
        returns (int256)
    {
        (, int24 tf) = GoatAnchorLib.pairSqrtPrice(usdS, usdH, n.srcDec, n.ncIs0 ? e.dec1 : e.dec0);
        t += tf;
        return n.ncIs0 ? t : -t;
    }

    /**
     * @notice The FEED half of the NC anchor: sequencer, `xMarketHours` calendar + holiday hours, the hard feed (H/USD)
     *         and the V3DERIVED source feed (H′/USD; the same answer when it is the hard feed). Returns the USD answers
     *         (8 decimals; `usdS` = 0 outside V3DERIVED). `anchorOf`'s NC branch calls the SAME internal function
     *         (`_ncFeeds`); while this half is closed (it reverts) the pair's swap flows are closed and the SR freezes
     *         (`_slowFrozen`, self-STATICCALL). Also read by the keeper. `PoolNotAllowed` if the pair is not listed,
     *         `BadPairEntry` on a CL row.
     */
    function ncFeedsOf(address currency0, address currency1) external view returns (uint256 usdH, uint256 usdS) {
        PairEntry memory e = _entry(currency0, currency1);
        if (!_isNc(e.srcKind)) revert BadPairEntry();
        _seq();
        return _ncFeeds(e, _nc[pairId(currency0, currency1)], currency0, currency1);
    }

    /// @dev Sequencer uptime rule (if a feed is set): the shared first step of `anchorOf` and `ncFeedsOf`.
    function _seq() private view {
        GoatAnchorLib.checkSequencer(sequencerFeed, SEQUENCER_GRACE);
    }

    /// @dev NC feed half (without the sequencer, which the caller checks): calendar, hard feed, V3DERIVED source feed.
    function _ncFeeds(PairEntry memory e, NcSource memory n, address currency0, address currency1)
        private
        view
        returns (uint256 usdH, uint256 usdS)
    {
        if (n.xMarketHours) _checkSessionOpen();
        usdH = n.ncIs0
            ? _read(e.feed1, e.maxAge1, e.min1, e.max1, e.flags1, currency1)
            : _read(e.feed0, e.maxAge0, e.min0, e.max0, e.flags0, currency0);
        if (e.srcKind == K.SRC_NC_V3DERIVED) {
            usdS = n.srcFeed == (n.ncIs0 ? e.feed1 : e.feed0)
                ? usdH
                : _read(n.srcFeed, n.srcMaxAge, n.srcMin, n.srcMax, n.srcFlags, address(0));
        }
    }

    function _read(address feed, uint32 maxAge, uint64 mn, uint64 mx, uint8 flags, address token)
        private
        view
        returns (uint256 answer)
    {
        uint256 updatedAt;
        (answer, updatedAt) = GoatAnchorLib.readFeed(feed, maxAge, int256(uint256(mn)), int256(uint256(mx)));
        if (IGoatChainlinkFeed(feed).decimals() != 8) revert NoAnchor();
        if (flags & K.FLAG_MARKET_HOURS != 0) _checkSession(updatedAt);
        if (flags & K.FLAG_UI_SCALED != 0) {
            GoatAnchorLib.checkMultiplier(token, updatedAt);
            // The stock token's own oracle pause is a `NoAnchor` (fail-closed: an unreadable or non-zero answer too);
            // `_slowFrozen` then freezes the SR as well.
            (bool ok, bytes memory r) =
                token.staticcall{gas: ORACLE_PAUSED_GAS}(abi.encodeWithSignature("oraclePaused()"));
            if (!ok || r.length < 32 || abi.decode(r, (uint256)) != 0) revert NoAnchor();
        }
    }

    /// @dev POKE window: EACH of the last 15 complete slots must have a registered poke (else `PokeHistoryGap`). The poke
    ///      pool must still be listed for this pair at the current epoch (removing the source pool with `removePool`
    ///      closes the anchor, the source checks and the SR walk: `PoolNotAllowed`).
    function _window(bytes32 pid) internal view returns (PokeWindow memory w) {
        bytes32 pp = pokePoolOf[pid];
        PoolListing storage l = poolListing[pp];
        if (l.pair != pid || l.epoch != _entries[pid].epoch) revert PoolNotAllowed();
        w = POKE_ORACLE.consult(pp);
        if (w.complete != K.POKE_WINDOW || w.registered != K.POKE_WINDOW) {
            revert PokeHistoryGap(w.complete, w.registered);
        }
    }

    /**
     * @notice Source checks of a swap flow. They only BLOCK. Returns the reported TWAP tick.
     *   - NONE: `ExitOnlyPair` (a swap flow needs a source).
     *   - CL+V3: a single observe([900, 60, 10, 0]); |A − TWAP900| > K → `AnchorVetoed`; |A − TWAP60| or |A − TWAP10| > G →
     *     `VetoTwapFar`; |A − v3 spot| > G → `VetoSpotFar`.
     *   - CL+V3DERIVED (kind 6): the same three checks, in the same order and with the same errors, on the path
     *     c0 -> Q -> c1 (one observe([900, 60, 10, 0]) per leg, cumulatives summed before the floor; spot = the sum of
     *     the two hop floors); either leg unreadable or a mean beyond the extreme-price bound → `AnchorVetoed`; no
     *     one-leg fallback.
     *   - CL+POKE: full window; medLo < A − K or medHi > A + K → `AnchorVetoed` (statistics that extra pokes can only
     *     widen; medMid is not used for K because it can move both ways); the newest buckets' lo/hi outside A ± G →
     *     `VetoTwapFar`.
     *   - NC V3SAME / V3DERIVED: the source's TWAP60 / TWAP10 and spot within G of the source's TWAP900 (the feed term
     *     cancels out in the differences); SR: TWAP900 within G of the slow reference (`VetoSlowFar`).
     *   - NC POKE: the newest buckets' lo/hi within medMid ± G; SR: [medLo, medHi] within the slow reference ± G.
     *   The returned TWAP is in the pair orientation (on V3DERIVED the feed term is added, and the sign flips when X is
     *   currency1).
     */
    function vetoOf(address currency0, address currency1, int24 anchorTick)
        external
        view
        returns (int24 twap, bool applied)
    {
        bytes32 pid = pairId(currency0, currency1);
        PairEntry memory e = _entry(currency0, currency1);
        uint8 k = e.srcKind;
        if (k == K.SRC_NONE) revert ExitOnlyPair();
        int256 ref = anchorTick;
        if (k == K.SRC_CL_POKE || k == K.SRC_NC_POKE) {
            PokeWindow memory w = _window(pid);
            if (k == K.SRC_CL_POKE) {
                _within(ref - w.medLo, e.vetoTicks, AnchorVetoed.selector);
                _within(w.medHi - ref, e.vetoTicks, AnchorVetoed.selector);
            } else {
                ref = w.medMid;
            }
            _within(ref - w.newLo, e.gate, VetoTwapFar.selector);
            _within(w.newHi - ref, e.gate, VetoTwapFar.selector);
            if (k == K.SRC_NC_POKE) {
                int24 cur = ncSlow[pid].tick;
                int24 target = cur < w.medLo ? w.medLo : cur > w.medHi ? w.medHi : cur;
                _slowGate(pid, currency0, currency1, w.medMid, target, w.medLo, w.medHi, e.gate);
            }
            return (w.medMid, true);
        }
        (int24 t900, int24 tSlow, int24 tFast, int256 spot) = _v3Src(e);
        bool cl = k == K.SRC_CL_V3 || k == K.SRC_CL_V3DERIVED;
        if (cl) {
            _within(ref - t900, e.vetoTicks, AnchorVetoed.selector);
        } else {
            ref = t900;
        }
        _within(ref - tSlow, e.gate, VetoTwapFar.selector);
        _within(ref - tFast, e.gate, VetoTwapFar.selector);
        _within(ref - spot, e.gate, VetoSpotFar.selector);
        if (cl) return (t900, true);
        _slowGate(pid, currency0, currency1, t900, t900, t900, t900, e.gate);
        if (k == K.SRC_NC_V3DERIVED) {
            // Report the TWAP in the pair orientation (like `anchorOf`'s tick), not in the source's.
            NcSource memory n = _nc[pid];
            (uint256 usdH, uint256 usdS) = _ncFeeds(e, n, currency0, currency1);
            return (int24(_derivedPairTick(e, n, usdH, usdS, t900)), true);
        }
        return (t900, true);
    }

    /**
     * @dev The v3 source's TWAP900 / TWAP60 / TWAP10 and spot in the orientation `vetoOf` compares. One pool (CL_V3, NC
     *      V3SAME, NC V3DERIVED source orientation), or for CL_V3DERIVED the path c0 -> Q -> c1: exact TWAPs
     *      (`GoatAnchorLib.pathTwapTicks3`: one observe per leg, cumulatives summed before the floor, extreme-price
     *      bound, fail-closed `AnchorVetoed`), spot = the sum of the two hop floors (the exact path floor or 1 below it).
     */
    function _v3Src(PairEntry memory e) private view returns (int24 t900, int24 tSlow, int24 tFast, int256 spot) {
        bool path = e.srcKind == K.SRC_CL_V3DERIVED;
        (t900, tSlow, tFast) = path
            ? GoatAnchorLib.pathTwapTicks3(
                e.vetoPool, e.vetoFlip, e.vetoPool2, e.vetoFlip2, VETO_WINDOW, GATE_TWAP_SLOW, GATE_TWAP_FAST
            )
            : GoatAnchorLib.twapTicks3(e.vetoPool, VETO_WINDOW, GATE_TWAP_SLOW, GATE_TWAP_FAST, e.vetoFlip);
        (uint160 sp,,,,,,) = IGoatV3PoolObserve(e.vetoPool).slot0();
        spot = _spotTickV4(sp, e.vetoFlip);
        if (path) {
            (sp,,,,,,) = IGoatV3PoolObserve(e.vetoPool2).slot0();
            spot += _spotTickV4(sp, e.vetoFlip2);
        }
    }

    /// @dev |d| <= bound, else revert with the given selector (an error without arguments).
    function _within(int256 d, int24 bound, bytes4 err) private pure {
        if (d > bound || d < -bound) {
            assembly ("memory-safe") {
                mstore(0, err)
                revert(0, 4)
            }
        }
    }

    /**
     * @dev FLOOR tick of the v3 spot in the requested orientation, from sqrtP rather than `slot0.tick`: when the price
     *      falls exactly onto a tick boundary, v3 writes `tick = k − 1`. k = floor(log P): plain orientation k; inverted
     *      floor(−log P) = −k when P sits exactly on the boundary, else −k − 1.
     */
    function _spotTickV4(uint160 sqrtP, bool flip) private pure returns (int256) {
        return GoatAnchorLib.spotTick(sqrtP, flip);
    }
}
