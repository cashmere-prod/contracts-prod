// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {GoatV4StewardCore} from "./base/GoatV4StewardCore.sol";
import {GoatV4StewardEngine} from "./GoatV4StewardEngine.sol";
import {GoatV4PairRegistry} from "./GoatV4PairRegistry.sol";
import {GoatRecenterMath} from "./lib/GoatRecenterMath.sol";
import {GoatRateBucket} from "./lib/GoatRateBucket.sol";
import {GoatPoolSlots} from "./lib/GoatPoolSlots.sol";
import {IGoatPosmNft} from "./interfaces/GoatV4External.sol";
import "./lib/GoatV4Errors.sol";

/**
 * @notice Two-mode automation for Uniswap v4 positions:
 *   - RECENTER: moves a position that left its range to a new range of the same width, centred on the anchor.
 *   - EXIT:     closes the position when the price crosses the owner's level; per side "withdraw" or "withdraw and swap".
 *   ONE config slot per position, so the two modes can never be active together.
 *
 * @dev Swap flows (RECENTER, swap EXIT) run only on a pair with a pool-based price source (`ExitOnlyPair`) and while
 *      the pair entry version the config is bound to is unchanged (`PairChanged`). Withdraw-only EXIT runs on every
 *      allowed pool and is not stopped by the source checks or the hourly bucket; it is triggered by the v4 pool's spot
 *      price, since a withdrawal at a moved price is worth no less than at the fair price.
 *
 * @dev Trust model: the CONTRACT computes the trigger, the centre, the price limit and the floor. The keeper sends only
 *      `(tokenId, deadline)`, optionally the owner's permit signature and, on `runSwap`, the exec pool and the signed
 *      fees, all of which the contract checks. There is no price, amount, recipient, hookData or mode input.
 *
 * @dev Two contracts: the Steward DECIDES (config, roles, anchor, trigger, source checks, gate, caps, buckets, new range)
 *      and passes a plan to the `GoatV4StewardEngine` it creates in its constructor; the Engine is the only holder of
 *      the NFT approval and obeys only the Steward. The user's approval / permit goes to the ENGINE.
 *
 * @dev No per-position cap; the hourly limit is off by default; hookless pools plus hooks whose entry pins their code
 *      hash. The floor deducts the LP fee (static, or the hook's pinned term) and the protocol fee share.
 */
contract GoatV4Steward is GoatV4StewardCore {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using GoatRateBucket for GoatRateBucket.Bucket;

    // ------------------------------------------------------------------ config bounds

    /// @dev T >= G + 1 (G per pair from the registry, at least 100): every spot inside the gate is then outside the old
    ///      range on the same side (one-sided burn). Checked at config time only: G is part of the registry's semantic
    ///      hash, so a later change of G bumps the pair epoch and every swap flow reverts `PairChanged` in `_swapPre`
    ///      until the owner sets the config again (the same holds for the G + 1 bound of the EXIT swap side).
    uint16 internal constant MAX_TRIGGER_TICKS = 20_000;
    uint32 internal constant MIN_INTERVAL_FLOOR = 3600;
    uint32 internal constant MAX_INTERVAL = 30 days;
    uint8 internal constant MAX_BUDGET = 20;

    /// @notice EXIT flags.
    uint8 internal constant LOWER_ON = 1;
    uint8 internal constant UPPER_ON = 2;
    uint8 internal constant SWAP_ON_LOWER = 4; // lower side: token0 → token1
    uint8 internal constant SWAP_ON_UPPER = 8; // upper side: token1 → token0
    /// @notice Opt-in: a run is also authorized by `isApprovedForAll(owner, ENGINE)`; on RECENTER the config moves to the new id.
    uint8 internal constant STANDING = 0x10;

    // ------------------------------------------------------------------ types

    /// @notice One slot (232 bits). `lastRunAt` is written only by a run and is protected from user input. `pairEpoch`:
    ///         the pair entry version when the config was written (swap flows require it to be equal at run time).
    ///         `maxSwapFeePips`: the owner-signed max swap fee of the position (a TOTAL fee in pips); it moves with the
    ///         config to the new id on RECENTER (STANDING lineage included).
    struct Config {
        uint8 mode; // 0 off, 1 RECENTER, 2 EXIT
        uint16 triggerTicks; // RECENTER: T
        uint16 slippageBps; // both modes: s
        uint32 minInterval; // RECENTER
        uint8 budget; // RECENTER: runs left
        uint40 lastRunAt; // RECENTER
        uint8 flags; // EXIT
        int24 lowerTrigger; // EXIT: absolute tick
        int24 upperTrigger; // EXIT: absolute tick
        uint32 pairEpoch; // both modes: the pair entry version at config time
        uint24 maxSwapFeePips; // swap flows: [max(1, own φ), MAX_USER_SWAP_FEE]; withdraw-only EXIT: stored 0
    }

    struct RangeParams {
        uint16 triggerTicks;
        uint16 slippageBps;
        uint32 minInterval;
        uint8 budget;
        bool standing; // lineage continues through the ForAll approval
        uint24 maxSwapFeePips; // [1, MAX_USER_SWAP_FEE] (the owner-signed cap on the total fee)
    }

    struct ExitParams {
        uint8 flags;
        int24 lowerTrigger;
        int24 upperTrigger;
        uint16 slippageBps;
        uint24 maxSwapFeePips; // with a swap bit: [max(1, own φ), MAX_USER_SWAP_FEE]; withdraw-only: ignored, stored 0
    }

    /// @dev Operator inputs of `runSwap` (never stored). `signed` = the call came through `runSwap`; `zfo` / `ofz` = the
    ///      keeper-signed TOTAL fee per direction; `fee` / `ts` / `hooks` = the exec venue (`ts == 0`: the own pool).
    ///      Plain `run` / `runWithPermit` pass the zero value (unsigned, own pool).
    struct Leg {
        bool signed;
        uint24 zfo;
        uint24 ofz;
        uint24 fee;
        int24 ts;
        address hooks;
    }

    /// @notice The owner's POSM permit signature (not an economic parameter).
    struct PermitData {
        uint256 deadline;
        uint256 nonce;
        bytes signature;
    }

    struct RerangeReport {
        bytes32 poolId;
        int24 oldLower;
        int24 oldUpper;
        int24 newLower;
        int24 newUpper;
        uint128 oldLiquidity;
        uint128 newLiquidity;
        int24 anchorTick;
        uint160 anchorSqrtPriceX96;
        int24 twapTick;
        int24 spotTickBefore;
        uint160 sqrtPriceAtMint;
        uint256 principal0;
        uint256 principal1;
        uint256 lpFees0;
        uint256 lpFees1;
        uint256 protocolFee0;
        uint256 protocolFee1;
        bool zeroForOne;
        uint256 swapIn;
        uint256 swapOut;
        uint256 swapFloor;
        uint256 minted0;
        uint256 minted1;
        uint256 refund0;
        uint256 refund1;
        uint256 valueUsd8;
        bool bySelf;
        bool vetoApplied;
    }

    struct ExitReport {
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool upperSide;
        bool swapped;
        bool vetoApplied;
        int24 anchorTick;
        uint160 anchorSqrtPriceX96;
        int24 twapTick;
        int24 spotTickBefore;
        uint256 principal0;
        uint256 principal1;
        uint256 lpFees0;
        uint256 lpFees1;
        uint256 protocolFee0;
        uint256 protocolFee1;
        uint256 swapIn;
        uint256 swapOut;
        uint256 swapFloor;
        uint256 paid0;
        uint256 paid1;
        uint256 valueUsd8;
        bool bySelf;
    }

    /// @dev Pre-run evaluation (pure read; runs and `evaluateRun` use the same function).
    struct Eval {
        address owner;
        PoolKey key;
        bytes32 poolId;
        PoolRule rule;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        GoatV4PairRegistry.Quote anchor; // zero for withdraw-only (no anchor is read)
        int24 twapTick;
        bool vetoApplied;
        int24 spotTick;
        bool upperSide;
        bool swapExit;
        uint256 p0;
        uint256 p1;
        uint256 valueUsd8;
    }

    // ------------------------------------------------------------------ state

    mapping(uint256 => Config) internal _configs;
    /// @notice The owner who wrote the config. A run requires `ownerOf == configOwner` (it stops if the NFT changes hands).
    mapping(uint256 => address) public configOwner;

    // ------------------------------------------------------------------ events

    event RangeConfigSet(uint256 indexed tokenId, address indexed owner, RangeParams p);
    event ExitConfigSet(uint256 indexed tokenId, address indexed owner, ExitParams p);
    event ConfigCleared(uint256 indexed tokenId, address indexed by);
    /// @dev Emitted after every RECENTER run: the burned and minted token ids, the owner and the full report.
    event Reranged(uint256 indexed burnedTokenId, uint256 indexed mintedTokenId, address indexed owner, RerangeReport r);
    event PositionExited(uint256 indexed tokenId, address indexed owner, ExitReport r);
    /// @notice Emitted after every run with `swapIn > 0` (the report structs are unchanged). `execPoolId` = the pool the
    ///         swap ran on; `feePips` = the exec rule's φ (the floor term actually applied is
    ///         `min(feePips, lp_live + tax_live)`, further capped at the own pool's φ on a hookless or kind-3 own pool;
    ///         it can be recomputed from `totalFeePips` and the exec pool's pf); `totalFeePips` = the exec pool's live
    ///         total (pf ⊕ lp + tax) the Engine checked (the sizer uses only its input-side part); `feeSigned` = a keeper
    ///         signature applied (`runSwap`, any exec kind). Topic 0x0d5b7977….
    event SwapLeg(uint256 indexed tokenId, bytes32 indexed execPoolId, uint24 feePips, uint24 totalFeePips, bool feeSigned);

    /// @notice The executor and the only holder of the NFT approval. Created in this constructor; it cannot be changed.
    GoatV4StewardEngine public immutable ENGINE;

    constructor(address initialOwner, address feeRecipient_, address registry_)
        GoatV4StewardCore(initialOwner, registry_)
    {
        ENGINE = new GoatV4StewardEngine(feeRecipient_);
    }

    /// @notice Fee recipient (treasury), stored in the Engine. This Steward's owner changes it with
    ///         `ENGINE.setFeeRecipient(r)`; the setter lives in the Engine because of the Steward's code size limit.
    ///         The `FeeRecipientSet` event is emitted by the Engine.
    function feeRecipient() external view returns (address) {
        return ENGINE.feeRecipient();
    }

    // ================================================================== CONFIG

    function configOf(uint256 tokenId) external view returns (Config memory cfg, address cfgOwner) {
        return (_configs[tokenId], configOwner[tokenId]);
    }

    /// @dev Shared checks of a config write: not retired, the mode (and the SWAP bit for a swap config) not paused, the
    ///      caller is the owner, the pool rule (`_poolRule`), slippage within the pool's cap, no subscriber, liquidity > 0;
    ///      for a swap config also a LISTED pool, a pair open to swaps and width >= the pool's minimum width. The anchor
    ///      is NOT read.
    function _configPreflight(uint256 tokenId, uint8 mode, uint16 slippageBps, bool swapFlow)
        internal
        view
        returns (address owner, int24 lo, int24 hi, PoolRule memory rule)
    {
        if (retired) revert IsRetired();
        if (pausedModes & (swapFlow ? mode | MODE_SWAP : mode) != 0) revert ModePaused();
        owner = IGoatPosmNft(address(POSM)).ownerOf(tokenId);
        if (msg.sender != owner) revert NotTokenOwner();
        (PoolKey memory key, PositionInfo info) = POSM.getPoolAndPositionInfo(tokenId);
        rule = _poolRule(key, PoolId.unwrap(key.toId()), swapFlow); // a swap config never gets the withdraw-only rule
        if (slippageBps < MIN_SLIPPAGE_BPS || slippageBps > rule.maxSlippageBps) revert BadConfig();
        if (info.hasSubscriber()) revert HasSubscriber();
        lo = info.tickLower();
        hi = info.tickUpper();
        if (swapFlow) _swapRule(rule, hi - lo);
        if (POSM.getPositionLiquidity(tokenId) == 0) revert EmptyPosition();
    }

    /// @dev Pool conditions of a swap flow (config and run): a LISTED pool (the unlisted withdraw-only rule has epoch 0),
    ///      a source and an open budget (`ExitOnlyPair` / `SwapsOff`), width >= `minWidth`.
    function _swapRule(PoolRule memory rule, int24 width) internal pure {
        if (rule.epoch == 0) revert PoolNotAllowed();
        if (!rule.swapOk) {
            if (rule.budgeted) revert SwapsOff();
            revert ExitOnlyPair();
        }
        if (width < rule.minWidth) revert PoolNotAllowed();
    }

    /// @notice RECENTER config. Executes nothing. Only on a pair with a source and open swaps.
    ///         An exit-only kind-2 own pool (add-liquidity hook bits 0x0C00) never mints: `BadConfig()`.
    function setRangeConfig(uint256 tokenId, RangeParams calldata p) external nonReentrant {
        (address owner,,, PoolRule memory rule) = _configPreflight(tokenId, MODE_RECENTER, p.slippageBps, true);
        if (
            int24(uint24(p.triggerTicks)) <= rule.gate || p.triggerTicks > MAX_TRIGGER_TICKS
                || p.minInterval < MIN_INTERVAL_FLOOR || p.minInterval > MAX_INTERVAL || p.budget == 0
                || p.budget > MAX_BUDGET || p.maxSwapFeePips == 0 || p.maxSwapFeePips > MAX_USER_SWAP_FEE
                || p.maxSwapFeePips < rule.floorFeePips || rule.exitOnly
        ) revert BadConfig();

        uint40 last = _configs[tokenId].lastRunAt;
        _configs[tokenId] = Config({
            mode: MODE_RECENTER,
            triggerTicks: p.triggerTicks,
            slippageBps: p.slippageBps,
            minInterval: p.minInterval,
            budget: p.budget,
            lastRunAt: last,
            flags: p.standing ? STANDING : 0,
            lowerTrigger: 0,
            upperTrigger: 0,
            pairEpoch: rule.epoch,
            maxSwapFeePips: p.maxSwapFeePips
        });
        configOwner[tokenId] = owner;
        emit RangeConfigSet(tokenId, owner, p);
    }

    /// @notice EXIT config: two absolute levels, each at least G + 1 ticks outside the range. A swap flag only on a
    ///         LISTED pool of a pair with open swaps; withdraw-only on every hookless static pool, on a hooked pool with
    ///         an entry, and on an entry-less hooked pool (bits & 0x3 == 0, initialized, not red-listed, pin holding). On
    ///         an entry-less hooked pool a mixed config (one side swapping) is `PoolNotAllowed`: only swap-less sides can
    ///         be set. Bit 0x10 (STANDING) is optional.
    function setExitConfig(uint256 tokenId, ExitParams calldata p) external nonReentrant {
        bool swapFlow = p.flags & (SWAP_ON_LOWER | SWAP_ON_UPPER) != 0;
        (address owner, int24 lo, int24 hi, PoolRule memory rule) =
            _configPreflight(tokenId, MODE_EXIT, p.slippageBps, swapFlow);
        int24 g = rule.gate;
        bool lowerOn = p.flags & LOWER_ON != 0;
        bool upperOn = p.flags & UPPER_ON != 0;
        if (p.flags > 31 || (!lowerOn && !upperOn)) revert BadConfig();
        // A config with any swap side signs a max in [1, MAX_USER_SWAP_FEE] that is not below the own pool's floor φ
        // (hookless key.fee, kind-3 pinned φ; 0 for kinds 1 / 2 / 4); a withdraw-only config may pass 0.
        if (
            swapFlow
                && (p.maxSwapFeePips == 0 || p.maxSwapFeePips > MAX_USER_SWAP_FEE || p.maxSwapFeePips < rule.floorFeePips)
        ) revert BadConfig();
        if (p.flags & SWAP_ON_LOWER != 0 && !lowerOn) revert BadConfig();
        if (p.flags & SWAP_ON_UPPER != 0 && !upperOn) revert BadConfig();
        if (lowerOn) {
            if (p.lowerTrigger < TickMath.MIN_TICK || int256(p.lowerTrigger) > int256(lo) - g - 1) revert BadConfig();
        }
        if (upperOn) {
            if (p.upperTrigger > TickMath.MAX_TICK || int256(p.upperTrigger) < int256(hi) + g + 1) revert BadConfig();
        }
        uint40 last = _configs[tokenId].lastRunAt;
        _configs[tokenId] = Config({
            mode: MODE_EXIT,
            triggerTicks: 0,
            slippageBps: p.slippageBps,
            minInterval: 0,
            budget: 0,
            lastRunAt: last,
            flags: p.flags,
            // Canonical storage: a disabled side's trigger and a withdraw-only max fee are stored as 0
            // (the `ExitConfigSet` event echoes the caller's input; `configOf` is the canonical record).
            lowerTrigger: lowerOn ? p.lowerTrigger : int24(0),
            upperTrigger: upperOn ? p.upperTrigger : int24(0),
            pairEpoch: rule.epoch,
            maxSwapFeePips: swapFlow ? p.maxSwapFeePips : 0
        });
        configOwner[tokenId] = owner;
        emit ExitConfigSet(tokenId, owner, p);
    }

    /// @notice Deletes the config. The owner or the config's writer (the previous owner if the NFT changed hands) can
    ///         call it. Not affected by pause or retirement: turning automation off always works. `lastRunAt` is kept.
    function clearConfig(uint256 tokenId) external nonReentrant {
        if (msg.sender != configOwner[tokenId]) {
            address cur;
            try IGoatPosmNft(address(POSM)).ownerOf(tokenId) returns (address o) {
                cur = o;
            } catch {}
            if (msg.sender != cur) revert NotConfigOwnerOrTokenOwner();
        }
        uint40 last = _configs[tokenId].lastRunAt;
        delete _configs[tokenId];
        _configs[tokenId].lastRunAt = last;
        delete configOwner[tokenId];
        emit ConfigCleared(tokenId, msg.sender);
    }

    // ================================================================== RUN

    /// @notice Keeper (an active operator) or the owner. The only inputs are tokenId and deadline. Unsigned: a swap flow
    ///         whose exec pool needs a signed fee (kinds 1 / 4) gives `FeeNotSigned`; withdraw-only always runs.
    function run(uint256 tokenId, uint256 deadline) external nonReentrant {
        (Config memory cfg, address owner, bool bySelf) = _preflight(tokenId, deadline);
        Leg memory none;
        _perform(tokenId, cfg, owner, bySelf, none);
    }

    /// @notice `run` with the keeper-signed per-direction TOTAL fees (`signedZfo` for a token0 sale, `signedOfz` for a
    ///         token1 sale; only the swap direction is read) and the exec venue (`execTickSpacing == 0`: the own pool).
    ///         Signatures are never stored; a withdraw-only run ignores every extra argument. Another venue must be a
    ///         listed swap pool of the SAME pair (`_poolRule(xk, xid, true)`, else `PoolNotAllowed`); the Engine gates
    ///         the exec pool before and after the swap and mints in the own pool. A kind-2 EXTERNAL_VENUE pool is never
    ///         the exec pool (own position: `OwnVenueSwapForbidden`, so its swap flows need `runSwap` naming another
    ///         venue; other positions: `PoolNotAllowed`).
    function runSwap(
        uint256 tokenId,
        uint256 deadline,
        uint24 execFee,
        int24 execTickSpacing,
        address execHooks,
        uint24 signedZfo,
        uint24 signedOfz
    ) external nonReentrant {
        (Config memory cfg, address owner, bool bySelf) = _preflight(tokenId, deadline);
        _perform(tokenId, cfg, owner, bySelf, Leg(true, signedZfo, signedOfz, execFee, execTickSpacing, execHooks));
    }

    /// @notice `run` plus the owner's POSM permit signature. A failing permit is ignored; the real condition is `getApproved`.
    function runWithPermit(uint256 tokenId, uint256 deadline, PermitData calldata permit) external nonReentrant {
        (Config memory cfg, address owner, bool bySelf) = _preflight(tokenId, deadline);
        // A permit that was already used (for example by an earlier attempt) must not fail the run; an invalid signature
        // writes no approval, and the `getApproved` condition below catches it.
        try IGoatPosmNft(address(POSM)).permit(
            address(ENGINE), tokenId, permit.deadline, permit.nonce, permit.signature
        ) {} catch {}
        Leg memory none; // no signed variant: a signed exec pool gives `FeeNotSigned`
        _perform(tokenId, cfg, owner, bySelf, none);
    }

    /// @dev Shared entry checks (deadline, runnable config, caller). `owner` is read BEFORE any external call of the run.
    function _preflight(uint256 tokenId, uint256 deadline)
        internal
        view
        returns (Config memory cfg, address owner, bool bySelf)
    {
        if (block.timestamp > deadline) revert RunExpired();
        (cfg, owner) = _runnable(tokenId);
        bySelf = msg.sender == owner;
        if (!bySelf && !isOperator[msg.sender]) revert NotOperator();
    }

    /// @dev Shared start of a run and a preview: not retired, a config exists, the mode (on RECENTER also the SWAP bit)
    ///      is not paused, the owner has not changed.
    function _runnable(uint256 tokenId) internal view returns (Config memory cfg, address owner) {
        if (retired) revert IsRetired();
        cfg = _configs[tokenId];
        if (cfg.mode == 0) revert NoActiveConfig();
        if (pausedModes & (cfg.mode == MODE_RECENTER ? MODE_RECENTER | MODE_SWAP : cfg.mode) != 0) revert ModePaused();
        owner = IGoatPosmNft(address(POSM)).ownerOf(tokenId);
        if (owner != configOwner[tokenId]) revert OwnerChanged();
    }

    /**
     * @dev Shared evaluation (pure read): approval (token approval, or STANDING plus ForAll), scope, subscriber,
     *      liquidity, trigger and, for swap flows, the pool conditions + version + anchor + source checks + the
     *      user-favourable median + hook cap + gate; on RECENTER also the run budget and minInterval.
     *
     *      Withdraw-only EXIT is triggered by SPOT and reads no anchor, gate, source check, version or budget: when spot
     *      has crossed the level of a swap-less side it exits right away (a withdrawal at a moved price is worth no less
     *      than at the fair price, dV/dS >= 0). Otherwise the swap side is triggered by the ANCHOR (spot alone never
     *      triggers a swap) and runs every swap check.
     *
     *      The anchor trigger reads the median that DELAYS it: the upper side (EXIT `upperTrigger`, RECENTER
     *      `tickUpper + T`) needs `tickLo` >= the level, the lower side (EXIT `lowerTrigger`, RECENTER `tickLower - T`)
     *      needs `tickHi` <= the level. On NC+POKE these are medLo / medHi, which unregistered pokes can only push
     *      outward, so they can only delay a trigger. On other kinds `tickLo == tickHi == tick` (`anchorOf`) and the
     *      behaviour is the same. The trigger and the floor use the same median of the same side.
     */
    function _evaluate(uint256 tokenId, Config memory cfg, address owner) internal view returns (Eval memory e) {
        e.owner = owner;
        if (IGoatPosmNft(address(POSM)).getApproved(tokenId) != address(ENGINE)) {
            if (cfg.flags & STANDING == 0 || !IGoatPosmNft(address(POSM)).isApprovedForAll(owner, address(ENGINE))) {
                revert NotApprovedForRun();
            }
        }
        PositionInfo info;
        (e.key, info) = POSM.getPoolAndPositionInfo(tokenId);
        e.poolId = PoolId.unwrap(e.key.toId());
        // Spot first, then the flow, then the rule. `wo` = the swap-less side of an EXIT config is hit by spot (the same
        // test as the branch below); every other outcome of a RECENTER or swap-flagged config asks for a swap rule, so
        // the withdraw-only rule can never reach a swap flow.
        (, e.spotTick,) = GoatPoolSlots.slot0(POOL_MANAGER, e.poolId);
        {
            int256 sp0 = e.spotTick;
            bool wo = cfg.mode == MODE_EXIT
                && ((cfg.flags & LOWER_ON != 0 && sp0 <= cfg.lowerTrigger && cfg.flags & SWAP_ON_LOWER == 0)
                    || (cfg.flags & UPPER_ON != 0 && sp0 >= cfg.upperTrigger && cfg.flags & SWAP_ON_UPPER == 0));
            e.rule = _poolRule(
                e.key, e.poolId, cfg.mode == MODE_RECENTER || (!wo && cfg.flags & (SWAP_ON_LOWER | SWAP_ON_UPPER) != 0)
            );
        }
        if (info.hasSubscriber()) revert HasSubscriber();
        e.tickLower = info.tickLower();
        e.tickUpper = info.tickUpper();
        e.liquidity = POSM.getPositionLiquidity(tokenId);
        if (e.liquidity == 0) revert EmptyPosition();

        address c0 = Currency.unwrap(e.key.currency0);
        address c1 = Currency.unwrap(e.key.currency1);

        if (cfg.mode == MODE_RECENTER) {
            _swapPre(cfg, e);
            e.anchor = REGISTRY.anchorOf(c0, c1);
            // Delaying median (lower side medHi, upper side medLo; == tick outside NC+POKE).
            int256 t = int256(uint256(cfg.triggerTicks));
            if (e.anchor.tickHi <= int256(e.tickLower) - t) e.upperSide = false;
            else if (e.anchor.tickLo >= int256(e.tickUpper) + t) e.upperSide = true;
            else revert NotTriggered();
        } else {
            int256 sp = e.spotTick;
            if (cfg.flags & LOWER_ON != 0 && sp <= cfg.lowerTrigger && cfg.flags & SWAP_ON_LOWER == 0) {
                e.upperSide = false;
            } else if (cfg.flags & UPPER_ON != 0 && sp >= cfg.upperTrigger && cfg.flags & SWAP_ON_UPPER == 0) {
                e.upperSide = true;
            } else if (cfg.flags & (SWAP_ON_LOWER | SWAP_ON_UPPER) != 0) {
                if (pausedModes & MODE_SWAP != 0) revert ModePaused();
                _swapPre(cfg, e);
                e.anchor = REGISTRY.anchorOf(c0, c1);
                // Same delaying median as the RECENTER branch.
                if (cfg.flags & SWAP_ON_LOWER != 0 && e.anchor.tickHi <= cfg.lowerTrigger) e.upperSide = false;
                else if (cfg.flags & SWAP_ON_UPPER != 0 && e.anchor.tickLo >= cfg.upperTrigger) e.upperSide = true;
                else revert NotTriggered();
                e.swapExit = true;
            } else {
                revert NotTriggered();
            }
        }

        // One-sided principal (independent of the price, with the pool's removal rounding).
        (e.p0, e.p1) = GoatRecenterMath.oneSidedPrincipal(e.upperSide, e.tickLower, e.tickUpper, e.liquidity);

        if (cfg.mode == MODE_RECENTER || e.swapExit) {
            // Source checks with the MID anchor; then the user-favourable median (tickLo when selling token1, tickHi
            // when selling token0; the same tick on CL and v3 kinds), which the gate, centre, price limit and floor use.
            (e.twapTick, e.vetoApplied) = REGISTRY.vetoOf(c0, c1, e.anchor.tick);
            int24 fav = e.upperSide ? e.anchor.tickLo : e.anchor.tickHi;
            if (fav != e.anchor.tick) {
                e.anchor.tick = fav;
                e.anchor.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(fav);
            }
            // Own-pool cap guard for kind 1 only (kind 4 has no `maxFee`; its pin is checked in the Engine), on every
            // swap flow whatever the exec pool.
            if (e.rule.kind == KIND_SIGNED_FEE) _hookFeeGuard(address(e.key.hooks), e.poolId, e.rule.pinnedHookFee);
            _gate(e.spotTick, e.anchor.tick, e.rule.gate);
            e.valueUsd8 = _usd8(e.p0, e.p1, e.anchor);
        }

        if (cfg.mode == MODE_RECENTER) {
            if (cfg.budget == 0) revert BudgetExhausted();
            if (block.timestamp < uint256(cfg.lastRunAt) + cfg.minInterval) revert TooSoon();
        }
    }

    /// @dev Run conditions of a swap flow: the pool rule (width included) and a current pair version in the config.
    ///      Run-time counterpart of the `setRangeConfig` refusal: RECENTER on an exit-only kind-2 own pool ->
    ///      `PoolNotAllowed()` (the entry kind can change after the config, e.g. kind 1 queued again as kind 2).
    function _swapPre(Config memory cfg, Eval memory e) internal pure {
        _swapRule(e.rule, e.tickUpper - e.tickLower);
        if (cfg.mode == MODE_RECENTER && e.rule.exitOnly) revert PoolNotAllowed();
        if (cfg.pairEpoch != e.rule.epoch) revert PairChanged();
    }

    /// @dev Which hourly bucket applies (if any): RECENTER → 0, swap EXIT → 1, withdraw-only → none.
    function _bucketOf(Config memory cfg, Eval memory e) internal pure returns (bool counted, uint256 kind) {
        if (cfg.mode == MODE_RECENTER) return (true, BUCKET_RECENTER);
        if (e.swapExit) return (true, BUCKET_EXIT_SWAP);
        return (false, 0);
    }

    /// @dev Body of a run.
    function _perform(uint256 tokenId, Config memory cfg, address owner, bool bySelf, Leg memory leg) internal {
        Eval memory e = _evaluate(tokenId, cfg, owner);
        // The owner's own run is not counted in the bucket; an operator run is.
        (bool counted, uint256 kind) = _bucketOf(cfg, e);
        if (counted && !bySelf) {
            _buckets[kind].consume(e.valueUsd8);
            // On a budgeted pair the one-sided PRINCIPAL of an OPERATOR run (swap-less RECENTER included) is taken from
            // the pair's buckets BEFORE the Engine call (hard and X legs in their own units). The owner's own run is not
            // counted. Without room the whole run reverts.
            if (e.rule.budgeted) {
                REGISTRY.consumeSwapBudget(
                    Currency.unwrap(e.key.currency0), Currency.unwrap(e.key.currency1), e.p0, e.p1
                );
            }
        }

        GoatV4StewardEngine.Plan memory plan;
        plan.tokenId = tokenId;
        plan.key = e.key;
        plan.owner = e.owner;
        plan.upperSide = e.upperSide;
        plan.swapExit = e.swapExit;
        plan.p0 = e.p0;
        plan.p1 = e.p1;
        plan.anchorTick = e.anchor.tick;
        plan.anchorSqrtPriceX96 = e.anchor.sqrtPriceX96;
        plan.gate = e.rule.gate;
        // The pool the swap leg runs on (`SwapLeg.execPoolId`): the own pool, or the admitted exec pool.
        bytes32 xid = e.poolId;
        if (cfg.mode == MODE_RECENTER || e.swapExit) {
            // In swap flows the floor AND the sizing fee are the EXEC rule's φ, never `key.fee` (0x800000 on a hooked
            // pool). Withdraw-only does not use these fields (no swap): they stay 0.
            PoolRule memory xr = e.rule;
            if (leg.ts != 0) {
                // The exec venue. The currencies are FORCED to the position's, so a pool of another pair has another
                // poolId. `_poolRule(xk, xid, true)` is the whole admission: unlisted, another pair's, entry-less hooked
                // or outside policy -> `PoolNotAllowed()`. The pair-level epoch and `swapOk` are the values the own rule
                // already passed (one registry row per pair): no second check. Depth: the exec pool passed the walk
                // check at listing; depth at the swap size is the keeper's choice, backed on chain by the Engine's
                // `PartialFill` at anchor ∓ G plus the floor.
                PoolKey memory xk = PoolKey(e.key.currency0, e.key.currency1, leg.fee, leg.ts, IHooks(leg.hooks));
                xid = PoolId.unwrap(xk.toId());
                if (xid != e.poolId) {
                    xr = _poolRule(xk, xid, true);
                    (plan.execFee, plan.execTickSpacing, plan.execHooks) = (leg.fee, leg.ts, leg.hooks);
                }
            }
            // A kind-2 EXTERNAL_VENUE pool is never the exec pool. Its own positions must swap elsewhere (plain `run`, or
            // `runSwap` with ts 0 or the own key: `OwnVenueSwapForbidden()`); other positions of the pair never use it as
            // a venue (`PoolNotAllowed()`). The own pool's hook is then never entered.
            if (xr.kind == KIND_EXTERNAL_VENUE) {
                if (xid == e.poolId) revert OwnVenueSwapForbidden();
                revert PoolNotAllowed();
            }
            // φ = the exec rule's term (hookless key.fee, kind 3 pinned φ) or, for kinds 1 / 4, the keeper-signed total
            // of the swap direction (zeroForOne = !upperSide; the other direction is ignored).
            // bound = min(user max, entry ceiling) for EVERY exec kind.
            uint24 phi = xr.floorFeePips;
            uint24 bound = cfg.maxSwapFeePips;
            if (xr.feeCeiling != 0 && xr.feeCeiling < bound) bound = xr.feeCeiling;
            uint24 sig = e.upperSide ? leg.ofz : leg.zfo;
            if (xr.signedFee) {
                if (!leg.signed) revert FeeNotSigned();
                phi = sig;
            }
            if (phi > bound) revert SwapFeeAboveMax(phi, bound);
            // The Engine checks the exec pool's live TOTAL (pf ⊕ lp + tax) for the swap direction against `feeCheck`
            // right before PM.swap, for every exec kind: the signed total on `runSwap` (any kind; `feeSigned` ->
            // `FeeAboveSigned`), else min(user max, ceiling) (`SwapFeeAboveMax`). feeCheck <= bound always.
            if (leg.signed) {
                if (sig > bound) revert SwapFeeAboveMax(sig, bound);
                (plan.feeCheck, plan.feeSigned) = (sig, true);
            } else {
                plan.feeCheck = bound;
            }
            plan.floorFeePips = phi;
            // On a hookless or kind-3 own pool, the operator's venue choice never widens the floor's fee term above the
            // own pool's φ. A pricier kind-3 venue is refused instead: its φ is also the tax the Engine prices. Kind-1 / 4
            // own pools (φ signed per run) and kind-2 own pools are not covered by this rule.
            uint24 ownPhi = e.rule.floorFeePips;
            if (phi > ownPhi && (e.rule.kind == 0 || e.rule.kind == KIND_CONST_TAX)) {
                if (xr.kind == KIND_CONST_TAX) revert SwapFeeAboveMax(phi, ownPhi);
                plan.floorFeePips = ownPhi;
            }
            plan.pinnedHookFee = xr.pinnedHookFee;
            // The exec kind and the kind-3 bound recipient (0 otherwise), for the Engine's recipient code check right
            // before PM.swap.
            (plan.hookKind, plan.taxRecipient) = (xr.kind, xr.taxRecipient);
            plan.sizeFeePips = phi;
            // Effective s: capped by the entry's upper bound on a hooked pool (the entry may have been narrowed later).
            plan.slippageBps = cfg.slippageBps < xr.maxSlippageBps ? cfg.slippageBps : xr.maxSlippageBps;
        }

        if (cfg.mode == MODE_RECENTER) {
            // New range FROM THE ANCHOR, old width (spot is not read).
            (plan.newLower, plan.newUpper) =
                GoatRecenterMath.centredRange(e.anchor.tick, e.tickUpper - e.tickLower, e.key.tickSpacing);
            if (plan.newLower == e.tickLower && plan.newUpper == e.tickUpper) revert RangeUnchanged();
            plan.recenter = true;
            plan.feeBps = feeBps[0];
            // State is written BEFORE external calls. The config moves to the new id after the mint.
            cfg.lastRunAt = uint40(block.timestamp);
            cfg.budget -= 1;
            delete _configs[tokenId];
            delete configOwner[tokenId];

            GoatV4StewardEngine.Result memory res = ENGINE.carryOut(plan);

            // Structural closing check: owner code ran during the payouts; the new NFT must still be with the owner.
            if (IGoatPosmNft(address(POSM)).ownerOf(res.newTokenId) != e.owner) revert NftLeftMidFlight();
            // Config migration.
            _configs[res.newTokenId] = cfg;
            configOwner[res.newTokenId] = e.owner;
            _emitReranged(tokenId, e, plan, res, bySelf);
            if (res.swapIn > 0) emit SwapLeg(tokenId, xid, plan.sizeFeePips, res.totalFeePips, plan.feeSigned);
        } else {
            plan.feeBps = feeBps[1];
            // Single shot: the config is deleted BEFORE external calls.
            delete _configs[tokenId];
            delete configOwner[tokenId];

            GoatV4StewardEngine.Result memory res = ENGINE.carryOut(plan);
            _emitExited(tokenId, e, res, bySelf);
            if (res.swapIn > 0) emit SwapLeg(tokenId, xid, plan.sizeFeePips, res.totalFeePips, plan.feeSigned);
        }
    }

    function _emitReranged(
        uint256 tokenId,
        Eval memory e,
        GoatV4StewardEngine.Plan memory plan,
        GoatV4StewardEngine.Result memory res,
        bool bySelf
    ) internal {
        RerangeReport memory r;
        r.poolId = e.poolId;
        r.oldLower = e.tickLower;
        r.oldUpper = e.tickUpper;
        r.newLower = plan.newLower;
        r.newUpper = plan.newUpper;
        r.oldLiquidity = e.liquidity;
        r.newLiquidity = res.newLiquidity;
        r.anchorTick = e.anchor.tick;
        r.anchorSqrtPriceX96 = e.anchor.sqrtPriceX96;
        r.twapTick = e.twapTick;
        r.spotTickBefore = e.spotTick;
        r.sqrtPriceAtMint = res.sqrtPriceAtMint;
        r.principal0 = e.p0;
        r.principal1 = e.p1;
        r.lpFees0 = res.lpFees0;
        r.lpFees1 = res.lpFees1;
        r.protocolFee0 = res.protocolFee0;
        r.protocolFee1 = res.protocolFee1;
        r.zeroForOne = res.zeroForOne;
        r.swapIn = res.swapIn;
        r.swapOut = res.swapOut;
        r.swapFloor = res.swapFloor;
        r.minted0 = res.minted0;
        r.minted1 = res.minted1;
        r.refund0 = res.paid0;
        r.refund1 = res.paid1;
        r.valueUsd8 = e.valueUsd8;
        r.bySelf = bySelf;
        r.vetoApplied = e.vetoApplied;
        emit Reranged(tokenId, res.newTokenId, e.owner, r);
    }

    function _emitExited(uint256 tokenId, Eval memory e, GoatV4StewardEngine.Result memory res, bool bySelf)
        internal
    {
        ExitReport memory r;
        r.poolId = e.poolId;
        r.tickLower = e.tickLower;
        r.tickUpper = e.tickUpper;
        r.liquidity = e.liquidity;
        r.upperSide = e.upperSide;
        r.swapped = res.swapIn > 0;
        r.vetoApplied = e.vetoApplied;
        r.anchorTick = e.anchor.tick;
        r.anchorSqrtPriceX96 = e.anchor.sqrtPriceX96;
        r.twapTick = e.twapTick;
        r.spotTickBefore = e.spotTick;
        r.principal0 = e.p0;
        r.principal1 = e.p1;
        r.lpFees0 = res.lpFees0;
        r.lpFees1 = res.lpFees1;
        r.protocolFee0 = res.protocolFee0;
        r.protocolFee1 = res.protocolFee1;
        r.swapIn = res.swapIn;
        r.swapOut = res.swapOut;
        r.swapFloor = res.swapFloor;
        r.paid0 = res.paid0;
        r.paid1 = res.paid1;
        r.valueUsd8 = e.valueUsd8;
        r.bySelf = bySelf;
        emit PositionExited(tokenId, e.owner, r);
    }

    // ================================================================== VIEWS

    /// @notice Whether an operator run would pass right now; if not, the reason (error selector).
    function previewTrigger(uint256 tokenId) external view returns (bool ready, bool upperSide, bytes4 reason) {
        try this.evaluateRun(tokenId) returns (bool up) {
            return (true, up, bytes4(0));
        } catch (bytes memory err) {
            if (err.length >= 4) reason = bytes4(err);
            return (false, false, reason);
        }
    }

    /// @notice Read-only checks of a run (an operator run is assumed; buckets included). On failure it reverts with the
    ///         error the run would give. Changes no state.
    function evaluateRun(uint256 tokenId) external view returns (bool upperSide) {
        (Config memory cfg, address owner) = _runnable(tokenId);
        Eval memory e = _evaluate(tokenId, cfg, owner);
        (bool counted, uint256 kind) = _bucketOf(cfg, e);
        GoatRateBucket.Bucket memory b = _buckets[kind];
        if (counted && b.capacity != 0 && e.valueUsd8 > GoatRateBucket.current(b)) revert HourlyLimitHit();
        // Budget preview: the one-sided principal the run would count (two legs, in their own units) against the room in
        // the pair's buckets; the same value as `run`.
        if (counted && e.rule.budgeted) {
            (uint256 v, uint256 room) = REGISTRY.previewSwapBudget(
                Currency.unwrap(e.key.currency0), Currency.unwrap(e.key.currency1), e.p0, e.p1
            );
            if (v > room) revert SwapBudgetExceeded(v, room);
        }
        return e.upperSide;
    }
}
