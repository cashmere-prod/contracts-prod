// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GoatChainlinkFeeds} from "./GoatChainlinkFeeds.sol";

/// @dev Chainlink AggregatorV3, only the members this contract reads.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IUniV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0()
        external
        view
        returns (
            uint160,
            int24,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8,
            bool
        );
    function observations(uint256) external view returns (uint32 blockTimestamp, int56, uint160, bool initialized);
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
    function liquidity() external view returns (uint128);
}

/**
 * @notice GoatPriceAnchor: manipulation-resistant outside price for compounds. Chainlink first, then the TWAP of
 *         the single Uniswap v3 pool the owner assigned to the pair. With neither, `ok = false` and the consumer
 *         runs without an anchor.
 *
 * @dev Uniswap v4 has no oracle (v4-core has no `observe()`), and comparing a v4 spot price with itself protects
 * nothing, so the reference has to come from another venue.
 *
 * @dev The factory is never scanned: each pair has at most one v3 pool, assigned by the owner, and a pool nobody
 * assigned can never be the anchor. The approach is similar to Revert Finance's `V4Oracle`; this code is an
 * independent implementation, not a copy (theirs is BUSL-1.1).
 *
 * @dev Trust model: the owner (a multisig) chooses the sources, but every change waits `CONFIG_DELAY` (24 hours)
 * in public, emits an event and lapses if it is not applied within `CONFIG_GRACE`. The worst an owner can do is
 * point a pair at a poor pool or remove its anchor; compound consumers then risk at most the collected fees,
 * since the compound flow never withdraws principal. There is deliberately no instant override.
 *
 * @dev An assigned pool must meet these conditions (`_validatePool`, when queued and when applied):
 *  - it is the factory's canonical pool for (token0, token1, fee);
 *  - its current observation ring (`observationCardinality`, not `observationCardinalityNext`) has at least
 *    `MIN_POOL_CARDINALITY` (1801) slots. With at most one observation per second, the oldest entry then always
 *    lies more than 1800 seconds back, so the 30-minute window can always be measured. A ring grows to its
 *    `next` size only when the write index wraps around, so after `increaseObservationCardinalityNext(1801)`
 *    wait until the ring has actually grown;
 *  - `minDepth >= MIN_ANCHOR_DEPTH`. At read time the depth (the lower of a frozen and a live harmonic-mean
 *    liquidity) must be at least `minDepth`, or the anchor returns `ok = false`. A harmonic mean also drops
 *    while the price trades outside the pool's active liquidity, so only busy, wide pools are assigned,
 *    `minDepth` is set well below their usual depth, and `CompoundedWithoutAnchor` is monitored. A quiet
 *    anchor only means compounds run without one, with exposure limited to fees, not a loss of principal;
 *  - when queued, the pool must be able to serve right away (fresh TWAP, depth >= `minDepth`); when applied,
 *    depth >= `minDepth` is checked again.
 *
 * @dev Consumer rules: with `ok = false` a consumer must not swap. `GoatV4Compoundor` and the v3 compound
 * contracts then add liquidity without a swap; a flow that moves principal (such as auto-range) must reject.
 */
contract GoatPriceAnchor is Ownable2Step {
    IUniV3Factory public immutable factory;
    /// @notice v4 native ETH (address(0)) is mapped to this address, since the v3 pools hold WETH.
    address public immutable weth;

    /// @notice TWAP window: 30 minutes.
    uint32 public constant TWAP_SECONDS = 1800;

    /// @notice Smallest allowed `minDepth` (the read-time depth floor) for an assigned pool.
    uint128 public constant MIN_ANCHOR_DEPTH = 1e6;

    /// @notice Smallest current observation ring (`observationCardinality`, not the `next` value) an assigned
    /// pool must have; the reason is in the contract notes.
    uint16 public constant MIN_POOL_CARDINALITY = 1801;

    /// @notice Decimals every accepted feed must report; anything else means a wrong feed (for example an
    /// 18-decimal exchange-rate feed). Checked at deployment, on every feed change and on every read, because
    /// the aggregator behind a proxy can change without an event; a read with other decimals gives `ok = false`.
    uint8 public constant FEED_DECIMALS = 8;

    /// @notice Largest accepted feed answer: 1,000,000 USD at 8 decimals. A larger answer is treated as a
    /// corrupt round and gives `ok = false`.
    uint256 public constant MAX_FEED_ANSWER = 1e6 * 10 ** FEED_DECIMALS;

    /// @dev Above this many token decimals the Chainlink path returns `ok = false`, so the raw ratio cannot overflow.
    uint8 private constant MAX_TOKEN_DECIMALS = 36;

    /// @notice How long an owner change waits before it can be applied.
    uint256 public constant CONFIG_DELAY = 24 hours;
    /// @notice A matured change lapses if it is not applied within this time, so an old intent cannot be applied later.
    uint256 public constant CONFIG_GRACE = 14 days;

    /**
     * @notice Largest allowed age of the pool's last observation, chosen for cross-venue use.
     *
     * @dev Looser than the 180-second limit in the v3 compound contracts, because the use differs.
     * `GoatSelfCompoundor` and `GoatAutoCompoundV3` compare a pool's own spot with its own TWAP; there a stale
     * observation makes `observe` extrapolate the current tick and the check would compare spot with itself.
     * This anchor compares a v4 spot price with a v3 pool, a different venue: a v3 price stays put when the v4
     * pool moves, and arbitrage keeps the two venues aligned, so a quiet v3 pool is not a stale price. Deep
     * v4 pools often have only thin, quiet v3 counterparts, and a short limit would leave them unanchored.
     *
     * @dev The independence holds only when the consumer prices a pool other than the assigned v3 pool. A v3
     * consumer whose own pool is the assigned pool would get its own 30-minute TWAP back, so it should reject
     * the anchor when `poolFor(token0, token1)` is its own pool, and rows should use a different venue or fee
     * tier from the pools being compounded where possible. The 6-hour limit is meant for cross-venue use only.
     *
     * @dev Age and the frozen depth window are measured from the last observation before the current timestamp
     * (`_refObsTs`), so an observation written in the same block cannot reset them, and `anchor()` returns the
     * same result throughout one timestamp (apart from a one-unit rounding in live depth, see `_historicalDepth`).
     * The guarantee covers one timestamp only. Keeping assigned pools active and deep is the owner's job: an idle
     * or thin pool is removed with `queuePool(tokenA, tokenB, address(0), 0)`. A compound that runs on such a
     * pool still risks at most the fees collected in that compound.
     */
    uint32 public constant MAX_STALENESS = 6 hours;


    /**
     * @notice Chainlink USD feed per token (ETH/USD is stored under WETH). The proxy address is stored;
     * Chainlink's advice not to pin addresses concerns the aggregator behind the proxy.
     * @dev The initial table comes from `GoatChainlinkFeeds` at deployment; every later change goes through
     * `queueFeed`, a 24-hour wait, then `applyFeed`.
     */
    mapping(address => IAggregatorV3) public feedOf;

    /**
     * @notice Largest accepted age of a Chainlink answer, unless `feedMaxAge` sets a lower limit for the token.
     * @dev Stock feeds update 24/5 (Sunday 20:00 ET to Friday 20:00 ET) and keep their last value over the
     * weekend; 5 days also covers long weekends and holiday closures. When an answer is older, the anchor falls
     * back to the assigned v3 pool, or to no anchor. Where a pool drifts away from a frozen weekend price,
     * compounding waits for the market to reopen: a delay, not a loss.
     * @dev This is the default and the upper bound. Feeds that update around the clock (ETH and USDG, 24-hour
     * heartbeat) need a tighter limit, set per token in `feedMaxAge` (`queueFeedMaxAge`, a 24-hour wait, then
     * `applyFeedMaxAge`); for WETH and USDG the constructor writes 25 hours (`GoatChainlinkFeeds.initialMaxAge`),
     * so it applies from deployment.
     */
    uint256 public constant MAX_FEED_AGE = 5 days;

    /// @notice Smallest non-zero value `queueFeedMaxAge` accepts, to catch unit mistakes (0 means the default).
    uint256 public constant MIN_FEED_MAX_AGE = 1 hours;

    /**
     * @notice Per-token largest age of a Chainlink answer, in seconds; 0 means `MAX_FEED_AGE`.
     * @dev Keyed by token, not by feed: the limit stays when `applyFeed` changes the feed, so a feed with a
     * different schedule needs its own queued limit. It can only tighten (at most `MAX_FEED_AGE`), which gives
     * the owner no power beyond what `queueFeed(token, address(0))` already gives.
     */
    mapping(address => uint32) public feedMaxAge;

    struct PendingMaxAge {
        uint32 maxAge;
        uint64 eta;
    }
    mapping(address => PendingMaxAge) public pendingFeedMaxAge;

    struct PoolConfig {
        address pool;
        uint128 minDepth;
    }
    /// @dev Key: keccak256(abi.encode(token0, token1)), with the tokens sorted and native ETH mapped to WETH.
    mapping(bytes32 => PoolConfig) private _poolOf;

    struct PendingFeed {
        address feed; // address(0) = remove
        uint64 eta;
    }
    mapping(address => PendingFeed) public pendingFeed;

    struct PendingPool {
        address pool; // address(0) = remove
        uint128 minDepth;
        uint64 eta;
    }
    mapping(bytes32 => PendingPool) private _pendingPool;

    event FeedQueued(address indexed token, address feed, uint64 eta);
    event FeedQueueCancelled(address indexed token);
    event FeedSet(address indexed token, address previous, address feed);
    event PoolQueued(address indexed token0, address indexed token1, address pool, uint128 minDepth, uint64 eta);
    event PoolQueueCancelled(address indexed token0, address indexed token1);
    event PoolSet(address indexed token0, address indexed token1, address previous, address pool, uint128 minDepth);
    event FeedMaxAgeQueued(address indexed token, uint32 maxAge, uint64 eta);
    event FeedMaxAgeQueueCancelled(address indexed token);
    event FeedMaxAgeSet(address indexed token, uint32 previous, uint32 maxAge);

    error ZeroAddress();
    error DuplicateToken();
    error BadMaxAge();
    error PoolNotServable();
    error LengthMismatch();
    error SameToken();
    error BadFeed();
    error BadPool();
    error MinDepthTooLow();
    error NothingQueued();
    error NotReady(uint64 eta);
    error QueueExpired(uint64 eta);
    error RenounceDisabled();

    /**
     * @param _tokens Tokens that have a Chainlink feed (use the WETH address for v4 native ETH).
     * @param _feeds  Each token's USD proxy, in the same order. Both arrays may be empty.
     * @dev The deployer is the first owner and hands ownership to the multisig with the two-step transfer.
     * No v3 pool is assigned here: the first pools also wait 24 hours through `queuePool`, in public.
     */
    constructor(IUniV3Factory _factory, address _weth, address[] memory _tokens, address[] memory _feeds)
        Ownable(msg.sender)
    {
        if (address(_factory) == address(0) || _weth == address(0)) revert ZeroAddress();
        if (_tokens.length != _feeds.length) revert LengthMismatch();
        factory = _factory;
        weth = _weth;
        for (uint256 i; i < _tokens.length; ++i) {
            if (_tokens[i] == address(0) || _feeds[i] == address(0)) revert ZeroAddress();
            // A repeated token would silently overwrite the earlier row and emit a misleading FeedSet.
            if (address(feedOf[_tokens[i]]) != address(0)) revert DuplicateToken();
            _validateFeed(_feeds[i]);
            feedOf[_tokens[i]] = IAggregatorV3(_feeds[i]);
            emit FeedSet(_tokens[i], address(0), _feeds[i]);
            // Rows that update around the clock (WETH and USDG) get a 25-hour limit from deployment. No event:
            // the value follows from the FeedSet above, and watchers read `feedMaxAge(token)`.
            uint32 ma = GoatChainlinkFeeds.initialMaxAge(_tokens[i], _feeds[i]);
            if (ma != 0) feedMaxAge[_tokens[i]] = ma;
        }
    }

    /**
     * @notice Disabled. Without an owner the configuration would be frozen for good: no feed or pool could be
     * added and a broken source could not be removed. Ownership moves with `transferOwnership` and
     * `acceptOwnership`.
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------------------------------
    // Delayed configuration
    // ------------------------------------------------------------------------------------------

    /// @notice Queues a change of a token's feed, or its removal (`feed = address(0)`).
    function queueFeed(address token, address feed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (feed != address(0)) _validateFeed(feed);
        uint64 eta = uint64(block.timestamp + CONFIG_DELAY);
        pendingFeed[token] = PendingFeed(feed, eta);
        emit FeedQueued(token, feed, eta);
    }

    /// @notice Applies a matured feed change. Anyone may call it: the change was announced 24 hours earlier.
    function applyFeed(address token) external {
        PendingFeed memory p = pendingFeed[token];
        _checkReady(p.eta);
        if (p.feed != address(0)) _validateFeed(p.feed);
        delete pendingFeed[token];
        address previous = address(feedOf[token]);
        feedOf[token] = IAggregatorV3(p.feed);
        emit FeedSet(token, previous, p.feed);
    }

    function cancelFeed(address token) external onlyOwner {
        if (pendingFeed[token].eta == 0) revert NothingQueued();
        delete pendingFeed[token];
        emit FeedQueueCancelled(token);
    }

    /// @notice Queues a change of a token's feed age limit (`feedMaxAge`); 0 means `MAX_FEED_AGE`.
    function queueFeedMaxAge(address token, uint32 maxAge) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (maxAge != 0 && (maxAge < MIN_FEED_MAX_AGE || maxAge > MAX_FEED_AGE)) revert BadMaxAge();
        uint64 eta = uint64(block.timestamp + CONFIG_DELAY);
        pendingFeedMaxAge[token] = PendingMaxAge(maxAge, eta);
        emit FeedMaxAgeQueued(token, maxAge, eta);
    }

    /// @notice Applies a matured age-limit change. Anyone may call it.
    function applyFeedMaxAge(address token) external {
        PendingMaxAge memory p = pendingFeedMaxAge[token];
        _checkReady(p.eta);
        delete pendingFeedMaxAge[token];
        uint32 previous = feedMaxAge[token];
        feedMaxAge[token] = p.maxAge;
        emit FeedMaxAgeSet(token, previous, p.maxAge);
    }

    function cancelFeedMaxAge(address token) external onlyOwner {
        if (pendingFeedMaxAge[token].eta == 0) revert NothingQueued();
        delete pendingFeedMaxAge[token];
        emit FeedMaxAgeQueueCancelled(token);
    }

    /**
     * @notice Queues the assignment of a pair's v3 anchor pool, or its removal (`pool = address(0)`).
     * @param minDepth Floor for the read-time depth, the lower of the frozen and live harmonic-mean liquidity.
     * A fraction of the pool's depth at assignment is recommended, so the anchor goes quiet only if LPs leave.
     * @dev The pool must be able to serve right away (fresh TWAP and `poolDepth >= minDepth`), otherwise
     * `PoolNotServable`; `applyPool` checks the depth again. This keeps a row from being applied that would give
     * the pair a configured source that never answers.
     */
    function queuePool(address tokenA, address tokenB, address pool, uint128 minDepth) external onlyOwner {
        (address t0, address t1) = _sortedMapped(tokenA, tokenB);
        if (pool != address(0)) {
            _validatePool(pool, t0, t1);
            if (minDepth < MIN_ANCHOR_DEPTH) revert MinDepthTooLow();
            _checkServable(IUniV3Pool(pool), minDepth);
        } else {
            minDepth = 0;
        }
        uint64 eta = uint64(block.timestamp + CONFIG_DELAY);
        _pendingPool[_pairKey(t0, t1)] = PendingPool(pool, minDepth, eta);
        emit PoolQueued(t0, t1, pool, minDepth, eta);
    }

    /// @notice Applies a matured pool change. Anyone may call it.
    function applyPool(address tokenA, address tokenB) external {
        (address t0, address t1) = _sortedMapped(tokenA, tokenB);
        bytes32 k = _pairKey(t0, t1);
        PendingPool memory p = _pendingPool[k];
        _checkReady(p.eta);
        if (p.pool != address(0)) {
            _validatePool(p.pool, t0, t1);
            // Depth is checked again, since LPs may have left during the wait. Freshness is not required here:
            // a deep pool that has not traded recently recovers with its next trade, and `anchor()` applies
            // the 6-hour limit anyway.
            if (_historicalDepth(IUniV3Pool(p.pool)) < p.minDepth) revert PoolNotServable();
        }
        delete _pendingPool[k];
        address previous = _poolOf[k].pool;
        _poolOf[k] = PoolConfig(p.pool, p.minDepth);
        emit PoolSet(t0, t1, previous, p.pool, p.minDepth);
    }

    function cancelPool(address tokenA, address tokenB) external onlyOwner {
        (address t0, address t1) = _sortedMapped(tokenA, tokenB);
        bytes32 k = _pairKey(t0, t1);
        if (_pendingPool[k].eta == 0) revert NothingQueued();
        delete _pendingPool[k];
        emit PoolQueueCancelled(t0, t1);
    }

    /// @notice The pair's current v3 anchor pool and depth floor (zero if none).
    function poolFor(address tokenA, address tokenB) external view returns (address pool, uint128 minDepth) {
        (address t0, address t1) = _sortedMapped(tokenA, tokenB);
        PoolConfig memory c = _poolOf[_pairKey(t0, t1)];
        return (c.pool, c.minDepth);
    }

    /// @notice The pair's pending pool change (eta = 0 if none).
    function pendingPoolFor(address tokenA, address tokenB)
        external
        view
        returns (address pool, uint128 minDepth, uint64 eta)
    {
        (address t0, address t1) = _sortedMapped(tokenA, tokenB);
        PendingPool memory p = _pendingPool[_pairKey(t0, t1)];
        return (p.pool, p.minDepth, p.eta);
    }

    function _checkReady(uint64 eta) internal view {
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert NotReady(eta);
        if (block.timestamp > uint256(eta) + CONFIG_GRACE) revert QueueExpired(eta);
    }

    /// @dev The feed must have code and report `decimals() == 8`. Its description is not compared on chain,
    /// since feeds use several formats.
    function _validateFeed(address feed) internal view {
        if (feed.code.length == 0) revert BadFeed();
        try IAggregatorV3(feed).decimals() returns (uint8 d) {
            if (d != FEED_DECIMALS) revert BadFeed();
        } catch {
            revert BadFeed();
        }
    }

    /// @dev Canonical v3 pool for the right token pair, with a large enough observation ring (see contract notes).
    function _validatePool(address pool, address t0, address t1) internal view {
        if (pool.code.length == 0) revert BadPool();
        IUniV3Pool p = IUniV3Pool(pool);
        if (p.token0() != t0 || p.token1() != t1) revert BadPool();
        if (factory.getPool(t0, t1, p.fee()) != pool) revert BadPool();
        // Current ring size, not `next` (see contract notes); card <= next always holds, so next is bounded too.
        (,,, uint16 card,,,) = p.slot0();
        if (card < MIN_POOL_CARDINALITY) revert BadPool();
    }

    /// @dev Whether the pool can serve as the anchor right now: the same two checks as the v3 branch of `anchor()`.
    function _checkServable(IUniV3Pool pool, uint128 minDepth) internal view {
        (bool ok,,) = _observe(pool);
        if (!ok || _historicalDepth(pool) < minDepth) revert PoolNotServable();
    }

    function _sortedMapped(address a, address b) internal view returns (address t0, address t1) {
        a = a == address(0) ? weth : a;
        b = b == address(0) ? weth : b;
        if (a == b) revert SameToken();
        (t0, t1) = a < b ? (a, b) : (b, a);
    }

    function _pairKey(address t0, address t1) internal pure returns (bytes32) {
        return keccak256(abi.encode(t0, t1));
    }

    // ------------------------------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------------------------------

    /**
     * @notice Manipulation-resistant price for the pair, as tokenB per tokenA in raw units: the orientation of a
     * pool whose currency0 is tokenA.
     * @dev `tick` and `sqrtPriceX96` follow the caller's (tokenA, tokenB) order. When the v3 pool's own token
     * order is the reverse, the tick is negated (sqrtPrice(-t) = 1/sqrtPrice(t)), so the caller can compare it
     * directly with the spot tick of its own pool.
     * @return ok Whether an anchor is available. When false the caller must not swap: `GoatV4Compoundor` and the
     * v3 compound contracts then add liquidity without a swap or a price gate, and a flow that moves principal
     * (such as auto-range) must reject.
     *
     * @dev `sqrtPriceX96` is the precise price and `tick` is its floor tick, so
     * `getSqrtPriceAtTick(tick) <= sqrtPriceX96`, less than one tick (about 0.01%) apart and not necessarily
     * equal. The Chainlink path carries the exact feed ratio, which gives a better swap floor; the v3 path derives
     * the price from the tick, so there the two are equal. Use `sqrtPriceX96` for prices and `tick` for
     * comparisons, and do not rebuild one from the other. For the same reason `anchor(a, b)` and `anchor(b, a)`
     * may differ by one tick.
     */
    function anchor(address tokenA, address tokenB)
        external
        view
        returns (bool ok, uint160 sqrtPriceX96, int24 tick)
    {
        address a = tokenA == address(0) ? weth : tokenA;
        address b = tokenB == address(0) ? weth : tokenB;
        if (a == b) return (false, 0, 0);

        // 1) Chainlink, when both tokens have a feed; independent of v3 trading.
        (bool clOk, uint160 clSqrt, int24 clTick) = _chainlinkAnchor(a, b);
        if (clOk) return (true, clSqrt, clTick);

        // 2) The assigned v3 pool (the factory is never scanned): needs a fresh TWAP and the depth floor.
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        PoolConfig memory c = _poolOf[_pairKey(t0, t1)];
        if (c.pool == address(0)) return (false, 0, 0);
        IUniV3Pool p = IUniV3Pool(c.pool);
        (bool okP, int24 t,) = _observe(p);
        if (!okP) return (false, 0, 0);
        if (_historicalDepth(p) < c.minDepth) return (false, 0, 0);

        // The pool's token0 is `t0` (checked on assignment); flip the direction when the caller's tokenA is not `t0`.
        if (a != t0) t = -t;
        return (true, TickMath.getSqrtPriceAtTick(t), t);
    }

    /// @notice Diagnostic: the anchor from the Chainlink path alone.
    function chainlinkAnchor(address tokenA, address tokenB)
        external
        view
        returns (bool ok, uint160 sqrtPriceX96, int24 tick)
    {
        address a = tokenA == address(0) ? weth : tokenA;
        address b = tokenB == address(0) ? weth : tokenB;
        if (a == b) return (false, 0, 0);
        return _chainlinkAnchor(a, b);
    }

    /**
     * @dev Price from the two USD feeds, already oriented as (a = token0, b = token1), so no flip is needed.
     *
     * Every check must pass:
     *  - both tokens have a feed;
     *  - `0 < answer <= MAX_FEED_ANSWER` (zero, negative and corrupt answers are rejected);
     *  - `updatedAt != 0` and the answer is within the token's age limit (`feedMaxAge`, else `MAX_FEED_AGE`);
     *  - `answeredInRound >= roundId`, so incomplete rounds are not used;
     *  - the feed reports `decimals() == FEED_DECIMALS` at read time, and token decimals are at most 36;
     *  - the raw ratio is below 2^64 (a larger one would overflow `mulDiv`) and the result is inside the tick range.
     * Otherwise `ok = false` and the caller moves on to the v3 path. No feed or token response, malformed return
     * data included, can make `anchor()` revert.
     */
    function _chainlinkAnchor(address a, address b)
        internal
        view
        returns (bool ok, uint160 sqrtPriceX96, int24 tick)
    {
        IAggregatorV3 fa = feedOf[a];
        IAggregatorV3 fb = feedOf[b];
        if (address(fa) == address(0) || address(fb) == address(0)) return (false, 0, 0);

        // Both answers have FEED_DECIMALS decimals (checked in `_readFeed`), so they share a base.
        (bool okA, uint256 ansA) = _readFeed(fa, _maxAge(a));
        if (!okA) return (false, 0, 0);
        (bool okB, uint256 ansB) = _readFeed(fb, _maxAge(b));
        if (!okB) return (false, 0, 0);

        (bool okTa, uint8 tdA) = _tokenDecimals(a);
        (bool okTb, uint8 tdB) = _tokenDecimals(b);
        if (!okTa || !okTb) return (false, 0, 0);

        // Raw pool ratio (token1/token0) = (ansA / ansB) * 10^tdB / 10^tdA.
        // With ans <= 1e14 and td <= 36, num and den stay below 2^167, so the products cannot overflow.
        uint256 num = ansA * (10 ** tdB);
        uint256 den = ansB * (10 ** tdA);
        if (num == 0 || den == 0) return (false, 0, 0);
        // A ratio >= 2^64 gives ratio * 2^192 >= 2^256, which would make `mulDiv` revert.
        if (num / den >= 1 << 64) return (false, 0, 0);

        // sqrtPriceX96 = sqrt(raw ratio) * 2^96 = sqrt(raw ratio * 2^192)
        uint256 ratioX192 = FullMath.mulDiv(num, 1 << 192, den);
        uint256 root = _sqrt(ratioX192);
        if (root == 0 || root > type(uint160).max) return (false, 0, 0);
        sqrtPriceX96 = uint160(root);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            return (false, 0, 0);
        }
        return (true, sqrtPriceX96, TickMath.getTickAtSqrtPrice(sqrtPriceX96));
    }

    /// @dev The token's effective feed age limit: `feedMaxAge`, or `MAX_FEED_AGE` when unset.
    function _maxAge(address token) internal view returns (uint256 m) {
        m = feedMaxAge[token];
        if (m == 0) m = MAX_FEED_AGE;
    }

    function _readFeed(IAggregatorV3 f, uint256 maxAge) internal view returns (bool ok, uint256 answer) {
        (bool s, uint256[5] memory w) = _staticWords(address(f), IAggregatorV3.latestRoundData.selector, 5);
        if (!s) return (false, 0);
        // w = (roundId, answer, startedAt, updatedAt, answeredInRound); the uint80 fields must be well formed
        if (w[0] > type(uint80).max || w[4] > type(uint80).max) return (false, 0);
        int256 ans = int256(w[1]);
        uint256 updatedAt = w[3];
        if (ans <= 0 || uint256(ans) > MAX_FEED_ANSWER) return (false, 0);
        if (updatedAt == 0 || w[4] < w[0]) return (false, 0);
        if (block.timestamp < updatedAt) return (false, 0); // answer from the future: unexpected clock
        if (block.timestamp - updatedAt > maxAge) return (false, 0);
        // The aggregator behind the proxy can change without an event, so decimals are checked on every read.
        (bool sd, uint256[5] memory d) = _staticWords(address(f), IAggregatorV3.decimals.selector, 1);
        if (!sd || d[0] != FEED_DECIMALS) return (false, 0);
        return (true, uint256(ans));
    }

    /// @dev A reverting `decimals()` is read as 18. Short return data, or a value above `MAX_TOKEN_DECIMALS`,
    /// gives ok = false.
    function _tokenDecimals(address token) internal view returns (bool ok, uint8 dec) {
        bytes4 selector = IERC20Decimals.decimals.selector;
        bool called;
        uint256 size;
        uint256 v;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            called := staticcall(gas(), token, 0x00, 0x04, 0x00, 0x20)
            size := returndatasize()
            v := mload(0x00)
        }
        if (!called) return (true, 18);
        if (size < 32 || v > MAX_TOKEN_DECIMALS) return (false, 0);
        return (true, uint8(v));
    }

    /**
     * @dev Static call of `selector` on `target`; the first `n` return words (n <= 5) are written to `w`.
     * `ok = false` when the call reverts or returns fewer than `n` words. Extra return data is not copied.
     * Not try/catch, because try/catch does not catch failures while decoding the return data (short data,
     * values out of range for uint8 or uint80, an address without code), which would make `anchor()` revert.
     */
    function _staticWords(address target, bytes4 selector, uint256 n)
        private
        view
        returns (bool ok, uint256[5] memory w)
    {
        assembly ("memory-safe") {
            mstore(0x00, selector)
            ok := staticcall(gas(), target, 0x00, 0x04, w, mul(n, 0x20))
            if lt(returndatasize(), mul(n, 0x20)) { ok := 0 }
        }
    }

    /// @dev Babylonian square root, rounded down.
    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        // Initial estimate from half the position of the most significant bit
        uint256 r = 1;
        uint256 v = x;
        if (v >= 1 << 128) { v >>= 128; r <<= 64; }
        if (v >= 1 << 64) { v >>= 64; r <<= 32; }
        if (v >= 1 << 32) { v >>= 32; r <<= 16; }
        if (v >= 1 << 16) { v >>= 16; r <<= 8; }
        if (v >= 1 << 8) { v >>= 8; r <<= 4; }
        if (v >= 1 << 4) { v >>= 4; r <<= 2; }
        if (v >= 1 << 2) { r <<= 1; }
        // Newton iterations (seven rounds are enough for uint256)
        unchecked {
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            uint256 r1 = x / r;
            z = r < r1 ? r : r1; // round down
        }
    }

    /// @notice Diagnostic: a pool's TWAP tick and harmonic-mean liquidity over the window.
    function poolAnchor(address pool)
        external
        view
        returns (bool ok, int24 twapTick, uint128 harmonicLiquidity)
    {
        return _observe(IUniV3Pool(pool));
    }

    /**
     * @notice Whether the pair has a configured price source (a feed for both tokens, or an assigned v3 pool),
     * whether or not that source can answer right now.
     * @dev For monitoring only; no contract calls it. True while `CompoundedWithoutAnchor` is being emitted means
     * a configured source has gone quiet (a stale feed, or a stale or shallow pool) and needs attention.
     */
    function hasSource(address tokenA, address tokenB) external view returns (bool) {
        address a = tokenA == address(0) ? weth : tokenA;
        address b = tokenB == address(0) ? weth : tokenB;
        if (a == b) return false;
        if (address(feedOf[a]) != address(0) && address(feedOf[b]) != address(0)) return true;
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return _poolOf[_pairKey(t0, t1)].pool != address(0);
    }

    function poolDepth(address pool) external view returns (uint128) {
        return _historicalDepth(IUniV3Pool(pool));
    }

    /**
     * @dev Depth used for the `minDepth` check: the lower of two harmonic-mean liquidities.
     * Frozen window `[R - (W - 1), R]`, where `R` is the last observation before the current timestamp
     * (`_refObsTs`). It lies entirely in the past, so liquidity added or removed in the current block has no
     * weight in it and an observation written in this block does not change it; with a ring of at least 1801
     * slots it can always be measured. Live window `[now - W, now]`, which v3 extrapolates with the current
     * liquidity, so a pool whose liquidity has left shows it there.
     * Returns 0 when the history is too short or cannot be read, and the anchor then reports `ok = false`.
     *
     * @dev Within one timestamp the result does not change, apart from a possible one-unit rounding in the live
     * window (v3 extrapolates `now - W` before an observation is written in the block and interpolates after).
     * The TWAP tick is exact. Across timestamps a pool is only as good as its recent activity; see `MAX_STALENESS`.
     */
    function _historicalDepth(IUniV3Pool pool) internal view returns (uint128) {
        (, , uint16 obsIndex, uint16 card, , , ) = pool.slot0();
        if (card == 0) return 0;
        uint32 nowTs = uint32(block.timestamp);
        (bool init, uint32 refTs) = _refObsTs(pool, obsIndex, card, nowTs);
        if (!init) return 0;
        if (refTs > nowTs) return 0;
        uint32 age = nowTs - refTs;

        // (1) Frozen window [R - (W - 1), R]: it excludes the current timestamp, so changes made in this
        //     block can neither raise nor lower it.
        uint128 frozen = _depthOverWindow(pool, age, TWAP_SECONDS - 1);
        if (frozen == 0) return 0;

        // (2) Live window [now - W, now]: v3 extrapolates its end with the current liquidity, so a pool
        //     whose liquidity has been withdrawn shows it here.
        uint128 live = _depthOverWindow(pool, 0, TWAP_SECONDS);

        // The pool needs both a real past and a real present, so take the lower of the two.
        return live < frozen ? live : frozen;
    }

    /// @dev Harmonic-mean liquidity over the window from `offset + len` to `offset` seconds ago; 0 if it cannot be
    /// measured.
    function _depthOverWindow(IUniV3Pool pool, uint32 offset, uint32 len) private view returns (uint128) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = offset;
        ago[1] = offset + len;
        try pool.observe(ago) returns (int56[] memory, uint160[] memory liqCum) {
            uint160 d;
            unchecked { d = liqCum[0] - liqCum[1]; } // oracle accumulators wrap by design
            if (d == 0) return 0;
            uint192 windowX160 = uint192(len) * type(uint160).max;
            return uint128(windowX160 / (uint192(d) << 32));
        } catch {
            return 0;
        }
    }

    /**
     * @dev Reference time for age and the frozen window: the last observation before the current timestamp.
     * When the newest observation was written at this timestamp (v3 writes at most one per timestamp), the
     * previous slot is used. With no previous slot (`card < 2`) or an uninitialized one, `init = false`
     * (assigned pools have at least 1801 slots). The TWAP (`observe([0, W])`) is unaffected, since it already
     * gives the current timestamp zero weight.
     */
    function _refObsTs(IUniV3Pool pool, uint16 obsIndex, uint16 card, uint32 nowTs)
        internal
        view
        returns (bool init, uint32 ts)
    {
        (ts, , , init) = pool.observations(obsIndex);
        if (!init || ts != nowTs) return (init, ts);
        if (card < 2) return (false, 0);
        uint16 prev = obsIndex == 0 ? card - 1 : obsIndex - 1;
        (ts, , , init) = pool.observations(prev);
    }

    /**
     * @dev TWAP tick and harmonic-mean liquidity over the window, from a single `observe()`.
     *
     * When the window start `now - W` is later than the last observation, v3 extrapolates with the current tick
     * and the result equals the pool's last tick: the window holds a real observation only when
     * `now - lastTs <= W`. With too little history `observe` reverts, and the try/catch returns false.
     *
     * The limit applied here is `MAX_STALENESS` (6 hours), measured from `_refObsTs`, not `W`. Between `W` and
     * 6 hours the window holds no real observation and the result equals the v3 pool's last price. That is
     * accepted only for cross-venue use (see `MAX_STALENESS`): for a v4 consumer the v3 pool is a separate venue.
     * A v3 consumer whose own pool is the assigned pool must reject the anchor.
     *
     * Extrapolating the `now` end with the current tick is exact, not an estimate: in v3 the tick changes only
     * through swaps, and the first swap in a block writes an observation. The current tick has therefore held
     * for the whole of `[lastTs, now]`, and the result is the true time-weighted average. A price moved within
     * the current block has zero weight in it.
     */
    function _observe(IUniV3Pool pool) internal view returns (bool ok, int24 tick, uint128 harmonicLiquidity) {
        (, , uint16 obsIndex, uint16 card, , , ) = pool.slot0();
        if (card == 0) return (false, 0, 0);

        // Age is measured from the last observation before this timestamp, so activity in the same block
        // does not refresh it (see `MAX_STALENESS`).
        uint32 nowTs = uint32(block.timestamp);
        (bool init, uint32 lastTs) = _refObsTs(pool, obsIndex, card, nowTs);
        if (!init) return (false, 0, 0);

        if (lastTs > nowTs) return (false, 0, 0); // unexpected clock: no anchor
        // Staleness limit of 6 hours: past W the TWAP equals the v3 pool's last price, which is accepted for
        // cross-venue use only (see the function notes).
        if (nowTs - lastTs > MAX_STALENESS) return (false, 0, 0);

        uint32[] memory ago = new uint32[](2);
        ago[0] = 0;
        ago[1] = TWAP_SECONDS;
        try pool.observe(ago) returns (int56[] memory cum, uint160[] memory liqCum) {
            // `unchecked` is required: the oracle accumulators wrap by design, and Uniswap's OracleLibrary
            // (Solidity 0.7.6) subtracts with wrapping. Checked 0.8 arithmetic would revert whenever an
            // accumulator wraps, leaving the anchor unusable at that moment.
            int56 tickDelta;
            uint160 liqDelta;
            unchecked {
                tickDelta = cum[0] - cum[1];
                liqDelta = liqCum[0] - liqCum[1];
            }

            int56 window = int56(uint56(TWAP_SECONDS));
            int24 t = int24(tickDelta / window);
            // Same as Uniswap's OracleLibrary.consult: round negative values down.
            if (tickDelta < 0 && tickDelta % window != 0) t--;

            // Harmonic-mean liquidity, the same formula as OracleLibrary.consult.
            // secondsPerLiquidityCumulativeX128 accumulates (1 << 128) / liquidity per second.
            if (liqDelta == 0) return (false, 0, 0); // depth cannot be measured: do not use
            uint192 windowX160 = uint192(TWAP_SECONDS) * type(uint160).max;
            return (true, t, uint128(windowX160 / (uint192(liqDelta) << 32)));
        } catch {
            return (false, 0, 0);
        }
    }
}
