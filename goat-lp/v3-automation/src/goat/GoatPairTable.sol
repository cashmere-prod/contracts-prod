// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24; // pinned to the compiler of the deployed build

// Part of Goat LP, not derived from Revert Finance. The pair table that AutoRange and AutoExit read: which pairs and
// fee tiers v3 automation may use, their price sources and their swap limits. AutoRange and AutoExit bind it once
// with setPairTable (GoatRobinhood); Revert's ABIs are unchanged.
//
// Rows. A CL row prices a pair from two Chainlink feeds (token0/USD and token1/USD, each with its own decimals,
// answer bounds, an age limit derived from its heartbeat, and a market-hours class), with a pinned v3 veto pool and a
// pair-specific gate G. An NC row prices a pair without Chainlink: the anchor is the 900 s TWAP of a pinned v3
// reference pool of the same pair (the hard leg's Chainlink feed only values the pool's depth at listing). Every row
// needs a source pool (the veto pool or the reference) with an observation cardinality of at least 1,800 and a VD4
// depth (GoatDepthLib) of at least MIN_VETO_DEPTH_USD. AutoRange and exits with a swap run only on listed pairs; any
// other pair gets only swap-less exits, which never read the table.
//
// Roles. Widening actions are owner only and wait a 24 h timelock: adding or changing a row (queuePair -> addPair,
// queueNc -> addNc), raising a budget or an SR rate, reopening a market, unpausing swaps, adding a consumer after
// the seal and replacing a sitting guardian. Narrowing actions are instant for the owner or the guardian: removing a
// row, lowering a budget or an SR rate, closing a market, pausing swaps, removing a consumer, and cancelling a queued
// row, budget raise, rate raise or reopen. A holiday closure covers at most 96 hours per call and reaches at most 7
// days ahead; a reopen cannot clear a closure added after it was queued (lastClosureAt). Every queue lapses after
// eta + QUEUE_GRACE (NotQueued; queue again). There is no permanent disable.
//
// Failure mode: REVERT on any problem (no fallback). Stock and RWA feeds (marketHours) revert with MarketClosed()
// while the market is closed: UTC Saturday and Sunday, before the weekly opening round, and in holiday hours set by
// the owner or guardian.
//
// Swap budgets. Each pair has a leaky swap budget per leg: hard-leg input counts in raw hard-leg units, X input in
// raw X units (never converted at the anchor price). On a CL row a budget is UNLIMITED or 0 (swaps closed). Only the
// bound consumers (AutoRange, AutoExit) charge it; AutoRange charges the whole principal on every move, with or
// without a swap.
//
// Founding rows are written with seedFounding / seedFoundingNc (before the seal, only from the compile-time founding
// libraries, with the same checks), then seal(); AutoRange and AutoExit bind only a sealed table.
//
// Swap-only pause: pauseSwaps makes anchor() revert with SwapsPaused (AutoRange and every swap side of AutoExit
// stop); swap-less exits do not read the table and keep working.
//
// Slow reference (SR), NC rows ONLY: SR follows the reference's 900 s TWAP by at most slowRate ticks per hour
// (anyone can poke it; the rounded step's time is charged rounding up; idle time beyond 300 s is dropped). Swap
// flows need |TWAP900 - SR| <= G, otherwise NcSlowFar. While the pair's swap flow is closed (pauseSwaps, both budgets
// at 0, or the calendar closed on a marketHours row) SR is frozen: a poke only moves its timestamp to now. After
// reopening, SR moves on from its value before the closure at the normal rate, so a price held during the closure
// is not accepted straight away. The hard leg (capIn0) of an existing NC row cannot change (InvalidPair(10)), since
// that would swap the units of the two budgets.

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";

import "../../lib/AggregatorV3Interface.sol";
import "../utils/Constants.sol";
import "./GoatPairTypes.sol";
import "./GoatFoundingPairs.sol";
// NC founding rows and the depth walk
import "./GoatFoundingNc.sol";
import "./GoatDepthLib.sol";

contract GoatPairTable is Ownable2Step, Constants {
    // ---- constants ----
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; // NPM.factory()
    uint256 public constant TIMELOCK = 24 hours; // same as Automator.TIMELOCK
    // early bad-round filter: stock feeds had bad rounds before this time (2026-06-23 13:53:28 UTC); a round whose
    // updatedAt is not after it is rejected (the answer bounds catch such rounds as well)
    uint256 public constant FEED_EPOCH = 1782222808;
    // stock/RWA calendar: the feeds update Monday to Friday UTC; every feed writes an opening round on Monday at
    // 00:00-00:01 UTC (EDT) and the last rounds come on Saturday at 00:01 UTC. Closed: Saturday 00:00 to Monday 00:00
    // UTC, and when there is no round since this week's opening (a Monday holiday; under EST the opening is 01:00 UTC).
    // Weekday holidays: closeMarket.
    uint256 internal constant MONDAY0 = 345600; // 1970-01-05 00:00 UTC (a Monday)
    uint256 internal constant OPEN_SPAN = 5 days; // Monday 00:00 to Saturday 00:00 UTC
    uint256 public constant MAX_CLOSURE_HOURS = 96;
    // a closure reaches at most 7 days AHEAD (toHour <= current hour + 168); a reopen range is also at most 168 hours
    // (loop bound)
    uint256 public constant MAX_CLOSURE_AHEAD_HOURS = 168;
    // gate and veto bounds (row checks). CL rows: G <= K (the AutoRange/AutoExit maxTWAPTickDifference, 150); NC rows
    // use NC_MAX_GATE (no K)
    uint16 public constant MAX_GATE = 150;
    // gate applies to pools with fee <= 0.3%, gateHighFee to the higher tier (1%)
    uint24 public constant HIGH_FEE_ABOVE = 3000;
    uint16 public constant MIN_VETO_CARDINALITY = 1800;
    // minimum depth of the source pool (CL: veto pool, NC: reference): a +-100 tick walk that crosses ticks, times a
    // time weight (GoatDepthLib), the smaller of the two directions >= $4,000. The same floor as the v4 automation's
    // MIN_SOURCE_DEPTH_USD; VD4 is the only depth rule.
    uint256 public constant MIN_VETO_DEPTH_USD = 4_000;
    // queue expiry: after eta + 7 days (inclusive) NotQueued (the Compound Timelock GRACE_PERIOD pattern)
    uint256 public constant QUEUE_GRACE = 7 days;
    uint32 public constant MIN_FEED_AGE = 1 hours;
    uint32 public constant MAX_FEED_AGE_LIMIT = 4 days;
    // the Chainlink directory for chain 4663 has no "L2 Sequencer Uptime" feed; the check follows Revert's V3Oracle and
    // is skipped while this is address(0)
    address internal constant SEQUENCER_UPTIME_FEED = address(0);
    uint256 internal constant SEQUENCER_GRACE_PERIOD_TIME = 600;
    // NC rows and swap budgets
    uint32 public constant NC_TWAP_WINDOW = 900; // NC anchor = the reference's TWAP900 (same window as the veto)
    uint32 public constant SWAP_CAP_WINDOW = 3600; // budget refill: cap per 3,600 s
    uint16 public constant NC_MAX_GATE = 300;
    // 500k: consumers' priceX96 = sqrtP^2 / 2^96 keeps the relative truncation below 1e-7; the same bound applies to CL
    // anchors (anchor(), listing)
    int24 public constant NC_MAX_ABS_TICK = 500_000; // extreme prices fail closed
    uint128 public constant CAP_UNLIMITED = type(uint128).max; // "budget off": no accounting (CL rows)
    uint8 internal constant NC_MAX_DECIMALS = 30;
    // SR: idle time beyond this limit is dropped (time cannot be saved up before a poke); rate bounds (ticks per hour)
    uint32 public constant NC_SLOW_MAX_DT = 300;
    uint16 public constant NC_SLOW_MIN_RATE = 150;
    uint16 public constant NC_SLOW_MAX_RATE = 4000;

    struct Pending {
        PairCfg cfg;
        uint256 eta;
    }

    mapping(address => mapping(address => PairCfg)) internal _pairs; // token0 < token1
    mapping(address => mapping(address => Pending)) internal _pending;
    mapping(uint256 => uint256) public closedHourBits; // bitmap by hour index (ts / 3600); 1 = closed
    address public guardian;
    // pending reopens: keccak256(fromHour, toHour) -> eta
    mapping(bytes32 => uint256) public reopenEta;

    // NC rows, their queues, pair budgets, pending budget raises, bound consumers, founding seal
    struct NcPending {
        NcCfg cfg;
        uint256 eta;
    }

    struct CapPending {
        uint128 cap;
        uint128 capX; // X leg budget
        uint256 eta;
    }

    // SR state (the rate is in NcCfg.slowRate) and a pending rate raise
    struct NcSlow {
        int24 tick;
        uint32 at;
    }

    struct RatePending {
        uint16 rate;
        uint256 eta;
    }

    mapping(address => mapping(address => NcCfg)) internal _nc;
    mapping(address => mapping(address => NcPending)) internal _ncPending;
    mapping(address => mapping(address => SwapBudget)) public swapBudget;
    mapping(address => mapping(address => CapPending)) internal _capPending;
    // X leg budget (raw X units); on a CL row the same value as swapBudget
    mapping(address => mapping(address => SwapBudget)) public swapBudgetX;
    // SR and pending rate raises
    mapping(address => mapping(address => NcSlow)) public ncSlow;
    mapping(address => mapping(address => RatePending)) internal _ratePending;
    mapping(address => bool) public swapConsumer;
    bytes32 public immutable clFoundingHash; // keccak256(abi.encode(GoatFoundingPairs.rows()))
    bytes32 public immutable ncFoundingHash; // keccak256(abi.encode(GoatFoundingNc.rows()))
    bool public foundingSealed; // `sealed` is a reserved word in Solidity
    // when the last closure was added
    uint256 public lastClosureAt;
    // swap-only pause
    bool public swapsPaused;
    uint256 public swapsUnpauseEta;
    // consumer list (SR freezes while every consumer is paused) and the queue for adding consumers after the seal
    address[] internal _consumers;
    mapping(address => uint256) public swapConsumerEta;
    // the owner replaces a sitting guardian only after 24 h
    address public pendingGuardian;
    uint256 public guardianEta;

    event PairQueued(address indexed token0, address indexed token1, uint256 eta, PairCfg cfg);
    event PairAdded(address indexed token0, address indexed token1, PairCfg cfg);
    event PairRemoved(address indexed token0, address indexed token1);
    event PairQueueCancelled(address indexed token0, address indexed token1);
    event MarketClosureAdded(uint256 fromHour, uint256 toHour);
    event MarketReopenQueued(uint256 fromHour, uint256 toHour, uint256 eta);
    event MarketReopened(uint256 fromHour, uint256 toHour);
    event MarketReopenCancelled(uint256 fromHour, uint256 toHour);
    event GuardianChanged(address newGuardian);
    // NC rows and swap budgets
    event NcQueued(address indexed token0, address indexed token1, uint256 eta, NcCfg cfg);
    event NcAdded(address indexed token0, address indexed token1, NcCfg cfg);
    event NcRemoved(address indexed token0, address indexed token1);
    event NcQueueCancelled(address indexed token0, address indexed token1);
    event SwapCapLowered(address indexed token0, address indexed token1, uint128 cap, uint128 capX);
    event SwapCapQueued(address indexed token0, address indexed token1, uint128 cap, uint128 capX, uint256 eta);
    event SwapCapQueueCancelled(address indexed token0, address indexed token1);
    event SwapCapRaised(address indexed token0, address indexed token1, uint128 cap, uint128 capX);
    event SwapConsumerAdded(address consumer);
    event SwapBudgetUsed(address indexed token0, address indexed token1, bool hardLeg, uint256 value, uint256 used);
    // slow reference
    event NcSlowPoked(address indexed token0, address indexed token1, int24 twap, int24 slow);
    event NcSlowRateLowered(address indexed token0, address indexed token1, uint16 rate);
    event NcSlowRateQueued(address indexed token0, address indexed token1, uint16 rate, uint256 eta);
    event NcSlowRateQueueCancelled(address indexed token0, address indexed token1);
    event NcSlowRateRaised(address indexed token0, address indexed token1, uint16 rate);
    event FoundingRowSkipped(bool nc, uint256 index, uint8 reason);
    event FoundingSealed();
    // swap-only pause
    event SwapsPauseSet(bool paused);
    event SwapsUnpauseQueued(uint256 eta);
    // guardian and consumer queues
    event GuardianQueued(address newGuardian, uint256 eta);
    event SwapConsumerQueued(address consumer, uint256 eta);
    event SwapConsumerRemoved(address consumer);

    error MarketClosed();
    error NotQueued();
    error InvalidPair(uint8 reason);
    error RenounceOwnershipDisabled();
    // swap budgets and the swap-only pause
    error SwapBudgetExceeded(uint256 value, uint256 room);
    error SwapsOff();
    error NcTwapUnavailable(address pool);
    error SwapsPaused();
    // the reference's TWAP900 is outside G of SR (speed limit)
    error NcSlowFar(int24 twap, int24 slow);

    // InvalidPair reason codes
    uint8 internal constant P_ORDER = 1; // token0 >= token1 or a zero address
    uint8 internal constant P_FEED = 2; // no feed, no code, or decimals() mismatch
    uint8 internal constant P_TOKEN = 3; // token decimals() mismatch
    uint8 internal constant P_BOUNDS = 4; // answer bounds, or the current answer outside them
    uint8 internal constant P_AGE = 5; // maxAge outside [1 h, 4 days]
    uint8 internal constant P_GATE = 6; // gate 0 or > MAX_GATE
    uint8 internal constant P_FEE = 7; // gateHighFee (if not 0) below gate or above MAX_GATE
    uint8 internal constant P_VETO = 8; // no veto pool, not a factory pool of this pair, or cardinality too low
    uint8 internal constant P_VETO_DEPTH = 9; // source VD4 depth < MIN_VETO_DEPTH_USD (or the walk limit was exceeded)
    uint8 internal constant P_STALE = 11; // feed round dead, in the future, inconsistent or older than the listing bound
    uint8 internal constant P_ANCHOR = 12; // CL anchor not computable, |tick| too large, or > MAX_GATE from the veto TWAP900
    uint8 internal constant P_NC = 10; // CL/NC clash, zero cap or capX, SR rate out of bounds, or a capIn0 change

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) revert Unauthorized();
        _;
    }

    // Founding happens in two steps: the constructor only stores the hashes of the compile-time founding lists
    // (GoatFoundingPairs, GoatFoundingNc); before the seal, the owner writes the rows with
    // seedFounding / seedFoundingNc (the FULL list in calldata, matching the hash), each row passing the SAME checks as
    // queuePair / queueNc, then calls seal(). Checking and writing every founding row in one constructor would exceed
    // the block gas limit. A row that fails its checks does not stop the seeding; it is skipped (FoundingRowSkipped),
    // so one row that drifted out of bounds cannot block the whole founding. A skipped row can be seeded again before
    // the seal, or added later through the 24 h queue. An unsealed table cannot be bound by AutoRange or AutoExit
    // (GoatRobinhood._setPairTable).
    constructor() {
        if (block.chainid != 4663) revert InvalidConfig();
        clFoundingHash = keccak256(abi.encode(GoatFoundingPairs.rows()));
        ncFoundingHash = keccak256(abi.encode(GoatFoundingNc.rows()));
    }

    function seedFounding(PairRow[] calldata rows, uint256 from, uint256 to) external onlyOwner {
        if (foundingSealed || keccak256(abi.encode(rows)) != clFoundingHash || from >= to || to > rows.length) {
            revert InvalidConfig();
        }
        for (uint256 i = from; i < to; ++i) {
            uint8 r = _checkCl(rows[i].token0, rows[i].token1, rows[i].cfg);
            if (r == 0) _listCl(rows[i].token0, rows[i].token1, rows[i].cfg);
            else emit FoundingRowSkipped(false, i, r);
        }
    }

    function seedFoundingNc(NcRow[] calldata rows, uint256 from, uint256 to) external onlyOwner {
        if (foundingSealed || keccak256(abi.encode(rows)) != ncFoundingHash || from >= to || to > rows.length) {
            revert InvalidConfig();
        }
        for (uint256 i = from; i < to; ++i) {
            uint8 r = _checkNc(rows[i].token0, rows[i].token1, rows[i].cfg);
            if (r == 0) _listNc(rows[i].token0, rows[i].token1, rows[i].cfg);
            else emit FoundingRowSkipped(true, i, r);
        }
    }

    function seal() external onlyOwner {
        if (foundingSealed) revert InvalidConfig();
        foundingSealed = true;
        emit FoundingSealed();
    }

    // ------------------------------------------------------------------ administration
    // add or change: with addPair after 24 h (watchers are alerted by PairQueued during the wait)
    function queuePair(address token0, address token1, PairCfg calldata cfg) external onlyOwner {
        _validate(token0, token1, cfg);
        uint256 eta = block.timestamp + TIMELOCK;
        _pending[token0][token1] = Pending(cfg, eta);
        emit PairQueued(token0, token1, eta, cfg);
    }

    function addPair(address token0, address token1) external onlyOwner {
        Pending memory p = _pending[token0][token1];
        if (p.eta == 0 || block.timestamp < p.eta) revert NotQueued();
        // a stale entry (after eta + 7 days) needs a new queuePair
        if (block.timestamp > p.eta + QUEUE_GRACE) revert NotQueued();
        // a change that clears a feed's marketHours flag and was queued before (or in the same second as) the last
        // closure needs a new queue, so a later closeMarket stays in force
        PairCfg storage o = _pairs[token0][token1];
        if (
            ((o.feed0.marketHours && !p.cfg.feed0.marketHours) || (o.feed1.marketHours && !p.cfg.feed1.marketHours))
                && p.eta - TIMELOCK <= lastClosureAt
        ) revert NotQueued();
        _validate(token0, token1, p.cfg);
        delete _pending[token0][token1];
        // a new CL row's budget is UNLIMITED; a change to an existing row does NOT touch the budget (a swap closure by
        // the guardian cannot be undone by a change queued before it)
        _listCl(token0, token1, p.cfg);
    }

    // removal is instant (owner or guardian); a pending addition is deleted too
    function removePair(address token0, address token1) external onlyOwnerOrGuardian {
        bool had = _pairs[token0][token1].feed0.proxy != address(0);
        // removePair on an NC row reverts (use removeNc) instead of succeeding silently
        if (!had && _nc[token0][token1].refPool != address(0)) revert InvalidPool();
        // if a CL row exists its budget is deleted too (cap 0 = swaps closed; a pending raise as well)
        if (had) {
            _dropBudget(token0, token1);
            delete _pairs[token0][token1];
        }
        if (_pending[token0][token1].eta != 0) {
            delete _pending[token0][token1];
            emit PairQueueCancelled(token0, token1);
        }
        // a pending NC listing of the pair is cancelled too
        if (_ncPending[token0][token1].eta != 0) {
            delete _ncPending[token0][token1];
            emit NcQueueCancelled(token0, token1);
        }
        // events only for real changes
        if (had) emit PairRemoved(token0, token1);
    }

    function cancelPair(address token0, address token1) external onlyOwnerOrGuardian {
        if (_pending[token0][token1].eta != 0) {
            delete _pending[token0][token1];
            emit PairQueueCancelled(token0, token1);
        }
    }

    // the guardian hands its role over (or resigns, g = 0) immediately; the owner sets the FIRST guardian immediately
    // and replaces a sitting one only through queueGuardian -> applyGuardian (24 h, until eta + 7 days). The sitting
    // guardian cannot cancel its own replacement (so the owner can always replace it); during the 24 h it can still
    // cancel or pause any widening the owner queued alongside.
    function setGuardian(address g) external {
        if (msg.sender != guardian || guardian == address(0)) {
            _checkOwner();
            if (guardian != address(0)) revert NotQueued();
            _setGuardian(g);
            return;
        }
        // a guardian handover (or a "handover" to itself) keeps the owner's queued replacement, so the sitting guardian
        // cannot void the 24 h queue right before applyGuardian
        guardian = g;
        emit GuardianChanged(g);
    }

    function queueGuardian(address g) external onlyOwner {
        uint256 eta = block.timestamp + TIMELOCK;
        pendingGuardian = g;
        guardianEta = eta;
        emit GuardianQueued(g, eta);
    }

    function applyGuardian() external onlyOwner {
        _requireReady(guardianEta);
        _setGuardian(pendingGuardian);
    }

    function cancelGuardian() external onlyOwner {
        if (guardianEta != 0) {
            delete pendingGuardian;
            delete guardianEta;
            emit GuardianQueued(address(0), 0);
        }
    }

    function _setGuardian(address g) internal {
        guardian = g;
        delete pendingGuardian;
        delete guardianEta;
        emit GuardianChanged(g);
    }

    // holiday closure (only narrows the service, so instant): hour indexes [fromHour, toHour) (ts / 3600), at most 96
    // hours, ending in the future and at most 7 days ahead. It ends by itself; the owner can reopen early with
    // reopenMarket.
    function closeMarket(uint256 fromHour, uint256 toHour) external onlyOwnerOrGuardian {
        uint256 nowH = block.timestamp / 1 hours;
        if (
            toHour <= fromHour || toHour - fromHour > MAX_CLOSURE_HOURS || toHour <= nowH
                || toHour > nowH + MAX_CLOSURE_AHEAD_HOURS
        ) {
            revert InvalidConfig();
        }
        for (uint256 h = fromHour; h < toHour; ++h) {
            closedHourBits[h >> 8] |= uint256(1) << (h & 255);
        }
        // reopens queued BEFORE this moment cannot clear this closure
        lastClosureAt = block.timestamp;
        emit MarketClosureAdded(fromHour, toHour);
    }

    // a reopen WIDENS the service, so like an addition it is owner only with a 24 h timelock (queueReopen ->
    // reopenMarket); the guardian or the owner can cancel a pending one (narrowing). Range: [fromHour, toHour), at
    // most MAX_CLOSURE_AHEAD_HOURS hours.
    function queueReopen(uint256 fromHour, uint256 toHour) external onlyOwner {
        if (toHour <= fromHour || toHour - fromHour > MAX_CLOSURE_AHEAD_HOURS) revert InvalidConfig();
        uint256 eta = block.timestamp + TIMELOCK;
        reopenEta[keccak256(abi.encode(fromHour, toHour))] = eta;
        emit MarketReopenQueued(fromHour, toHour, eta);
    }

    function reopenMarket(uint256 fromHour, uint256 toHour) external onlyOwner {
        bytes32 k = keccak256(abi.encode(fromHour, toHour));
        uint256 eta = reopenEta[k];
        if (eta == 0 || block.timestamp < eta) revert NotQueued();
        // a stale entry (after eta + 7 days) needs a new queueReopen
        if (block.timestamp > eta + QUEUE_GRACE) revert NotQueued();
        // if the queueing time (eta - TIMELOCK) is not after the last closure, a new queue is needed ('<=': a closure
        // added in the queueing second stays in force too)
        if (eta - TIMELOCK <= lastClosureAt) revert NotQueued();
        delete reopenEta[k];
        for (uint256 h = fromHour; h < toHour; ++h) {
            closedHourBits[h >> 8] &= ~(uint256(1) << (h & 255));
        }
        emit MarketReopened(fromHour, toHour);
    }

    function cancelReopen(uint256 fromHour, uint256 toHour) external onlyOwnerOrGuardian {
        bytes32 k = keccak256(abi.encode(fromHour, toHour));
        if (reopenEta[k] != 0) {
            delete reopenEta[k];
            emit MarketReopenCancelled(fromHour, toHour); // only for a real change
        }
    }

    // ------------------------------------------------------------------ NC rows (same roles as CL rows)
    // add or change: 24 h timelock (queueNc -> addNc, until eta + 7 days); removal and queue cancellation are instant
    // (owner or guardian)
    function queueNc(address token0, address token1, NcCfg calldata cfg) external onlyOwner {
        _validateNc(token0, token1, cfg);
        uint256 eta = block.timestamp + TIMELOCK;
        _ncPending[token0][token1] = NcPending(cfg, eta);
        emit NcQueued(token0, token1, eta, cfg);
    }

    function addNc(address token0, address token1) external onlyOwner {
        NcPending memory q = _ncPending[token0][token1];
        _requireReady(q.eta);
        // a true -> false marketHours change queued before (or in the same second as) the last closure needs a new
        // queue, so closeMarket and the SR freeze stay in force
        if (_nc[token0][token1].marketHours && !q.cfg.marketHours && q.eta - TIMELOCK <= lastClosureAt) revert NotQueued();
        _validateNc(token0, token1, q.cfg);
        delete _ncPending[token0][token1];
        _listNc(token0, token1, q.cfg);
    }

    function removeNc(address token0, address token1) external onlyOwnerOrGuardian {
        bool had = _nc[token0][token1].refPool != address(0);
        // removeNc on a CL row reverts (use removePair) instead of succeeding silently
        if (!had && _pairs[token0][token1].feed0.proxy != address(0)) revert InvalidPool();
        if (had) {
            delete _nc[token0][token1];
            _dropBudget(token0, token1);
            // a pending rate raise is deleted. SR is KEPT (no poke can move it while the row is absent): a re-listing
            // resumes from it instead of starting again from the TWAP900 at re-listing time
            _cancelRateRaise(token0, token1);
        }
        if (_ncPending[token0][token1].eta != 0) {
            delete _ncPending[token0][token1];
            emit NcQueueCancelled(token0, token1);
        }
        // a pending CL listing of the pair is cancelled too
        if (_pending[token0][token1].eta != 0) {
            delete _pending[token0][token1];
            emit PairQueueCancelled(token0, token1);
        }
        if (had) emit NcRemoved(token0, token1); // only for a real change
    }

    function cancelNc(address token0, address token1) external onlyOwnerOrGuardian {
        if (_ncPending[token0][token1].eta != 0) {
            delete _ncPending[token0][token1];
            emit NcQueueCancelled(token0, token1);
        }
    }

    // ------------------------------------------------------------------ swap budgets
    // LOWERING is instant (owner or guardian; it narrows the service): each of the two budgets (hard cap, X capX) lower
    // or equal, at least one strictly lower; 0 = swaps closed on that leg (lowerSwapCap(..., 0, 0): the pair's swaps
    // closed); on a CL row only (0, 0). A pending raise is deleted (a raise queued before the lowering cannot undo it).
    function lowerSwapCap(address token0, address token1, uint128 cap, uint128 capX) external onlyOwnerOrGuardian {
        bool cl = _listedKind(token0, token1);
        SwapBudget storage b = swapBudget[token0][token1];
        SwapBudget storage x = swapBudgetX[token0][token1];
        if (cap > b.cap || capX > x.cap || (cap == b.cap && capX == x.cap) || (cl && (cap != 0 || capX != 0))) {
            revert InvalidConfig();
        }
        // settle at the old cap's leak rate before the cap changes
        _setCap(b, cap);
        _setCap(x, capX);
        _cancelCapRaise(token0, token1);
        emit SwapCapLowered(token0, token1, cap, capX);
    }

    // RAISING is owner only, with a 24 h queue (until eta + 7 days): each budget higher or equal, at least one strictly
    // higher; CAP_UNLIMITED = that budget is off ("budget OFF"); on a CL row only (UNLIMITED, UNLIMITED), which reopens
    // swaps
    function queueSwapCap(address token0, address token1, uint128 cap, uint128 capX) external onlyOwner {
        bool cl = _listedKind(token0, token1);
        uint128 c0 = swapBudget[token0][token1].cap;
        uint128 cx = swapBudgetX[token0][token1].cap;
        if (cap < c0 || capX < cx || (cap == c0 && capX == cx) || (cl && (cap != CAP_UNLIMITED || capX != CAP_UNLIMITED))) {
            revert InvalidConfig();
        }
        uint256 eta = block.timestamp + TIMELOCK;
        _capPending[token0][token1] = CapPending(cap, capX, eta);
        emit SwapCapQueued(token0, token1, cap, capX, eta);
    }

    function applySwapCap(address token0, address token1) external onlyOwner {
        CapPending memory q = _capPending[token0][token1];
        _requireReady(q.eta);
        _listedKind(token0, token1);
        delete _capPending[token0][token1];
        _setCap(swapBudget[token0][token1], q.cap); // settles at the old cap first
        _setCap(swapBudgetX[token0][token1], q.capX);
        emit SwapCapRaised(token0, token1, q.cap, q.capX);
    }

    // the owner or guardian cancels a pending raise directly (also when the cap is at its floor)
    function cancelSwapCap(address token0, address token1) external onlyOwnerOrGuardian {
        _cancelCapRaise(token0, token1);
    }

    // bound consumers (AutoRange and AutoExit, after their deployment): an address with code. A wrong consumer could
    // only use up budgets. Adding is instant only before seal(); after the seal it waits 24 h (queueSwapConsumer, until
    // eta + 7 days). Removal is instant (owner or guardian).
    function addSwapConsumer(address c) external onlyOwner {
        if (c.code.length == 0) revert InvalidConfig();
        if (foundingSealed) {
            _requireReady(swapConsumerEta[c]);
            delete swapConsumerEta[c];
        }
        if (!swapConsumer[c]) {
            swapConsumer[c] = true;
            _consumers.push(c);
        }
        emit SwapConsumerAdded(c);
    }

    function queueSwapConsumer(address c) external onlyOwner {
        if (c.code.length == 0 || swapConsumer[c]) revert InvalidConfig();
        uint256 eta = block.timestamp + TIMELOCK;
        swapConsumerEta[c] = eta;
        emit SwapConsumerQueued(c, eta);
    }

    function removeSwapConsumer(address c) external onlyOwnerOrGuardian {
        bool changed = swapConsumerEta[c] != 0 || swapConsumer[c];
        delete swapConsumerEta[c];
        if (swapConsumer[c]) {
            swapConsumer[c] = false;
            uint256 n = _consumers.length;
            for (uint256 i; i < n; ++i) {
                if (_consumers[i] == c) {
                    _consumers[i] = _consumers[n - 1];
                    _consumers.pop();
                    break;
                }
            }
        }
        if (changed) emit SwapConsumerRemoved(c);
    }

    function swapConsumers() external view returns (address[] memory) {
        return _consumers;
    }

    /// @notice Charges a swap flow's input (for AutoRange: the principal of both legs) to the pair's budget; bound
    ///         consumers only, called BEFORE the swap. The input counts in its OWN leg's budget, in its OWN raw units
    ///         (hard leg: swapBudget, X: swapBudgetX); the anchor price is never used in the accounting. UNLIMITED:
    ///         returns without a write; 0: SwapsOff; otherwise a leaky bucket:
    ///         used = max(0, used - cap * dt / SWAP_CAP_WINDOW) + input <= cap, else SwapBudgetExceeded(input, room).
    function consumeSwap(address token0, address token1, bool zeroForOne, uint256 amountIn) external {
        if (!swapConsumer[msg.sender]) revert Unauthorized();
        bool hard = zeroForOne == _nc[token0][token1].capIn0;
        SwapBudget storage b = hard ? swapBudget[token0][token1] : swapBudgetX[token0][token1];
        uint256 cap = b.cap;
        if (cap == CAP_UNLIMITED) return;
        if (cap == 0) revert SwapsOff();
        (uint256 used, uint256 room) = _leaked(b, cap);
        if (amountIn > room) revert SwapBudgetExceeded(amountIn, room);
        // exact leak: a zero input writes nothing, and a non-empty bucket moves `at` only by whole windows (one window
        // leaks exactly cap), so the fractional leak of the running window is never dropped
        if (amountIn == 0) return;
        uint256 stored = used + amountIn;
        uint256 at = block.timestamp;
        if (used != 0) {
            uint256 k = (block.timestamp - b.at) / SWAP_CAP_WINDOW;
            uint256 s2 = uint256(b.used) - k * cap + amountIn;
            if (s2 <= type(uint128).max) (stored, at) = (s2, b.at + k * SWAP_CAP_WINDOW);
        }
        b.used = uint128(stored);
        b.at = uint64(at);
        emit SwapBudgetUsed(token0, token1, hard, amountIn, used + amountIn);
    }

    // ------------------------------------------------------------------ slow reference (SR)
    /// @notice Permissionless: moves SR toward the reference's TWAP900 by at most
    ///         slowRate * min(dt, NC_SLOW_MAX_DT) / 3600 ticks (NcTwapUnavailable if the TWAP900 cannot be read;
    ///         InvalidPool for an unlisted pair).
    function pokeNcSlow(address token0, address token1) public returns (int24 slow) {
        NcCfg storage n = _nc[token0][token1];
        if (n.refPool == address(0)) revert InvalidPool();
        NcSlow storage s = ncSlow[token0][token1];
        int24 t = _twapOrRevert(n.refPool, NC_TWAP_WINDOW);
        uint32 at;
        // on a frozen pair SR stays where it is and its timestamp becomes now
        (slow, at) = _slowNow(token0, token1, n, t);
        s.tick = slow;
        s.at = at;
        emit NcSlowPoked(token0, token1, t, slow);
    }

    // batch poke: if one fails, all revert (fail closed)
    function pokeNcSlowMany(address[] calldata t0s, address[] calldata t1s) external {
        if (t0s.length != t1s.length) revert InvalidConfig();
        for (uint256 i; i < t0s.length; ++i) {
            pokeNcSlow(t0s[i], t1s[i]);
        }
    }

    /// @notice Keeper view: the stored SR, the SR a poke would set now (used by anchor()), the rate and the time of
    ///         the last step.
    function slowOf(address token0, address token1)
        external
        view
        returns (int24 stored, int24 virtualNow, uint16 rate, uint32 at)
    {
        NcCfg storage n = _nc[token0][token1];
        if (n.refPool == address(0)) revert InvalidPool();
        NcSlow storage s = ncSlow[token0][token1];
        (stored, rate, at) = (s.tick, n.slowRate, s.at);
        (virtualNow,) = _slowNow(token0, token1, n, _twapOrRevert(n.refPool, NC_TWAP_WINDOW)); // frozen pairs keep SR
    }

    // LOWERING the rate is instant (owner or guardian): strictly lower and >= NC_SLOW_MIN_RATE; deletes a pending raise
    function lowerSlowRate(address token0, address token1, uint16 rate) external onlyOwnerOrGuardian {
        NcCfg storage n = _nc[token0][token1];
        if (n.refPool == address(0)) revert InvalidPool();
        if (rate >= n.slowRate || rate < NC_SLOW_MIN_RATE) revert InvalidConfig();
        n.slowRate = rate;
        _cancelRateRaise(token0, token1);
        emit NcSlowRateLowered(token0, token1, rate);
    }

    // RAISING the rate is owner only with a 24 h queue (until eta + 7 days): strictly higher and <= NC_SLOW_MAX_RATE
    function queueSlowRate(address token0, address token1, uint16 rate) external onlyOwner {
        NcCfg storage n = _nc[token0][token1];
        if (n.refPool == address(0)) revert InvalidPool();
        if (rate <= n.slowRate || rate > NC_SLOW_MAX_RATE) revert InvalidConfig();
        uint256 eta = block.timestamp + TIMELOCK;
        _ratePending[token0][token1] = RatePending(rate, eta);
        emit NcSlowRateQueued(token0, token1, rate, eta);
    }

    function applySlowRate(address token0, address token1) external onlyOwner {
        RatePending memory q = _ratePending[token0][token1];
        _requireReady(q.eta);
        NcCfg storage n = _nc[token0][token1];
        if (n.refPool == address(0)) revert InvalidPool();
        // settle SR at the OLD rate first; the raise applies from now on
        pokeNcSlow(token0, token1);
        ncSlow[token0][token1].at = uint32(block.timestamp);
        delete _ratePending[token0][token1];
        n.slowRate = q.rate;
        emit NcSlowRateRaised(token0, token1, q.rate);
    }

    // the owner or guardian cancels a pending rate raise directly (also at NC_SLOW_MIN_RATE)
    function cancelSlowRate(address token0, address token1) external onlyOwnerOrGuardian {
        _cancelRateRaise(token0, token1);
    }

    // ------------------------------------------------------------------ swap-only pause
    // owner or guardian, instant; also deletes a pending unpause. Swap-less exits (which do not read the table) go on.
    function pauseSwaps() external onlyOwnerOrGuardian {
        swapsPaused = true;
        if (swapsUnpauseEta != 0) {
            delete swapsUnpauseEta;
            emit SwapsUnpauseQueued(0);
        }
        emit SwapsPauseSet(true);
    }

    function queueUnpauseSwaps() external onlyOwner {
        if (!swapsPaused) revert InvalidConfig();
        uint256 eta = block.timestamp + TIMELOCK;
        swapsUnpauseEta = eta;
        emit SwapsUnpauseQueued(eta);
    }

    function unpauseSwaps() external onlyOwner {
        _requireReady(swapsUnpauseEta);
        delete swapsUnpauseEta;
        swapsPaused = false;
        emit SwapsPauseSet(false);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    // ------------------------------------------------------------------ reads (AutoRange, AutoExit)
    // Anchor: tick and sqrtPriceX96 of the token1/token0 raw-unit price, plus the pair's gate and veto pool. Reverts on
    // any problem. During the swap-only pause every row reverts with SwapsPaused; without a CL row the NC row is used
    // (_ncAnchor).
    function anchor(address token0, address token1, uint24 fee)
        external
        view
        returns (int24 tick, uint160 sqrtPriceX96, uint16 gate, address vetoPool)
    {
        if (swapsPaused) revert SwapsPaused();
        // a stock token in a corporate-action window (oraclePaused()) has no fresh price
        _requireOracleLive(token0);
        _requireOracleLive(token1);
        PairCfg storage c = _pairs[token0][token1];
        if (c.feed0.proxy == address(0)) return _ncAnchor(token0, token1, fee);
        gate = _gateFor(fee, c.gate, c.gateHighFee); // canonical tiers only
        if (gate == 0) revert NotSupportedFeeTier();
        _checkSequencer();
        uint256 p0 = _readFeed(c.feed0);
        uint256 p1 = _readFeed(c.feed1);
        sqrtPriceX96 = _sqrtPrice(p0, c.feed0, p1, c.feed1);
        tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        if (_beyondNs7(tick)) revert InvalidPool(); // the |tick| bound applies to CL anchors too
        vetoPool = c.vetoPool;
    }

    // NC anchor: the reference's TWAP900 (rounded toward negative infinity; a failing observe reverts with
    // NcTwapUnavailable), |tick| <= NC_MAX_ABS_TICK, and the calendar on a marketHours row (weekend, closed hours;
    // there is no feed round). The veto pool is the reference itself, so Revert's K check in _validateSwap reduces to
    // |TWAP900 - TWAP900| = 0; the short TWAPs and the reference's spot are checked by the source gate (AutoRange,
    // AutoExit).
    function _ncAnchor(address token0, address token1, uint24 fee)
        internal
        view
        returns (int24 tick, uint160 sqrtPriceX96, uint16 gate, address vetoPool)
    {
        NcCfg storage n = _nc[token0][token1];
        vetoPool = n.refPool;
        if (vetoPool == address(0)) revert InvalidPool();
        gate = _gateFor(fee, n.gate, n.gateHighFee); // canonical tiers only
        if (gate == 0) revert NotSupportedFeeTier();
        _checkSequencer();
        if (n.marketHours && !_calendarOpen()) revert MarketClosed();
        tick = _twapOrRevert(vetoPool, NC_TWAP_WINDOW);
        if (tick > NC_MAX_ABS_TICK || tick < -NC_MAX_ABS_TICK) revert InvalidPool();
        // speed limit: the anchor (TWAP900) may not be more than G from SR's current virtual step (inclusive).
        // Whatever the price path, over T seconds the accepted anchor can move by at most G + R * (T + 300) / 3600
        // ticks. The pause and the calendar were already rejected above; a freeze here only happens on a pair whose two
        // budgets are 0 (the flow then reverts at the budget).
        (int24 slowNow,) = _slowNow(token0, token1, n, tick);
        int256 e = int256(tick) - int256(slowNow);
        if ((e < 0 ? -e : e) > int256(uint256(gate))) revert NcSlowFar(tick, slowNow);
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
    }

    // config-time coverage check (feed freshness is not required, so configs work on weekends). NC rows count as listed
    // too.
    function coverage(address token0, address token1, uint24 fee) external view returns (bool pairListed, bool feeCovered) {
        PairCfg storage c = _pairs[token0][token1];
        pairListed = c.feed0.proxy != address(0);
        feeCovered = pairListed && _gateFor(fee, c.gate, c.gateHighFee) != 0; // canonical tiers only
        if (!pairListed) {
            NcCfg storage n = _nc[token0][token1];
            pairListed = n.refPool != address(0);
            feeCovered = pairListed && _gateFor(fee, n.gate, n.gateHighFee) != 0;
        }
    }

    // size estimate for an intermediate route hop: the value of `amount` of `from` in `to` at the anchor prices. from
    // and to must be the pair's tokens or WETH/USDG (the WETH and USDG feeds come from the WETH/USDG row; reverts
    // without it).
    function quote(address token0, address token1, address from, address to, uint256 amount)
        external
        view
        returns (uint256)
    {
        FeedCfg storage f = _feedOf(token0, token1, from);
        FeedCfg storage t = _feedOf(token0, token1, to);
        uint256 pf = _readFeed(f);
        uint256 pt = _readFeed(t);
        // out = amount * (pf / 10^(fdF + decF)) / (pt / 10^(fdT + decT))
        int256 e = int256(uint256(t.feedDecimals) + t.tokenDecimals) - int256(uint256(f.feedDecimals) + f.tokenDecimals);
        if (e >= 0) return FullMath.mulDiv(amount, pf * 10 ** uint256(e), pt);
        return FullMath.mulDiv(amount, pf, pt * 10 ** uint256(-e));
    }

    function pair(address token0, address token1) external view returns (PairCfg memory) {
        return _pairs[token0][token1];
    }

    function pending(address token0, address token1) external view returns (Pending memory) {
        return _pending[token0][token1];
    }

    // anchor()'s gate choice without reading feeds, the sequencer or the calendar (for AutoRange's config-time minimum
    // width; configs work on weekends). The CL row if there is one, otherwise the NC row; canonical tiers:
    // 100/500/3000 -> gate, 10000 -> gateHighFee, any other tier or an unlisted pair -> 0 (AutoRange: InvalidConfig).
    // AutoRange keeps no copy of this rule.
    function gateFor(address token0, address token1, uint24 fee) external view returns (uint16) {
        PairCfg storage c = _pairs[token0][token1];
        if (c.feed0.proxy != address(0)) return _canonicalGate(fee, c.gate, c.gateHighFee);
        NcCfg storage n = _nc[token0][token1];
        if (n.refPool == address(0)) return 0;
        return _canonicalGate(fee, n.gate, n.gateHighFee);
    }

    function _canonicalGate(uint24 fee, uint16 g, uint16 gHigh) private pure returns (uint16) {
        if (fee == 10000) return gHigh;
        if (fee == 100 || fee == 500 || fee == 3000) return g;
        return 0;
    }

    // NC row, its queue, budget state (room including the current leak), pending raise
    function nc(address token0, address token1) external view returns (NcCfg memory) {
        return _nc[token0][token1];
    }

    function pendingNc(address token0, address token1) external view returns (NcPending memory) {
        return _ncPending[token0][token1];
    }

    function pendingSwapCap(address token0, address token1) external view returns (CapPending memory) {
        return _capPending[token0][token1];
    }

    function swapBudgetOf(address token0, address token1)
        external
        view
        returns (uint128 cap, uint256 used, uint256 room, uint64 at)
    {
        return _budgetOf(swapBudget[token0][token1]);
    }

    // X leg budget (raw X units)
    function swapBudgetXOf(address token0, address token1)
        external
        view
        returns (uint128 cap, uint256 used, uint256 room, uint64 at)
    {
        return _budgetOf(swapBudgetX[token0][token1]);
    }

    function pendingSlowRate(address token0, address token1) external view returns (RatePending memory) {
        return _ratePending[token0][token1];
    }

    function _budgetOf(SwapBudget storage b) internal view returns (uint128 cap, uint256 used, uint256 room, uint64 at) {
        cap = b.cap;
        at = b.at;
        if (cap == CAP_UNLIMITED) return (cap, 0, type(uint256).max, at);
        (used, room) = _leaked(b, cap);
    }

    /// @notice VD4 depth meter (the listing checks use the same code): a +-100 tick walk that crosses ticks
    ///         (down0: token0 input, up1: token1 input, raw units) and the 1,800 s time-weighted L.
    ///         USD = min(v(down0), v(up1)) * min(1, lTw / lNow).
    function sourceDepth(address pool) external view returns (uint256 down0, uint256 up1, uint128 lNow, uint128 lTw) {
        bool ok;
        (down0, up1, lNow,, ok) = GoatDepthLib.walk(IUniswapV3Pool(pool));
        if (!ok) revert GoatDepthLib.WalkTooLong();
        lTw = GoatDepthLib.timeWeightedL(IUniswapV3Pool(pool));
    }

    // market hours (stock/RWA class): open Monday 00:00 to Saturday 00:00 UTC, with a round since this week's opening,
    // and not a holiday
    function marketOpen(uint256 updatedAt) public view returns (bool) {
        uint256 w = (block.timestamp - MONDAY0) % 1 weeks;
        if (w >= OPEN_SPAN) return false;
        if (updatedAt < block.timestamp - w) return false;
        uint256 h = block.timestamp / 1 hours;
        // no closed hour from the round's hour to now: a closeMarket holiday is a session gap like the weekend, so a
        // round from before the holiday does not price after it (<= 121 hours, <= 2 bitmap words)
        return !_anyClosed(updatedAt < block.timestamp ? updatedAt / 1 hours : h, h);
    }

    function _anyClosed(uint256 fromH, uint256 toH) internal view returns (bool) {
        for (uint256 wd = fromH >> 8; wd <= toH >> 8; ++wd) {
            uint256 lo = wd == fromH >> 8 ? fromH & 255 : 0;
            uint256 hi = wd == toH >> 8 ? toH & 255 : 255;
            uint256 m = (hi == 255 ? type(uint256).max : (uint256(1) << (hi + 1)) - 1) & ~((uint256(1) << lo) - 1);
            if (closedHourBits[wd] & m != 0) return true;
        }
        return false;
    }

    // calendar of NC stock rows (no feed round): Monday 01:00 to Saturday 00:00 UTC, and not a closed hour
    function _calendarOpen() internal view returns (bool) {
        // opens Monday 01:00 UTC all year (the EST weekly open; one hour is lost in EDT weeks)
        uint256 w = (block.timestamp - MONDAY0) % 1 weeks;
        if (w < 1 hours || w >= OPEN_SPAN) return false;
        uint256 hr = block.timestamp / 1 hours;
        return (closedHourBits[hr >> 8] >> (hr & 255)) & 1 == 0;
    }

    // ------------------------------------------------------------------ internal
    function _feedOf(address token0, address token1, address token) internal view returns (FeedCfg storage) {
        PairCfg storage c = _pairs[token0][token1];
        if (c.feed0.proxy == address(0)) revert InvalidPool();
        if (token == token0) return c.feed0;
        if (token == token1) return c.feed1;
        PairCfg storage wu = _pairs[WETH][USDG];
        if (wu.feed0.proxy == address(0)) revert InvalidPool();
        if (token == WETH) return wu.feed0;
        if (token == USDG) return wu.feed1;
        revert InvalidToken();
    }

    // Revert's V3Oracle feed pattern plus round consistency, per-pair bounds, the early bad-round filter, market hours
    // and age
    function _readFeed(FeedCfg storage f) internal view returns (uint256) {
        // the proxy's decimals are checked again at every read
        if (AggregatorV3Interface(f.proxy).decimals() != f.feedDecimals) revert ChainlinkPriceError();
        (uint80 r, int256 a,, uint256 u, uint80 ar) = AggregatorV3Interface(f.proxy).latestRoundData();
        if (a <= 0 || a < f.minAnswer || a > f.maxAnswer || u <= FEED_EPOCH || u > block.timestamp || ar < r) {
            revert ChainlinkPriceError();
        }
        if (f.marketHours && !marketOpen(u)) revert MarketClosed();
        if (block.timestamp - u > f.maxAge) revert ChainlinkPriceError();
        return uint256(a);
    }

    // P (raw token1 / raw token0) = p0 * 10^(fd1 + dec1) / (p1 * 10^(fd0 + dec0)); sqrtPriceX96 = sqrt(P * 2^192)
    function _sqrtPrice(uint256 p0, FeedCfg storage f0, uint256 p1, FeedCfg storage f1)
        internal
        view
        returns (uint160)
    {
        int256 e = int256(uint256(f1.feedDecimals) + f1.tokenDecimals) - int256(uint256(f0.feedDecimals) + f0.tokenDecimals);
        uint256 priceX192 = e >= 0
            ? FullMath.mulDiv(p0 * 10 ** uint256(e), 1 << 192, p1)
            : FullMath.mulDiv(p0, 1 << 192, p1 * 10 ** uint256(-e));
        return uint160(Math.sqrt(priceX192));
    }

    function _checkSequencer() internal view {
        if (SEQUENCER_UPTIME_FEED != address(0)) {
            (, int256 sequencerAnswer, uint256 startedAt,,) =
                AggregatorV3Interface(SEQUENCER_UPTIME_FEED).latestRoundData();
            if (sequencerAnswer == 1) revert SequencerDown();
            if (startedAt == 0) revert SequencerUptimeFeedInvalid();
            if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD_TIME) revert SequencerGracePeriodNotOver();
        }
    }

    // the checks return a REASON CODE (0 = valid): the queue and add paths revert through _validate / _validateNc,
    // while seeding skips a founding row that fails (InvalidPair(reason))
    function _validate(address token0, address token1, PairCfg memory c) internal view {
        uint8 r = _checkCl(token0, token1, c);
        if (r != 0) revert InvalidPair(r);
    }

    function _validateNc(address token0, address token1, NcCfg memory n) internal view {
        uint8 r = _checkNc(token0, token1, n);
        if (r != 0) revert InvalidPair(r);
    }

    function _checkCl(address token0, address token1, PairCfg memory c) internal view returns (uint8) {
        if (token0 == address(0) || token0 >= token1) return P_ORDER;
        // no CL row while the pair has an NC row (removeNc first)
        if (_nc[token0][token1].refPool != address(0)) return P_NC;
        // a token whose oraclePaused() answers a non-bool word would make every anchor() revert (fail closed in
        // _requireOracleLive), so such a row is never listed
        if (!_oracleFlagOk(token0) || !_oracleFlagOk(token1)) return P_TOKEN;
        (uint8 r, uint256 a0) = _checkFeed(token0, c.feed0);
        if (r != 0) return r;
        uint256 a1;
        (r, a1) = _checkFeed(token1, c.feed1);
        if (r != 0) return r;
        if (c.gate == 0 || c.gate > MAX_GATE) return P_GATE;
        if (c.gateHighFee != 0 && (c.gateHighFee < c.gate || c.gateHighFee > MAX_GATE)) return P_FEE;
        return _checkClSource(token0, token1, c, a0, a1);
    }

    // the veto pool is REQUIRED: a pair without a source is not listed (it gets only swap-less exits, which do not read
    // the table). Source: a factory pool of this pair, ring >= 1,800, observe([1800, 900, 0]) works (P_VETO);
    // depth = the tick-crossing walk times the time weight >= MIN_VETO_DEPTH_USD (P_VETO_DEPTH).
    function _checkClSource(address token0, address token1, PairCfg memory c, uint256 a0, uint256 a1)
        internal
        view
        returns (uint8)
    {
        if (c.vetoPool == address(0)) return P_VETO;
        if (!_isPairPool(c.vetoPool, token0, token1)) return P_VETO;
        (,,, uint16 card,,,) = IUniswapV3Pool(c.vetoPool).slot0();
        if (card < MIN_VETO_CARDINALITY) return P_VETO;
        (bool obsOk, int24 t900, uint128 lTw) = _observeSource(c.vetoPool);
        if (!obsOk) return P_VETO;
        // the row must be anchorable from the listing answers (no overflow, |tick| <= NC_MAX_ABS_TICK) and its anchor
        // within K = MAX_GATE of the veto TWAP900 (the runtime 900 s veto bound): this catches feeds that price a
        // different asset pair than the veto pool, without rejecting rows over a momentary gap of size G
        (bool aOk, int24 at) = _anchorTick(a0, c.feed0, a1, c.feed1);
        if (!aOk) return P_ANCHOR;
        int256 dv = int256(at) - int256(t900);
        if ((dv < 0 ? -dv : dv) > int256(uint256(MAX_GATE))) return P_ANCHOR;
        (bool wOk, uint256 usd) = _vd4Cl(c, a0, a1, lTw);
        if (!wOk || usd < MIN_VETO_DEPTH_USD) return P_VETO_DEPTH;
        return 0;
    }

    // NC row checks (queueNc, addNc and seeding), in a fixed order (reason code in parentheses):
    //   1. order and zero address (1)
    //   2. the pair has no CL row (10)
    //   3. gate (6) and high-fee gate (7)
    //   4. cap and capX not 0, SR rate within [150, 4000], hard leg (capIn0) of an existing row unchanged (10)
    //   5. token decimals readable and <= 30, oraclePaused() answer is a bool (3)
    //   6. hard-leg feed (2/3/4/5/11)
    //   7. the reference is a factory pool of this pair (8)
    //   8. |spot| <= NC_MAX_ABS_TICK (4)
    //   9. ring >= 1,800 (8)
    //   10. observe([1800, 900, 0]) works (8)
    //   11. |TWAP900| <= NC_MAX_ABS_TICK (4)
    //   12. calm listing: |spot - TWAP900| <= G (4)
    //   13. VD4 depth >= MIN_VETO_DEPTH_USD, X valued via the reference's TWAP900 and the hard feed (9)
    function _checkNc(address token0, address token1, NcCfg memory n) internal view returns (uint8) {
        if (token0 == address(0) || token0 >= token1) return P_ORDER;
        if (_pairs[token0][token1].feed0.proxy != address(0)) return P_NC;
        if (n.gate == 0 || n.gate > NC_MAX_GATE) return P_GATE;
        if (n.gateHighFee != 0 && (n.gateHighFee < n.gate || n.gateHighFee > NC_MAX_GATE)) return P_FEE;
        if (n.cap == 0) return P_NC;
        // capX 0 is not accepted; the SR rate must lie in [150, 4000] ticks per hour
        if (n.capX == 0) return P_NC;
        if (n.slowRate < NC_SLOW_MIN_RATE || n.slowRate > NC_SLOW_MAX_RATE) return P_NC;
        // the hard leg of an existing row does not change (the budgets would swap units, and an X budget lowered by the
        // guardian would become the hard input's budget); to change the hard leg use removeNc + queueNc (a new row)
        NcCfg storage old = _nc[token0][token1];
        if (old.refPool != address(0) && old.capIn0 != n.capIn0) return P_NC;
        if (!_decimalsOk(token0) || !_decimalsOk(token1)) return P_TOKEN;
        // same oraclePaused() answer check as _checkCl
        if (!_oracleFlagOk(token0) || !_oracleFlagOk(token1)) return P_TOKEN;
        (uint8 r, uint256 aHard) = _checkFeed(n.capIn0 ? token0 : token1, n.hardFeed);
        if (r != 0) return r;
        return _checkNcSource(token0, token1, n, aHard);
    }

    function _checkNcSource(address token0, address token1, NcCfg memory n, uint256 aHard) internal view returns (uint8) {
        if (!_isPairPool(n.refPool, token0, token1)) return P_VETO;
        (, int24 spot,, uint16 ring,,,) = IUniswapV3Pool(n.refPool).slot0();
        if (_beyondNs7(spot)) return P_BOUNDS;
        if (MIN_VETO_CARDINALITY > ring) return P_VETO;
        (bool obsOk, int24 t900, uint128 lTw) = _observeSource(n.refPool);
        if (!obsOk) return P_VETO;
        if (_beyondNs7(t900)) return P_BOUNDS;
        int256 dd = int256(spot) - int256(t900);
        if ((dd < 0 ? -dd : dd) > int256(uint256(n.gate))) return P_BOUNDS;
        (bool wOk, uint256 usd) = _vd4Nc(n, aHard, t900, lTw);
        if (!wOk || usd < MIN_VETO_DEPTH_USD) return P_VETO_DEPTH;
        return 0;
    }

    // source identity: has code, holds this pair's tokens, registered in the factory (independent of PoolAddress)
    function _isPairPool(address pool, address token0, address token1) internal view returns (bool) {
        IUniswapV3Pool v = IUniswapV3Pool(pool);
        return pool.code.length != 0 && v.token0() == token0 && v.token1() == token1
            && IUniswapV3Factory(V3_FACTORY).getPool(token0, token1, v.fee()) == pool;
    }

    // |tick| > NC_MAX_ABS_TICK
    function _beyondNs7(int24 t) internal pure returns (bool) {
        return t > NC_MAX_ABS_TICK || t < -NC_MAX_ABS_TICK;
    }

    function _decimalsOk(address token) internal view returns (bool) {
        (bool ok, uint256 d) = _decimalsOf(token);
        return ok && d <= NC_MAX_DECIMALS;
    }

    // decimals() through a checked staticcall: no code, a failure or a short answer -> false (a reason code instead of
    // a data-less revert); answers above 255 are representable and fail the <= 30 cap
    function _decimalsOf(address a) internal view returns (bool, uint256) {
        if (a.code.length == 0) return (false, 0);
        (bool ok, bytes memory r) = a.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || r.length < 32) return (false, 0);
        return (true, abi.decode(r, (uint256)));
    }

    // listing observe: [1800, 900, 0] -> TWAP900 (rounded toward negative infinity) and the 1,800 s time-weighted L; a
    // failure gives ok = false
    function _observeSource(address pool) internal view returns (bool ok, int24 twap900, uint128 lTw) {
        uint32[] memory ago = new uint32[](3);
        ago[0] = GoatDepthLib.VD4_TW_WINDOW;
        ago[1] = NC_TWAP_WINDOW;
        try IUniswapV3Pool(pool).observe(ago) returns (int56[] memory tc, uint160[] memory spl) {
            if (tc.length != 3 || spl.length != 3) return (false, 0, 0);
            return (true, _floorMean(tc[2] - tc[1], NC_TWAP_WINDOW), GoatDepthLib.twFromSpl(spl[0], spl[2]));
        } catch {
            return (false, 0, 0);
        }
    }

    // VD4 of a CL row (USD): valued with the row's feed answers (a0, a1), the smaller of the two directions times the
    // time weight
    function _vd4Cl(PairCfg memory c, uint256 a0, uint256 a1, uint128 lTw) internal view returns (bool, uint256) {
        (uint256 d0, uint256 u1, uint128 lNow,, bool ok) = GoatDepthLib.walk(IUniswapV3Pool(c.vetoPool));
        if (!ok) return (false, 0);
        uint256 v0 = FullMath.mulDiv(d0, a0, 10 ** (uint256(c.feed0.feedDecimals) + c.feed0.tokenDecimals));
        uint256 v1 = FullMath.mulDiv(u1, a1, 10 ** (uint256(c.feed1.feedDecimals) + c.feed1.tokenDecimals));
        return (true, GoatDepthLib.applyTimeWeight(v0 < v1 ? v0 : v1, lNow, lTw));
    }

    // VD4 of an NC row (USD): the X leg converted to raw hard-leg units at the reference's TWAP900, then to USD with
    // the hard feed
    function _vd4Nc(NcCfg memory n, uint256 aHard, int24 t900, uint128 lTw) internal view returns (bool, uint256) {
        (uint256 d0, uint256 u1, uint128 lNow,, bool ok) = GoatDepthLib.walk(IUniswapV3Pool(n.refPool));
        if (!ok) return (false, 0);
        uint160 sp = TickMath.getSqrtRatioAtTick(t900);
        uint256 k = 10 ** (uint256(n.hardFeed.feedDecimals) + n.hardFeed.tokenDecimals);
        uint256 v0 = FullMath.mulDiv(n.capIn0 ? d0 : _convertAt(d0, true, sp), aHard, k);
        uint256 v1 = FullMath.mulDiv(n.capIn0 ? _convertAt(u1, false, sp) : u1, aHard, k);
        return (true, GoatDepthLib.applyTimeWeight(v0 < v1 ? v0 : v1, lNow, lTw));
    }

    // ------------------------------------------------------------------ internal helpers
    // writes a CL row: a new row's budget is UNLIMITED; a change to an existing row leaves the budget alone
    function _listCl(address token0, address token1, PairCfg memory c) internal {
        if (_pairs[token0][token1].feed0.proxy == address(0)) {
            swapBudget[token0][token1] = SwapBudget(CAP_UNLIMITED, 0, 0);
            swapBudgetX[token0][token1] = SwapBudget(CAP_UNLIMITED, 0, 0); // X leg budget
        }
        _pairs[token0][token1] = c;
        emit PairAdded(token0, token1, c);
    }

    // writes an NC row: for a new row the budget = cfg.cap (empty, now); a change to an existing row can only LOWER the
    // budget (raising goes through its own 24 h queue, so a change queued earlier cannot undo a lowering by the
    // guardian). The X budget follows the same rule. For a new row SR starts at the reference's current TWAP900; a
    // change to an existing row keeps SR (no jump) and can only LOWER the rate (raising is queueSlowRate, 24 h).
    function _listNc(address token0, address token1, NcCfg memory n) internal {
        SwapBudget storage b = swapBudget[token0][token1];
        SwapBudget storage x = swapBudgetX[token0][token1];
        NcCfg storage old = _nc[token0][token1];
        if (old.refPool == address(0)) {
            swapBudget[token0][token1] = SwapBudget(n.cap, 0, uint64(block.timestamp));
            swapBudgetX[token0][token1] = SwapBudget(n.capX, 0, uint64(block.timestamp));
            // only a FIRST listing seeds SR from TWAP900; a re-listing after removeNc resumes from the kept SR (so a
            // price held at re-listing time cannot become the reference)
            NcSlow storage sr = ncSlow[token0][token1];
            if (sr.at == 0) sr.tick = _twapOrRevert(n.refPool, NC_TWAP_WINDOW);
            sr.at = uint32(block.timestamp);
        } else {
            // settle before the cap write; the stored and emitted caps are the caps in force; a narrowing cancels an
            // earlier queued raise (as lowerSwapCap and lowerSlowRate do)
            bool lowered;
            if (n.cap < b.cap) {
                lowered = true;
                _setCap(b, n.cap);
            } else {
                n.cap = b.cap;
            }
            if (n.capX < x.cap) {
                lowered = true;
                _setCap(x, n.capX);
            } else {
                n.capX = x.cap;
            }
            if (lowered) _cancelCapRaise(token0, token1);
            if (n.slowRate < old.slowRate) _cancelRateRaise(token0, token1);
            else n.slowRate = old.slowRate;
        }
        _nc[token0][token1] = n;
        emit NcAdded(token0, token1, n);
    }

    function _dropBudget(address token0, address token1) internal {
        delete swapBudget[token0][token1];
        delete swapBudgetX[token0][token1]; // X leg budget
        _cancelCapRaise(token0, token1);
    }

    // deletes a pending SR rate raise
    function _cancelRateRaise(address token0, address token1) internal {
        if (_ratePending[token0][token1].eta != 0) {
            delete _ratePending[token0][token1];
            emit NcSlowRateQueueCancelled(token0, token1);
        }
    }

    // one step of SR toward `target` (TWAP900): base = the last step time, or now - NC_SLOW_MAX_DT if that is older
    // (idle time is dropped); step = floor(rate * (now - base) / 3600). If the target is within one step, SR becomes
    // the target at the current time; otherwise SR moves by step and at = base + ceil(step * 3600 / rate) (rounding UP
    // carries the rest of the rounded step's time over, so frequent pokes cannot speed SR up, and rounding cannot stall
    // it).
    function _slowStep(NcSlow storage s, uint16 rate, int24 target) internal view returns (int24 slow, uint32 at) {
        uint256 base = s.at;
        if (block.timestamp - base > NC_SLOW_MAX_DT) base = block.timestamp - NC_SLOW_MAX_DT;
        uint256 step = uint256(rate) * (block.timestamp - base) / 3600;
        int256 d = int256(target) - int256(s.tick);
        if (d <= int256(step) && -d <= int256(step)) return (target, uint32(block.timestamp));
        slow = d > 0 ? int24(int256(s.tick) + int256(step)) : int24(int256(s.tick) - int256(step));
        at = uint32(base + (step * 3600 + uint256(rate) - 1) / uint256(rate));
    }

    // is the pair's swap flow closed? That is the table's swap pause, the pair's swaps closed (both budgets set to 0
    // with lowerSwapCap), or the calendar closed on a marketHours row (UTC weekend or a closeMarket hour). While
    // closed, SR is frozen: a price held during the closure cannot move SR, and after reopening SR moves on from its
    // earlier value at rate R.
    function _slowFrozen(address token0, address token1, NcCfg storage n) internal view returns (bool) {
        if (swapsPaused) return true;
        if (n.marketHours && !_calendarOpen()) return true;
        if (swapBudget[token0][token1].cap == 0 && swapBudgetX[token0][token1].cap == 0) return true;
        return _consumersPaused();
    }

    // no swap flow can run when every bound consumer (AutoRange, AutoExit) reports paused() (or none is bound): SR
    // freezes as for pauseSwaps. A consumer without a readable paused() counts as running (no freeze).
    function _consumersPaused() internal view returns (bool) {
        uint256 len = _consumers.length;
        for (uint256 i; i < len; ++i) {
            (bool ok, bytes memory r) = _consumers[i].staticcall(abi.encodeWithSignature("paused()"));
            if (!ok || r.length < 32 || abi.decode(r, (uint256)) == 0) return false;
        }
        return true;
    }

    // SR's current step: if frozen, (stored, now) (the frozen time is dropped), otherwise _slowStep
    function _slowNow(address token0, address token1, NcCfg storage n, int24 target)
        internal
        view
        returns (int24 slow, uint32 at)
    {
        NcSlow storage s = ncSlow[token0][token1];
        if (_slowFrozen(token0, token1, n)) return (s.tick, uint32(block.timestamp));
        return _slowStep(s, n.slowRate, target);
    }

    function _cancelCapRaise(address token0, address token1) internal {
        if (_capPending[token0][token1].eta != 0) {
            delete _capPending[token0][token1];
            emit SwapCapQueueCancelled(token0, token1);
        }
    }

    // the row must be listed; returns whether it is a CL row (otherwise NC)
    function _listedKind(address token0, address token1) internal view returns (bool cl) {
        cl = _pairs[token0][token1].feed0.proxy != address(0);
        if (!cl && _nc[token0][token1].refPool == address(0)) revert InvalidPool();
    }

    // newer queues: eta reached and eta + QUEUE_GRACE (inclusive) not passed
    function _requireReady(uint256 eta) internal view {
        if (eta == 0 || block.timestamp < eta || block.timestamp > eta + QUEUE_GRACE) revert NotQueued();
    }

    // settle the bucket at the OLD cap's leak rate, clamp to the new cap, then change the cap
    function _setCap(SwapBudget storage b, uint128 newCap) internal {
        uint256 old = b.cap;
        uint256 used;
        if (old != CAP_UNLIMITED && old != 0) (used,) = _leaked(b, old);
        if (used > newCap) used = newCap;
        b.used = uint128(used);
        b.at = uint64(block.timestamp);
        b.cap = newCap;
    }

    // only the canonical tiers: 100/500/3000 -> gate, 10000 -> gateHighFee, else 0 (not covered)
    function _gateFor(uint24 fee, uint16 g, uint16 gHigh) internal pure returns (uint16) {
        if (fee == 10000) return gHigh;
        if (fee == 100 || fee == 500 || fee == 3000) return g;
        return 0;
    }

    // oraclePaused() == true -> MarketClosed; no such function (WETH, USDG) -> live; a non-bool answer reverts (fail
    // closed)
    function _requireOracleLive(address token) internal view {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("oraclePaused()"));
        if (ok && r.length >= 32 && abi.decode(r, (bool))) revert MarketClosed();
    }

    // listing-time check: false only when oraclePaused() answers a 32-byte word that is not a bool (0/1), that is
    // exactly when _requireOracleLive would revert on decode for every anchor(); a paused (1) oracle is temporary and
    // does not block listing
    function _oracleFlagOk(address token) internal view returns (bool) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("oraclePaused()"));
        return !ok || r.length < 32 || abi.decode(r, (uint256)) <= 1;
    }

    // the runtime anchor formula (_sqrtPrice) without reverts: (false, 0) when P overflows (>= 2^64), the decimal
    // scaling overflows, sqrtP is outside TickMath's domain or |tick| > NC_MAX_ABS_TICK
    function _anchorTick(uint256 p0, FeedCfg memory f0, uint256 p1, FeedCfg memory f1) internal pure returns (bool, int24) {
        uint256 d0 = uint256(f0.feedDecimals) + f0.tokenDecimals;
        uint256 d1 = uint256(f1.feedDecimals) + f1.tokenDecimals;
        if (d0 > 76 || d1 > 76 || p1 == 0) return (false, 0);
        uint256 m = 10 ** (d1 >= d0 ? d1 - d0 : d0 - d1);
        uint256 num = p0;
        uint256 den = p1;
        if (d1 >= d0) {
            if (num > type(uint256).max / m) return (false, 0);
            num *= m;
        } else {
            if (den > type(uint256).max / m) return (false, 0);
            den *= m;
        }
        if (num >> 64 >= den) return (false, 0);
        uint256 sp = Math.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        if (sp < TickMath.MIN_SQRT_RATIO || sp >= TickMath.MAX_SQRT_RATIO) return (false, 0);
        int24 t = TickMath.getTickAtSqrtRatio(uint160(sp));
        if (_beyondNs7(t)) return (false, 0);
        return (true, t);
    }

    // leaky bucket: (current use, room)
    function _leaked(SwapBudget storage b, uint256 cap) internal view returns (uint256 used, uint256 room) {
        uint256 leak = FullMath.mulDiv(cap, block.timestamp - b.at, SWAP_CAP_WINDOW);
        used = b.used > leak ? b.used - leak : 0;
        room = cap > used ? cap - used : 0;
    }

    // token0 -> token1 (zeroForOne) or the reverse at the given sqrtP; in two steps (no precision loss at extreme
    // prices)
    function _convertAt(uint256 amount, bool zeroForOne, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (zeroForOne) return FullMath.mulDiv(FullMath.mulDiv(amount, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
        return FullMath.mulDiv(FullMath.mulDiv(amount, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    // mean tick of observe([w, 0]) (rounded toward negative infinity); a failure reverts with NcTwapUnavailable (fail
    // closed, no fallback)
    function _twapOrRevert(address pool, uint32 w) internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = w;
        try IUniswapV3Pool(pool).observe(ago) returns (int56[] memory tc, uint160[] memory) {
            return _floorMean(tc[1] - tc[0], w);
        } catch {
            revert NcTwapUnavailable(pool);
        }
    }

    function _floorMean(int56 d, uint32 w) internal pure returns (int24) {
        int56 ww = int56(uint56(w));
        int56 t = d / ww;
        if (d < 0 && d % ww != 0) t--;
        return int24(t);
    }


    // returns the checked answer (for the USD value of the depth; a >= minAnswer > 0) and a reason code (0 = valid, so
    // seeding can skip a row)
    function _checkFeed(address token, FeedCfg memory f) internal view returns (uint8, uint256) {
        if (f.proxy == address(0)) return (P_FEED, 0);
        // checked decimals reads and the <= 30 cap for CL feeds and tokens too (10 ** (fd + td))
        (bool ok, uint256 d) = _decimalsOf(f.proxy);
        if (!ok || d != f.feedDecimals || d > NC_MAX_DECIMALS) return (P_FEED, 0);
        (ok, d) = _decimalsOf(token);
        if (!ok || d != f.tokenDecimals || d > NC_MAX_DECIMALS) return (P_TOKEN, 0);
        if (f.maxAge < MIN_FEED_AGE || f.maxAge > MAX_FEED_AGE_LIMIT) return (P_AGE, 0);
        (uint80 rid, int256 a,, uint256 u, uint80 ar) = AggregatorV3Interface(f.proxy).latestRoundData();
        if (f.minAnswer <= 0 || f.maxAnswer <= f.minAnswer || a < f.minAnswer || a > f.maxAnswer) {
            return (P_BOUNDS, 0);
        }
        // the round that values VD4 must be live and consistent (_readFeed's round checks); age bound: the row's
        // maxAge, or MAX_FEED_AGE_LIMIT for marketHours feeds (so listing stays possible over a weekend or holiday)
        if (u <= FEED_EPOCH || u > block.timestamp || ar < rid) return (P_STALE, 0);
        if (block.timestamp - u > (f.marketHours ? MAX_FEED_AGE_LIMIT : f.maxAge)) return (P_STALE, 0);
        return (0, uint256(a));
    }
}
