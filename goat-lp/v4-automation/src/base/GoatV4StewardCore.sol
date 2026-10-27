// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {GoatPoolSlots} from "../lib/GoatPoolSlots.sol";
import {GoatRateBucket} from "../lib/GoatRateBucket.sol";
import {GoatV4Constants as K} from "../lib/GoatV4Constants.sol";
import {HookEntry} from "../lib/GoatPairTypes.sol";
import {GoatV4PairRegistry} from "../GoatV4PairRegistry.sol";
import {IGoatFeeCapHook} from "../interfaces/GoatV4External.sol";
import "../lib/GoatV4Errors.sol";

/**
 * @notice Abstract base of `GoatV4Steward`: roles, timelocks, pause, fees, hourly buckets (off by default), retirement,
 *         and the gate / pool-rule primitives. The anchor, the source checks, the pair scope and the hook entries live
 *         in the separate `GoatV4PairRegistry` (per-pair feeds, gate G and price sources; listing waits 24 h, removal
 *         is immediate).
 *
 * @dev There is no per-position cap. The global hourly limit is off by default; the owner can turn it on later.
 *
 * @dev Structural rules: no proxy, no delegatecall, no multicall, no receive/fallback, no onERC721Received, no rescue
 *      function. The Steward never holds tokens or NFTs; execution and balances are in `GoatV4StewardEngine`.
 */
abstract contract GoatV4StewardCore is Ownable2Step, ReentrancyGuard {
    using GoatRateBucket for GoatRateBucket.Bucket;

    // ------------------------------------------------------------------ fixed addresses

    IPositionManager public constant POSM = IPositionManager(K.POSM);
    IPoolManager public constant POOL_MANAGER = IPoolManager(K.POOL_MANAGER);

    // ------------------------------------------------------------------ compile-time constants

    /// @notice Pool scope. The pair and gate G come from `REGISTRY`. A LISTED hookless static pool needs fee <= 1% and
    ///         ts <= 200. A new range must contain anchor ± G, which needs `W >= 2(G + ts)`: the per-pool minimum width
    ///         is `roundUp(max(400, 2(G + ts)), ts)` (G 140, ts 200 → 800; ts <= 60 → 400).
    uint24 internal constant MAX_POOL_FEE = 10_000;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 internal constant MAX_TICK_SPACING = 200;
    int24 internal constant MIN_WIDTH = 400;
    /// @dev Gate of the withdraw-only rule on an unlisted hookless static pool (the EXIT level is G + 1 outside the range).
    int24 internal constant WO_GATE = 100;

    /// @notice The owner's slippage bounds (bps). A hooked pool's entry has its own (narrower) upper bound.
    uint16 internal constant MIN_SLIPPAGE_BPS = 10;
    uint16 public constant S_MAX = 100;
    /// @notice Range of the per-position, owner-signed max swap fee `maxSwapFeePips` (a TOTAL fee in pips):
    ///         [1, 100,000] = up to 10 %; the UI default is 10,000 (1 %).
    uint24 internal constant MAX_USER_SWAP_FEE = K.MAX_USER_SWAP_FEE;

    /// @dev The generic withdraw-only admission of an entry-less hooked pool refuses only the two liquidity
    ///      return-delta bits (0x0002 afterAddLiquidityReturnDelta, 0x0001 afterRemoveLiquidityReturnDelta).
    ///      Entries keep their per-kind masks in the registry (0x030F kind 1; 0x0303 kinds 2 / 3; 0x030B kind 4).
    uint160 internal constant WO_FORBIDDEN_HOOK_BITS = 0x0003;

    /// @dev Hook entry kinds, the registry's `KIND_*` values (0 = hookless or the withdraw-only rule).
    uint8 internal constant KIND_SIGNED_FEE = 1;
    uint8 internal constant KIND_EXTERNAL_VENUE = 2;
    uint8 internal constant KIND_CONST_TAX = 3;

    uint256 internal constant TIMELOCK = 24 hours;
    /// @notice A queued action can be applied in [queuedAt + TIMELOCK, queuedAt + TIMELOCK + QUEUE_GRACE] (24 h, then a
    ///         7-day window, both bounds inclusive); after that it expires.
    uint256 internal constant QUEUE_GRACE = 7 days;

    /// @notice Launch fee (bps) of both modes; it can only be lowered.
    uint16 internal constant LAUNCH_FEE_BPS = 15;

    uint8 internal constant MODE_RECENTER = 1;
    uint8 internal constant MODE_EXIT = 2;
    /// @notice Swap-only pause bit. Stops RECENTER and the swap side of EXIT; withdraw-only continues.
    uint8 internal constant MODE_SWAP = 4;

    uint256 internal constant BUCKET_RECENTER = 0;
    uint256 internal constant BUCKET_EXIT_SWAP = 1;

    // ------------------------------------------------------------------ types

    /// @notice Pool rule: the fee for the floor, the hook cap (0 = no hook), the slippage cap, the pair's gate G, the pair
    ///         entry version (0 = the UNLISTED withdraw-only rule), whether swap flows are open (a source exists AND the
    ///         budget is not 0), whether it is budgeted (NC row), and the minimum range width of swap flows.
    struct PoolRule {
        uint24 floorFeePips;
        uint24 pinnedHookFee;
        uint16 maxSlippageBps;
        int24 gate;
        uint32 epoch;
        bool swapOk;
        bool budgeted;
        int24 minWidth;
        // Hook entry fields. Hookless pools and the withdraw-only rule: all 0.
        bool signedFee; // kinds 1 and 4: φ is the keeper-signed total; the floor term here stays 0
        uint24 feeCeiling; // kinds 1, 3, 4: clamp of the user max
        uint8 kind; // hook entry kind (0 = hookless or withdraw-only)
        bool exitOnly; // kind 2 with add-liquidity bits (0x0C00): never mints (RECENTER refused)
        address taxRecipient; // kind 3: the bound tax recipient (the Engine checks that it has no code)
    }

    // ------------------------------------------------------------------ state

    /// @notice Pair table (anchor, source checks, gate, scope). Fixed in the constructor; it cannot be changed.
    GoatV4PairRegistry public immutable REGISTRY;

    mapping(address => bool) public isOperator;
    address public guardian;
    /// @notice bit0 = RECENTER, bit1 = EXIT (withdraw-only included), bit2 = SWAP (RECENTER + the swap side of EXIT).
    uint8 public pausedModes;
    /// @notice Incremented by every pause; voids any queued unpause.
    uint64 public pauseEpoch;
    bool public retired;

    /// @notice Timelock queue: action id → time it was queued.
    mapping(bytes32 => uint256) public queuedAt;

    /// @notice Fee per mode (bps): [0] RECENTER, [1] EXIT.
    uint16[2] public feeBps;
    /// @notice Hourly buckets: [0] RECENTER, [1] swap EXIT. Capacity 0 = limit off (the default).
    GoatRateBucket.Bucket[2] internal _buckets;
    /// @notice Per-kind epoch in the bucket-raise queue id. Every immediate tightening (`lowerBucket`) bumps it, so a
    ///         loosening queued before the tightening needs a fresh 24-hour notice (the same pattern as `pauseEpoch`).
    uint64[2] internal _bucketEpoch;

    // Hook entries (storage, queue / apply / remove, validation) live in the REGISTRY, which also emits their events;
    // the Steward reads them through `REGISTRY.ruleOf` in `_poolRule`.

    // ------------------------------------------------------------------ events (administration)

    event OperatorQueued(address indexed operator, uint256 eta);
    event OperatorActivated(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event GuardianSet(address indexed guardian);
    event GuardianQueued(address indexed guardian, uint256 eta);
    event ModesPaused(uint8 mask, address indexed by);
    event UnpauseQueued(uint8 mask, uint256 eta);
    event ModesUnpaused(uint8 mask);
    event FeeLowered(uint8 indexed mode, uint16 bps);
    event BucketLowered(uint256 indexed kind, uint256 usd8);
    event BucketRaiseQueued(uint256 indexed kind, uint256 usd8, uint256 eta);
    event BucketRaised(uint256 indexed kind, uint256 usd8);
    event Retired();

    // ------------------------------------------------------------------ constructor

    constructor(address initialOwner, address registry_) Ownable(initialOwner) {
        // The table checks every row with the meter at listing; its founding seeding must be sealed.
        if (registry_ == address(0)) revert BadDeployment();
        REGISTRY = GoatV4PairRegistry(registry_);
        if (!REGISTRY.foundingSealed()) revert BadDeployment();
        // The founding hook entry is seeded in the registry (`seedFoundingHooks`, before the seal) and must exist as
        // kind 1.
        HookEntry memory e = REGISTRY.hookEntry(K.FOUNDING_POOL_ID);
        if (e.codehash == bytes32(0) || e.kind != 1) revert BadDeployment();
        feeBps = [LAUNCH_FEE_BPS, LAUNCH_FEE_BPS];
        // The hourly buckets start off (capacity 0).
    }

    // ================================================================== ADMINISTRATION

    /// @notice DISABLED: without an owner, pause / unpause / operators would be frozen for good.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        _;
    }

    /// @dev Pending-owner check (the same error as Ownable2Step's own check); runs BEFORE the lock.
    modifier onlyPendingOwner() {
        if (pendingOwner() != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    /// @notice Ownership entry points change state too, so they take the lock. Identity is checked first (`onlyOwner`),
    ///         then the lock: during a run a non-owner gets `OwnableUnauthorizedAccount`, the owner the reentrancy error.
    function transferOwnership(address newOwner) public override onlyOwner nonReentrant {
        super.transferOwnership(newOwner);
    }

    /// @notice Pending-owner check, then the lock.
    function acceptOwnership() public override onlyPendingOwner nonReentrant {
        super.acceptOwnership();
    }

    function _queue(bytes32 id) internal returns (uint256 eta) {
        queuedAt[id] = block.timestamp;
        eta = block.timestamp + TIMELOCK;
    }

    /// @dev Consumes a queued action: the 24 h TIMELOCK has elapsed and the 7-day QUEUE_GRACE after it has not.
    function _consume(bytes32 id) internal {
        uint256 t = queuedAt[id];
        if (t == 0) revert NotQueued();
        if (block.timestamp < t + TIMELOCK) revert TimelockNotReady();
        if (block.timestamp > t + TIMELOCK + QUEUE_GRACE) revert TimelockExpired();
        delete queuedAt[id];
    }

    function _operatorId(address op) internal pure returns (bytes32) {
        return keccak256(abi.encode("OPERATOR", op));
    }

    /// @notice Adding an operator waits for the 24-hour timelock.
    function queueOperator(address op) external onlyOwner nonReentrant {
        if (op == address(0)) revert BadValue();
        emit OperatorQueued(op, _queue(_operatorId(op)));
    }

    function activateOperator(address op) external onlyOwner nonReentrant {
        _consume(_operatorId(op));
        isOperator[op] = true;
        emit OperatorActivated(op);
    }

    /// @notice Immediate; also drops a queued addition.
    function removeOperator(address op) external onlyOwner nonReentrant {
        isOperator[op] = false;
        delete queuedAt[_operatorId(op)];
        emit OperatorRemoved(op);
    }

    /// @dev The id binds the guardian being replaced, so a queue entry made under another guardian is void.
    function _guardianId(address g) internal view returns (bytes32) {
        return keccak256(abi.encode("GUARDIAN", guardian, g));
    }

    /// @notice Replacing or removing (`g == 0`) a live guardian waits for the 24-hour timelock; the current guardian
    ///         keeps its pause power until `setGuardian(g)` applies the change.
    function queueGuardian(address g) external onlyOwner nonReentrant {
        emit GuardianQueued(g, _queue(_guardianId(g)));
    }

    /// @notice With no guardian set: instant (it only adds a pause veto). Otherwise applies a `queueGuardian(g)` entry
    ///         (24 h elapsed, within the 7-day grace) made while the current guardian was in place.
    function setGuardian(address g) external onlyOwner nonReentrant {
        if (guardian != address(0)) _consume(_guardianId(g));
        guardian = g;
        emit GuardianSet(g);
    }

    /// @notice Immediate pause (owner or guardian). Voids queued unpauses.
    function pause(uint8 mask) external onlyOwnerOrGuardian nonReentrant {
        if (mask == 0 || mask > 7) revert BadValue();
        pausedModes |= mask;
        unchecked {
            ++pauseEpoch;
        }
        emit ModesPaused(mask, msg.sender);
    }

    function _unpauseId(uint8 mask) internal view returns (bytes32) {
        return keccak256(abi.encode("UNPAUSE", mask, pauseEpoch));
    }

    /// @notice Unpausing waits for the 24-hour timelock. Any pause in between voids the queue entry.
    function queueUnpause(uint8 mask) external onlyOwner nonReentrant {
        if (mask == 0 || mask > 7) revert BadValue();
        emit UnpauseQueued(mask, _queue(_unpauseId(mask)));
    }

    function unpause(uint8 mask) external onlyOwner nonReentrant {
        _consume(_unpauseId(mask));
        pausedModes &= ~mask;
        emit ModesUnpaused(mask);
    }

    /// @notice The fee can only be lowered (mode: 1 RECENTER, 2 EXIT). There is no way to raise it.
    function lowerFee(uint8 mode, uint16 bps) external onlyOwner nonReentrant {
        if (mode != MODE_RECENTER && mode != MODE_EXIT) revert BadValue();
        if (bps >= feeBps[mode - 1]) revert BadValue();
        feeBps[mode - 1] = bps;
        emit FeeLowered(mode, bps);
    }

    // ------------------------------------------------------------------ hourly buckets (off by default)

    function _bucketKind(uint256 kind) internal pure {
        if (kind != BUCKET_RECENTER && kind != BUCKET_EXIT_SWAP) revert BadValue();
    }

    /// @notice TIGHTENING, immediate: turn on a bucket that is off, or lower one that is on. 0 (turning it off) is not allowed here.
    function lowerBucket(uint256 kind, uint128 usd8) external onlyOwner nonReentrant {
        _bucketKind(kind);
        uint128 cap = _buckets[kind].capacity;
        if (usd8 == 0 || (cap != 0 && usd8 >= cap)) revert BadValue();
        _buckets[kind].setCapacity(usd8);
        unchecked {
            ++_bucketEpoch[kind]; // voids every queued loosening of this kind
        }
        emit BucketLowered(kind, usd8);
    }

    /// @notice LOOSENING, 24-hour timelock: raise a bucket that is on, or turn it off (`usd8 == 0`).
    function queueBucketRaise(uint256 kind, uint128 usd8) external onlyOwner nonReentrant {
        _raiseCheck(kind, usd8);
        emit BucketRaiseQueued(kind, usd8, _queue(_bucketId(kind, usd8)));
    }

    /// @notice The loosening is checked again against the CURRENT capacity, and the id carries the bucket epoch.
    function applyBucketRaise(uint256 kind, uint128 usd8) external onlyOwner nonReentrant {
        _raiseCheck(kind, usd8);
        _consume(_bucketId(kind, usd8));
        _buckets[kind].setCapacity(usd8);
        emit BucketRaised(kind, usd8);
    }

    /// @dev Loosening precondition (queue and apply): valid kind, open bucket, `usd8` raises it or turns it off (0).
    function _raiseCheck(uint256 kind, uint128 usd8) internal view {
        _bucketKind(kind);
        uint128 cap = _buckets[kind].capacity;
        if (cap == 0 || (usd8 != 0 && usd8 <= cap)) revert BadValue();
    }

    function _bucketId(uint256 kind, uint128 usd8) internal view returns (bytes32) {
        return keccak256(abi.encode("BUCKET", kind, usd8, _bucketEpoch[kind]));
    }

    /// @notice Bucket state (keeper pre-filter): (current level, capacity). Capacity 0 = limit off.
    function bucketState(uint256 kind) external view returns (uint256 level, uint256 capacity) {
        _bucketKind(kind); // BadValue, not Panic(0x32)
        GoatRateBucket.Bucket memory b = _buckets[kind];
        return (GoatRateBucket.current(b), b.capacity);
    }

    // ------------------------------------------------------------------ hook entries
    // Queue / apply / remove and `_validateHookEntry` live in `GoatV4PairRegistry` (owner, 24 h; removal by the owner or
    // the registry guardian, immediate). The Steward only reads: `_poolRule` -> `REGISTRY.ruleOf`, `_hookFeeGuard` at run time.

    /// @notice One-way retirement: new configs and all runs revert for good; clearing a config stays possible.
    function retire() external onlyOwner nonReentrant {
        retired = true;
        emit Retired();
    }

    // ================================================================== GATE, SCOPE

    /// @dev Gate: |spot − anchor| <= G (inclusive). G is set per pair (registry).
    function _gate(int24 spot, int24 anchorTick, int24 g) internal pure {
        int256 d = int256(spot) - int256(anchorTick);
        if (d > g || d < -g) revert GateExceeded();
    }

    /// @dev USD value of the principal at the anchor (8 decimals): p0·usd0/10^dec0 + p1·usd1/10^dec1 (1e18 / 1e6 on ETH/USDG).
    function _usd8(uint256 p0, uint256 p1, GoatV4PairRegistry.Quote memory q) internal pure returns (uint256) {
        return FullMath.mulDiv(p0, q.usd0, q.unit0) + FullMath.mulDiv(p1, q.usd1, q.unit1);
    }

    /**
     * @dev Pool rule:
     *   - LISTED and within policy: a hookless static pool with fee <= 1% and ts <= 200 (the floor deducts that fee), or
     *     a pool whose hook has an entry (code hash matching IN THIS transaction; per kind: kinds 1 / 4 pin = cap, φ
     *     signed per run; kind 3 floor = the pinned φ plus a bound tax recipient; kind 2 no fee, exit-only when it has
     *     add-liquidity bits); `minWidth` = roundUp(max(400, 2(G + ts)), ts).
     *   - Otherwise (unlisted, pair removed, listed hooked pool without an entry, or outside policy): the withdraw-only
     *     rule, and only for a swap-less flow (`swapFlow` -> exactly `PoolNotAllowed()`). Hookless: static fee only (any
     *     fee, any ts), floor = `key.fee` (never used by withdraw-only). Hooked: address bits `& 0x0003 == 0`
     *     (`HookBitsForbidden()`) and pool initialized (`PoolNotAllowed()`). Both then pass the registry's
     *     `checkUnlisted` IN THIS transaction: red tokens; if hooked, red hook, red LIVE code hash and the entry pin.
     *     Withdraw-only rule: {floor (0 | key.fee), 0, S_MAX, WO_GATE, epoch 0, false, false, 0, false, 0, kind 0, false, 0}.
     *   The registry's `ruleOf` counts as "unlisted" only when it reverts with exactly the 4-byte `PoolNotAllowed`; every
     *   other error (empty data from a call that ran out of gas, `HookCodeMismatch`) is bubbled up unchanged.
     */
    function _poolRule(PoolKey memory key, bytes32 poolId, bool swapFlow) internal view returns (PoolRule memory r) {
        address hook = address(key.hooks);
        bool hookless = hook == address(0);
        // One registry read gives the listing AND (hooked pools only) the entry; the registry reverts
        // `HookCodeMismatch()` when an entry exists and the hook's live runtime differs.
        (bool ok, bytes memory ret) = address(REGISTRY).staticcall(
            abi.encodeCall(
                GoatV4PairRegistry.ruleOf, (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), poolId, hook)
            )
        );
        if (ok) {
            HookEntry memory e;
            (r.gate, r.epoch, r.swapOk, r.budgeted, e) = abi.decode(ret, (int24, uint32, bool, bool, HookEntry));
            if (key.tickSpacing <= MAX_TICK_SPACING) {
                if (hookless) {
                    if (key.fee & DYNAMIC_FEE_FLAG == 0 && key.fee <= MAX_POOL_FEE) {
                        (r.floorFeePips, r.maxSlippageBps) = (key.fee, S_MAX);
                        r.minWidth = _minWidth(r.gate, key.tickSpacing);
                        return r;
                    }
                } else if (e.codehash != bytes32(0)) {
                    // Listed pool with an entry, per kind. Kind 2 (+0x0C00 add bits = beforeAdd / afterAddLiquidity):
                    // exit-only; kind 3: the pinned φ is the floor and the tax recipient is bound; kinds 1 and 4: the
                    // pin is the cap only, φ is signed per run (floor 0 here).
                    (r.kind, r.maxSlippageBps, r.feeCeiling) = (e.kind, e.maxSlippageBps, e.feeCeiling);
                    if (e.kind == KIND_EXTERNAL_VENUE) r.exitOnly = e.requiredBits & 0x0C00 != 0;
                    else if (e.kind == KIND_CONST_TAX) (r.floorFeePips, r.taxRecipient) = (e.pinnedFee, e.taxRecipient);
                    else (r.pinnedHookFee, r.signedFee) = (e.pinnedFee, true); // kinds 1 and 4
                    r.minWidth = _minWidth(r.gate, key.tickSpacing);
                    return r;
                }
            }
        } else if (ret.length != 4 || bytes4(ret) != PoolNotAllowed.selector) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        // ---- unlisted, listed without an entry, or outside policy: withdraw-only flows only ----
        if (swapFlow) revert PoolNotAllowed();
        r = PoolRule(0, 0, S_MAX, WO_GATE, 0, false, false, 0, false, 0, 0, false, address(0));
        if (hookless) {
            if (key.fee & DYNAMIC_FEE_FLAG != 0) revert PoolNotAllowed();
            r.floorFeePips = key.fee;
        } else {
            if (uint160(hook) & WO_FORBIDDEN_HOOK_BITS != 0) revert HookBitsForbidden();
            (uint160 sp,,) = GoatPoolSlots.slot0(POOL_MANAGER, poolId);
            if (sp == 0) revert PoolNotAllowed();
        }
        // Red tokens; if hooked: red hook, red LIVE code hash (same-transaction EXTCODEHASH) and the entry pin.
        REGISTRY.checkUnlisted(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), hook, poolId);
    }

    /// @dev roundUp(max(400, 2(G + ts)), ts).
    function _minWidth(int24 g, int24 ts) internal pure returns (int24 w) {
        w = 2 * (g + ts);
        if (w < MIN_WIDTH) w = MIN_WIDTH;
        int24 rem = w % ts;
        if (rem != 0) w += ts - rem;
    }

    /// @dev In the same transaction: the hook's configured cap must not exceed the pinned value. The live `currentFee`
    ///      is deliberately not read here (a floor derived from it would follow a fee jump).
    function _hookFeeGuard(address hook, bytes32 poolId, uint24 pinned) internal view {
        uint24 live = IGoatFeeCapHook(hook).maxFee(poolId);
        if (live > pinned) revert HookFeeCapRaised(live, pinned);
    }
}

