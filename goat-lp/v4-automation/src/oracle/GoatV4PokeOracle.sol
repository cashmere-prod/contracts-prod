// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Lock} from "@uniswap/v4-core/src/libraries/Lock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {PokeWindow, IGoatPokeOracle} from "../interfaces/GoatV4External.sol";
import {GoatV4Constants as K} from "../lib/GoatV4Constants.sol";
import "../lib/GoatV4Errors.sol";

/**
 * @notice Poke-based price history for Uniswap v4 pools. The v4 core has no oracle, so anyone can call `poke`: each
 *         poke reads the pool's live slot0 tick and in-range liquidity through `PoolManager.extsload` and adds it to a
 *         60 s BUCKET. There are TWO rings of buckets per pool:
 *           - the REGISTERED ring, written only by registered pokers. It is the only data `consult` reads, so it is the
 *             only data the registry and the meter act on (window medians, spread, newest-bucket range, minL);
 *           - the SIGNAL ring, written only by every other caller. Nothing on chain reads it: it is a monitoring signal,
 *             exposed through `openBucketAt` and `consultAll`.
 *         A bucket keeps the lowest (lo), highest (hi) and last tick of the pokes written into it, the poke count and,
 *         on the registered ring, the smallest in-range liquidity seen (minL).
 *
 * @dev Why two rings: pokes from any caller used to count toward the shared buckets; they now go to a separate signal
 *      ring. A poke by an unregistered caller changes none of the values `consult` returns (medians, spread, newest-
 *      bucket range, minL, the 15/15 counters); it only shows up in the monitoring views.
 * @dev Range buckets: a registered bucket keeps the range of every registered poke in its slot rather than a single
 *      sample, because a v4 pool has no start-of-block tick. Our poker reads 2-3 times per bucket at random seconds. An
 *      extra registered poke can only lower a bucket's lo or raise its hi, so medLo can only fall and medHi can only
 *      rise. A floor built on the median that favours the user (medHi when selling token0, medLo when selling token1)
 *      can therefore only become stricter, and moving a median takes a majority (>= 8) of the 15 buckets. medMid, the
 *      median of bucket midpoints (lo + hi) / 2, has no such direction, so every consumer of medMid bounds it with a
 *      spread limit (`spreadMax <= G`) or the [medLo, medHi] clamp, as the registry does.
 * @dev Spread statistic: `spreadMax` (name kept for interface compatibility) is the LOWER MEDIAN of bucket hi - lo
 *      (the 8th largest of 15), not the widest bucket, so a single wide bucket does not close the swap flows for the
 *      whole window. It exceeds G only when a majority of the registered buckets are wider than G.
 * @dev No poke while the PoolManager is unlocked (inside an `unlock` callback, read from its IS_UNLOCKED transient
 *      slot): `PokeWhileUnlocked`, on both rings. A price reached inside an unlock does not have to be settled until
 *      the callback ends, so it is never recorded.
 * @dev Tick from the price: when a zeroForOne swap leaves the price exactly on initialized tick k, slot0.tick = k - 1.
 *      The bucket records the price's tick (as TickMath.getTickAtSqrtPrice: tick + 1 when sqrtP == P(tick + 1)).
 *
 * @dev Registered pokers: only addresses the owner adds through a 1-hour timelock write the registered ring. The
 *      consumer (the registry) requires a registered bucket in EACH of the last 15 complete slots (15/15), so a gap in
 *      registered pokes pauses swap flows on POKE rows until the window is full again (fail-closed).
 *      Every value the consumers read comes from these keys, so they are trusted keys: the owner or the guardian
 *      removes a poker at once (`removePoker`).
 *
 * @dev minL: the first registered poke of a bucket SETS minL to its own liquidity and later registered pokes keep the
 *      minimum; `consult` returns the smallest minL of the window (0 if the window has no bucket). minL feeds the POKE
 *      source's time-weighted depth (VD4 = walk * min(1, minL / L_now)). Signal buckets carry minL = 0.
 *
 * @dev Structure: holds no tokens or ETH; its only external calls are the `extsload` / `exttload` views (no reentrancy
 *      surface); no proxy or delegatecall. The PoolManager is pinned to K.POOL_MANAGER in the constructor.
 *      Rings: 64 buckets per pool each, slot index (start / 60) mod 64; a stale bucket is recognised by its start time.
 */
contract GoatV4PokeOracle is Ownable2Step, IGoatPokeOracle {
    // ------------------------------------------------------------------ constants

    /// @notice Bucket width (s), derived from the consumers' window (K.VETO_WINDOW / K.POKE_WINDOW = 900 / 15 = 60).
    uint256 public constant SPACING = uint256(K.VETO_WINDOW) / K.POKE_WINDOW;
    /// @notice Number of buckets kept per pool (ring).
    uint256 public constant CARD = 64;
    /// @notice `consult` window: the 15 COMPLETE slots before the current one (= K.POKE_WINDOW; registry and meter require 15/15).
    uint256 public constant WINDOW = K.POKE_WINDOW;
    uint256 internal constant TIMELOCK = 1 hours;
    uint256 internal constant QUEUE_GRACE = 7 days;
    /// @dev Slot of PoolManager's `_pools` mapping and the liquidity offset inside `Pool.State` (layout facts).
    uint256 internal constant POOLS_SLOT = 6;
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    // ------------------------------------------------------------------ types

    /// @notice One slot (256 bits), the same layout on both rings. `last` and `n` are not read on chain: they serve
    ///         off-chain diagnostics through `bucketAt` / `openBucketAt` and share the slot, so they cost no extra SSTORE.
    struct Bucket {
        uint32 start; // bucket start (a multiple of 60); 0 = empty
        int24 lo;
        int24 hi;
        int24 last;
        uint16 n; // number of pokes written into this bucket (saturating)
        bool reg; // true on the registered ring, false on the signal ring
        uint128 minL; // registered ring: smallest in-range liquidity seen; signal ring: always 0
    }

    // ------------------------------------------------------------------ state

    IPoolManager public immutable POOL_MANAGER;
    address public guardian;
    mapping(address => bool) public isPoker;
    mapping(address => uint256) public pokerQueuedAt;
    /// @dev Registered ring: written only by registered pokers; the only ring `consult` reads.
    mapping(bytes32 => Bucket[CARD]) internal _buckets;
    /// @dev Signal ring: written only by other callers; read only by the monitoring views (`openBucketAt`, `consultAll`).
    mapping(bytes32 => Bucket[CARD]) internal _open;

    // ------------------------------------------------------------------ events

    event Poked(bytes32 indexed poolId, uint32 start, int24 tick, bool newBucket, bool registered);
    event PokerQueued(address indexed poker, uint256 eta);
    event PokerActivated(address indexed poker);
    event PokerRemoved(address indexed poker);
    event GuardianSet(address indexed guardian);

    /// @notice Poke while the PoolManager is unlocked (inside an unlock callback).
    error PokeWhileUnlocked();

    /// @dev The PoolManager is pinned to the canonical address (the registry, meter and Steward read K.POOL_MANAGER;
    ///      another PoolManager's `extsload` would anchor POKE rows to unrelated state).
    constructor(address poolManager_, address initialOwner) Ownable(initialOwner) {
        if (poolManager_ != K.POOL_MANAGER || poolManager_.code.length == 0) revert BadDeployment();
        POOL_MANAGER = IPoolManager(poolManager_);
    }

    // ================================================================== ADMINISTRATION

    /// @notice DISABLED: an oracle without an owner would freeze its poker list.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Immediate (no timelock). The guardian's only power is `removePoker`.
    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    /// @notice Adding a poker waits for a 1-hour timelock (a registered poke counts toward the consumer's 15/15 rule).
    function queuePoker(address p) external onlyOwner {
        if (p == address(0)) revert BadValue();
        pokerQueuedAt[p] = block.timestamp;
        emit PokerQueued(p, block.timestamp + TIMELOCK);
    }

    function activatePoker(address p) external onlyOwner {
        uint256 t = pokerQueuedAt[p];
        if (t == 0) revert NotQueued();
        if (block.timestamp < t + TIMELOCK) revert TimelockNotReady();
        if (block.timestamp > t + TIMELOCK + QUEUE_GRACE) revert TimelockExpired();
        delete pokerQueuedAt[p];
        isPoker[p] = true;
        emit PokerActivated(p);
    }

    /// @notice Immediate (owner or guardian); also drops a queued addition.
    function removePoker(address p) external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        isPoker[p] = false;
        delete pokerQueuedAt[p];
        emit PokerRemoved(p);
    }

    // ================================================================== POKE (permissionless)

    function poke(bytes32[] calldata ids) external {
        _notUnlocked();
        bool r = isPoker[msg.sender];
        for (uint256 i; i < ids.length; ++i) {
            _poke(ids[i], r);
        }
    }

    function pokeOne(bytes32 id) external {
        _notUnlocked();
        _poke(id, isPoker[msg.sender]);
    }

    /// @dev No poke while the PoolManager is inside `unlock` (flash accounting is open there).
    function _notUnlocked() internal view {
        if (POOL_MANAGER.exttload(Lock.IS_UNLOCKED_SLOT) != bytes32(0)) revert PokeWhileUnlocked();
    }

    function _poke(bytes32 id, bool r) internal {
        (uint160 sqrtP, int24 tick, uint128 liq) = poolState(id);
        if (sqrtP == 0) revert PoolNotInitialized(id);
        // When the price sits exactly on tick k, a zeroForOne swap leaves slot0.tick = k − 1: record the price's tick.
        if (tick >= TickMath.MIN_TICK && tick < TickMath.MAX_TICK && sqrtP == TickMath.getSqrtPriceAtTick(tick + 1)) {
            ++tick;
        }
        uint256 slot = block.timestamp / SPACING;
        uint32 start = uint32(slot * SPACING);
        uint256 i = slot % CARD;
        // A registered poke writes ONLY the registered ring, any other poke ONLY the signal ring: the two never mix.
        Bucket memory b = r ? _buckets[id][i] : _open[id][i];
        bool fresh = b.start != start;
        if (fresh) {
            b = Bucket(start, tick, tick, tick, 1, r, r ? liq : 0);
        } else {
            if (tick < b.lo) b.lo = tick;
            if (tick > b.hi) b.hi = tick;
            b.last = tick;
            unchecked {
                if (b.n != type(uint16).max) ++b.n;
            }
            if (r && liq < b.minL) b.minL = liq;
        }
        if (r) _buckets[id][i] = b;
        else _open[id][i] = b;
        emit Poked(id, start, tick, fresh, r);
    }

    /// @notice The pool's live sqrtP, tick and in-range liquidity (one `extsload` call, two slots).
    function poolState(bytes32 id) public view returns (uint160 sqrtP, int24 tick, uint128 liq) {
        bytes32 base = keccak256(abi.encode(id, POOLS_SLOT));
        bytes32[] memory slots = new bytes32[](2);
        slots[0] = base;
        slots[1] = bytes32(uint256(base) + LIQUIDITY_OFFSET);
        bytes32[] memory v = POOL_MANAGER.extsload(slots);
        uint256 w = uint256(v[0]);
        sqrtP = uint160(w);
        tick = int24(uint24(w >> 160));
        liq = uint128(uint256(v[1]));
    }

    // ================================================================== READS

    /// @notice The REGISTERED bucket `k` slots back (k = 0 is the current slot). If its start is not that slot (stale or
    ///         empty), `start` differs: that slot has no registered poke.
    function bucketAt(bytes32 id, uint256 k) external view returns (Bucket memory) {
        return _buckets[id][(block.timestamp / SPACING - k) % CARD];
    }

    /// @notice MONITORING ONLY: the signal bucket (other callers' pokes) `k` slots back. Nothing on chain reads it.
    function openBucketAt(bytes32 id, uint256 k) external view returns (Bucket memory) {
        return _open[id][(block.timestamp / SPACING - k) % CARD];
    }

    /**
     * @notice Summary of the last 15 COMPLETE slots (the current slot excluded), from the REGISTERED ring only. Slot k
     *         (1..15) counts only if a registered bucket starts exactly at `(now/60 - k)*60`; `complete` and
     *         `registered` are therefore equal (both kept for interface compatibility). The medians are LOWER medians
     *         over those buckets; `spreadMax` = the lower median of bucket hi - lo (NOT the widest); `newLo/newHi` come
     *         from slot 1 and, if present, the current slot 0. The consumer requires 15/15. `age` is not read on chain
     *         (off-chain diagnostics; freshness comes from the 15/15 rule). Pokes by other callers change nothing here.
     */
    function consult(bytes32 id) external view returns (PokeWindow memory w) {
        return _summary(id, false);
    }

    /**
     * @notice MONITORING ONLY (nothing on chain reads it): the same summary over the UNION of both rings, i.e. every
     *         caller's pokes, which is what `consult` returned in the previous version. `complete` counts slots with any
     *         poke, `registered` those with a registered one. A keeper compares it with `consult` to raise an alarm when
     *         outside pokes would have widened the window.
     */
    function consultAll(bytes32 id) external view returns (PokeWindow memory w) {
        return _summary(id, true);
    }

    /// @dev The window summary; `all` = union of both rings (monitoring), else the registered ring only (consumers).
    function _summary(bytes32 id, bool all) internal view returns (PokeWindow memory w) {
        uint256 cur = block.timestamp / SPACING;
        int24[] memory los = new int24[](WINDOW);
        int24[] memory his = new int24[](WINDOW);
        int24[] memory mids = new int24[](WINDOW);
        int24[] memory sprs = new int24[](WINDOW);
        int24 nLo = type(int24).max;
        int24 nHi = type(int24).min;
        uint128 minL = type(uint128).max;
        uint256 newest;
        Bucket memory b = _buckets[id][cur % CARD];
        bool ok = b.start == cur * SPACING;
        if (all) (ok, b) = _withOpen(id, cur, ok, b);
        if (ok) {
            (nLo, nHi, newest) = (b.lo, b.hi, b.start);
        }
        uint256 n;
        for (uint256 k = 1; k <= WINDOW; ++k) {
            uint256 s = cur - k;
            b = _buckets[id][s % CARD];
            ok = b.start == s * SPACING;
            if (all) (ok, b) = _withOpen(id, s, ok, b);
            if (!ok) continue;
            if (b.reg) {
                ++w.registered;
                if (b.minL < minL) minL = b.minL;
            }
            los[n] = b.lo;
            his[n] = b.hi;
            int256 sum = int256(b.lo) + int256(b.hi);
            mids[n] = int24(sum >= 0 ? sum / 2 : (sum - 1) / 2);
            sprs[n] = b.hi - b.lo;
            ++n;
            if (k == 1) {
                if (b.lo < nLo) nLo = b.lo;
                if (b.hi > nHi) nHi = b.hi;
            }
            if (newest == 0) newest = b.start;
        }
        w.complete = uint16(n);
        if (n != 0) {
            w.medLo = _lowerMedian(los, n);
            w.medHi = _lowerMedian(his, n);
            w.medMid = _lowerMedian(mids, n);
            w.spreadMax = _lowerMedian(sprs, n);
        }
        if (w.registered != 0) w.minL = minL;
        if (nLo <= nHi) (w.newLo, w.newHi) = (nLo, nHi);
        w.age = newest == 0 ? type(uint32).max : uint32(block.timestamp - newest);
    }

    /**
     * @dev Monitoring path only (`consultAll`): slot `s`'s registered bucket `b` (`ok` = it exists for exactly that
     *      slot) merged with the signal bucket of the same slot: lo = min, hi = max, n = sum (saturating); `reg` and
     *      `minL` come from the registered bucket (a signal-only slot has reg = false, minL = 0), as one shared bucket
     *      had them in the previous version. `consult` never calls it.
     */
    function _withOpen(bytes32 id, uint256 s, bool ok, Bucket memory b) internal view returns (bool, Bucket memory) {
        Bucket memory o = _open[id][s % CARD];
        if (o.start != s * SPACING) return (ok, b);
        if (!ok) return (true, o);
        if (o.lo < b.lo) b.lo = o.lo;
        if (o.hi > b.hi) b.hi = o.hi;
        uint256 m = uint256(b.n) + o.n;
        b.n = m > type(uint16).max ? type(uint16).max : uint16(m);
        return (true, b);
    }

    /// @dev Lower median of the first `n` items (in-place insertion sort; n <= 15).
    function _lowerMedian(int24[] memory v, uint256 n) internal pure returns (int24) {
        for (uint256 i = 1; i < n; ++i) {
            int24 x = v[i];
            uint256 j = i;
            while (j > 0 && v[j - 1] > x) {
                v[j] = v[j - 1];
                --j;
            }
            v[j] = x;
        }
        return v[(n - 1) / 2];
    }
}
