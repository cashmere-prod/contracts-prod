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

    /// @dev T >= G + 1 (G per pair from the registry, from GATE_MIN 50 to GATE_MAX 140): every spot inside the gate is
    ///      then outside the old range on the same side (one-sided burn). Checked at config time only. A larger G bumps
    ///      the pair epoch (`GoatVersionRule`) and every swap flow reverts `PairChanged` in `_swapPre` until the owner
    ///      sets the config again (the same holds for the G + 1 bound of the EXIT swap side); a smaller G keeps the
    ///      epoch, and a saved T, already above the old G, stays above the new one.
    uint16 internal constant MAX_TRIGGER_TICKS = 20_000;
    uint32 internal constant MIN_INTERVAL_FLOOR = 3600;
    uint32 internal constant MAX_INTERVAL = 30 days;
    uint8 internal constant MAX_BUDGET = 20;
    /// @dev Auto-range budget value that means "no move limit": never counted down. Accepted budgets: 1 to MAX_BUDGET
    ///      (counted down by one per move) or NO_MOVE_LIMIT.
    uint8 internal constant NO_MOVE_LIMIT = 255;

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
        uint8 budget; // RECENTER: runs left (255 = no move limit, never counted down)
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
        uint8 budget; // 1 to 20, or 255 = no move limit
        bool standing; // must be true: the lineage continues through the ForAll approval
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
        uint128 take; // a piece of a swap flow: the liquidity to take (0 = the whole position)
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

    /// @notice `statusOf`: one read per position for the site and the keeper.
    struct Status {
        uint8 mode; // 0 no config, 1 RECENTER, 2 EXIT
        bool ready; // an operator run would pass now (`previewTrigger`)
        bytes4 reason; // the error a run would give now (0 when ready)
        uint40 nextRunAt; // RECENTER: lastRunAt + minInterval (the earliest next move); 0 otherwise
        uint8 movesLeft; // RECENTER: moves left (255 = no move limit); 0 otherwise
        bool permissionOk; // the Engine may act: the per-position approval, or STANDING plus the all-positions permission
        bool versionOk; // a swap config's pair version is the current one (always true for a withdraw-only EXIT)
        bool swapsOpen; // the position's pool is listed and its pair is open to swap flows
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
    /// @notice A RECENTER in pieces: the position the earlier pieces of a position's move went to (0 = none). Written by
    ///         a piece that leaves liquidity behind; deleted by the run that empties (burns) the position and by every
    ///         config write on it (`setRangeConfig`, `setExitConfig`, `clearConfig` and their batches).
    mapping(uint256 => uint256) public pieceDest;

    // ------------------------------------------------------------------ events

    event RangeConfigSet(uint256 indexed tokenId, address indexed owner, RangeParams p);
    event ExitConfigSet(uint256 indexed tokenId, address indexed owner, ExitParams p);
    event ConfigCleared(uint256 indexed tokenId, address indexed by);
    /// @dev Emitted after a RECENTER run that burns the old id and mints the new one: the burned and minted token ids,
    ///      the owner and the full report. Every other RECENTER run is a piece (`RerangePiece`).
    event Reranged(uint256 indexed burnedTokenId, uint256 indexed mintedTokenId, address indexed owner, RerangeReport r);
    /// @dev Emitted after an EXIT run that burns the position (a whole exit, or the piece that empties it).
    event PositionExited(uint256 indexed tokenId, address indexed owner, ExitReport r);
    /// @notice Emitted after every run with `swapIn > 0` (the report structs are unchanged). `execPoolId` = the pool the
    ///         swap ran on; `feePips` = the exec rule's φ (the floor term actually applied is
    ///         `min(feePips, lp_live + tax_live)`, further capped at the own pool's φ on a hookless or kind-3 own pool;
    ///         it can be recomputed from `totalFeePips` and the exec pool's pf); `totalFeePips` = the exec pool's live
    ///         total (pf ⊕ lp + tax) the Engine checked (the sizer uses only its input-side part); `feeSigned` = a keeper
    ///         signature applied (`runSwap`, any exec kind). Topic 0x0d5b7977….
    event SwapLeg(uint256 indexed tokenId, bytes32 indexed execPoolId, uint24 feePips, uint24 totalFeePips, bool feeSigned);
    /// @notice A RECENTER piece: the old id, the id it went to, the owner, the same report as `Reranged` (principal,
    ///         value and fees of the piece; `oldLiquidity` the old id's before it), the liquidity left in the old id (0 =
    ///         this piece burned it), whether it minted `newTokenId`, and whether it opened the move (the old id had no
    ///         link before it). `Reranged` keeps its meaning: one tx burned the old id and minted the new one.
    event RerangePiece(
        uint256 indexed tokenId,
        uint256 indexed newTokenId,
        address indexed owner,
        RerangeReport r,
        uint128 liquidityLeft,
        bool minted,
        bool opened
    );
    /// @notice A swap-exit piece that leaves liquidity in the position (the id is not burned; its config stays), with the
    ///         same report as `PositionExited` (`liquidity` the position's before it). The piece that empties the position
    ///         burns it and emits `PositionExited`, as a whole exit does.
    event ExitPiece(uint256 indexed tokenId, address indexed owner, ExitReport r, uint128 liquidityLeft);

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
    ///         Auto-range always keeps running after a move: `standing` must be set (`StandingRequired`) and the owner
    ///         must already have given the Engine the all-positions permission (`AllPositionsApprovalRequired`), since
    ///         every move mints a new position id. `budget`: 1 to 20 moves, or 255 = no move limit.
    function setRangeConfig(uint256 tokenId, RangeParams calldata p) external nonReentrant {
        _setRangeConfig(tokenId, p);
    }

    /// @notice Change during a move: the same rule written on every listed id with a config in one transaction, each
    ///         through every check of `setRangeConfig`; any such id that fails reverts the whole batch. An id with no
    ///         config (burned by the last piece, already cleared) is skipped, so a list read a moment earlier never fails
    ///         and a burned id is never written.
    function setRangeConfigs(uint256[] calldata tokenIds, RangeParams calldata p) external nonReentrant {
        for (uint256 i; i < tokenIds.length; ++i) {
            if (_configs[tokenIds[i]].mode != 0) _setRangeConfig(tokenIds[i], p);
        }
    }

    /// @notice Stop during a move: `clearConfig` on every listed id in one transaction. An id with no config (burned by
    ///         the last piece, already cleared) is skipped, so a list read a moment earlier never fails.
    function clearConfigs(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i; i < tokenIds.length; ++i) {
            if (_configs[tokenIds[i]].mode != 0) _clearConfig(tokenIds[i]);
        }
    }

    function _setRangeConfig(uint256 tokenId, RangeParams calldata p) internal {
        (address owner,,, PoolRule memory rule) = _configPreflight(tokenId, MODE_RECENTER, p.slippageBps, true);
        if (
            int24(uint24(p.triggerTicks)) <= rule.gate || p.triggerTicks > MAX_TRIGGER_TICKS
                || p.minInterval < MIN_INTERVAL_FLOOR || p.minInterval > MAX_INTERVAL || p.budget == 0
                || (p.budget > MAX_BUDGET && p.budget != NO_MOVE_LIMIT) || p.maxSwapFeePips == 0
                || p.maxSwapFeePips > MAX_USER_SWAP_FEE || p.maxSwapFeePips < rule.floorFeePips || rule.exitOnly
        ) revert BadConfig();
        if (!p.standing) revert StandingRequired();
        if (!IGoatPosmNft(address(POSM)).isApprovedForAll(owner, address(ENGINE))) revert AllPositionsApprovalRequired();

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
        delete pieceDest[tokenId]; // a config write ends the link
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
        delete pieceDest[tokenId]; // a config write ends the link
        emit ExitConfigSet(tokenId, owner, p);
    }

    /// @notice Deletes the config. The owner or the config's writer (the previous owner if the NFT changed hands) can
    ///         call it. Not affected by pause or retirement: turning automation off always works. `lastRunAt` is kept.
    function clearConfig(uint256 tokenId) external nonReentrant {
        _clearConfig(tokenId);
    }

    function _clearConfig(uint256 tokenId) internal {
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
        delete pieceDest[tokenId]; // a config write ends the link
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
        _perform(tokenId, cfg, owner, bySelf, Leg(true, signedZfo, signedOfz, execFee, execTickSpacing, execHooks, 0));
    }

    /// @notice `runSwap` for a piece of a swap flow: takes `liquidity` of the position (all of it at or above its
    ///         liquidity) through every check of a run, and charges every budget and the room with the piece. The
    ///         position keeps its config until it is empty. A RECENTER piece is added to the position the earlier
    ///         pieces went to while that one holds (`_destHolds`), else it mints a new one. A piece of a withdraw-only
    ///         EXIT is `BadConfig`; a RECENTER piece needs the all-positions permission (`NotApprovedForRun`).
    function runSwapPiece(
        uint256 tokenId,
        uint256 deadline,
        uint128 liquidity,
        uint24 execFee,
        int24 execTickSpacing,
        address execHooks,
        uint24 signedZfo,
        uint24 signedOfz
    ) external nonReentrant {
        if (liquidity == 0) revert EmptyPosition();
        (Config memory cfg, address owner, bool bySelf) = _preflight(tokenId, deadline);
        _perform(
            tokenId, cfg, owner, bySelf, Leg(true, signedZfo, signedOfz, execFee, execTickSpacing, execHooks, liquidity)
        );
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
     *      needs `tickHi` <= the level. On NC+POKE these are medLo / medHi of the registered pokes, which extra
     *      registered reads can only push outward (other callers' pokes cannot move them), so they can only delay a
     *      trigger. On other kinds `tickLo == tickHi == tick` (`anchorOf`) and the
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
        // A piece (swap flows only): its principal and value replace the position's, so the buckets, the pair budgets
        // and the depth room below are charged with the piece. A RECENTER piece may add to another id of the owner (the
        // link), so it needs the all-positions permission; an exit piece touches this id only and runs on the run's own
        // authorization (`_evaluate`: the one-position approval, or STANDING plus ForAll).
        uint128 take = leg.take == 0 || leg.take >= e.liquidity ? e.liquidity : leg.take;
        if (take != e.liquidity) {
            if (cfg.mode != MODE_RECENTER && !e.swapExit) revert BadConfig();
            if (cfg.mode == MODE_RECENTER && !IGoatPosmNft(address(POSM)).isApprovedForAll(owner, address(ENGINE))) {
                revert NotApprovedForRun();
            }
            (e.p0, e.p1) = GoatRecenterMath.oneSidedPrincipal(e.upperSide, e.tickLower, e.tickUpper, take);
            e.valueUsd8 = _usd8(e.p0, e.p1, e.anchor);
        }
        // The owner's own run is not counted in the bucket; an operator run is.
        (bool counted, uint256 kind) = _bucketOf(cfg, e);
        if (counted && !bySelf) {
            _buckets[kind].consume(e.valueUsd8);
            // On a budgeted pair the one-sided PRINCIPAL of an OPERATOR run (swap-less RECENTER included) is taken from
            // the pair's buckets BEFORE the Engine call (hard and X legs in their own units), and its USD value from the
            // depth room of a row with a v3 source. The owner's own run is not counted. Without room the whole run
            // reverts.
            if (e.rule.budgeted) {
                address c0 = Currency.unwrap(e.key.currency0);
                address c1 = Currency.unwrap(e.key.currency1);
                REGISTRY.consumeSwapBudget(c0, c1, e.p0, e.p1);
                REGISTRY.consumeDepthRoom(c0, c1, e.valueUsd8);
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
        if (take != e.liquidity) plan.take = take;
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
            // A piece goes to the link of the earlier pieces while it holds (`_destHolds`): the sizer and the add then
            // use the link's range. Else a new position centred on the anchor is minted. `opened`: no link before.
            bool opened = pieceDest[tokenId] == 0;
            if (!opened) {
                (bool holds, int24 dLo, int24 dHi) = _destHolds(pieceDest[tokenId], cfg, e);
                if (holds) (plan.dest, plan.newLower, plan.newUpper) = (pieceDest[tokenId], dLo, dHi);
            }
            // State is written BEFORE external calls. The config moves to the new id after the mint (a new id only;
            // `cfg` is a memory copy, so a piece leaves the old id's stored config as it is).
            cfg.lastRunAt = uint40(block.timestamp);
            if (cfg.budget != NO_MOVE_LIMIT) cfg.budget -= 1;
            if (plan.take == 0) {
                delete _configs[tokenId];
                delete configOwner[tokenId];
                delete pieceDest[tokenId];
            }

            GoatV4StewardEngine.Result memory res = ENGINE.carryOut(plan);

            // Structural closing check: owner code ran during the payouts; the new NFT must still be with the owner.
            if (IGoatPosmNft(address(POSM)).ownerOf(res.newTokenId) != e.owner) revert NftLeftMidFlight();
            // Config migration (a new id only; the link of the earlier pieces keeps its own, never rewritten).
            if (plan.dest == 0) {
                _configs[res.newTokenId] = cfg;
                configOwner[res.newTokenId] = e.owner;
            }
            if (plan.take != 0) pieceDest[tokenId] = res.newTokenId;
            // `Reranged` only for a run that burned the old id and minted the new one; every other run is a piece.
            RerangeReport memory r = _rerangeReport(e, plan, res, bySelf);
            if (plan.take == 0 && plan.dest == 0) {
                emit Reranged(tokenId, res.newTokenId, e.owner, r);
            } else {
                emit RerangePiece(tokenId, res.newTokenId, e.owner, r, e.liquidity - take, plan.dest == 0, opened);
            }
            if (res.swapIn > 0) emit SwapLeg(tokenId, xid, plan.sizeFeePips, res.totalFeePips, plan.feeSigned);
        } else {
            plan.feeBps = feeBps[1];
            // Single shot: the config is deleted BEFORE external calls (a piece keeps it on the rest).
            if (plan.take == 0) {
                delete _configs[tokenId];
                delete configOwner[tokenId];
            }

            GoatV4StewardEngine.Result memory res = ENGINE.carryOut(plan);
            // `PositionExited` only for the run that burned the position; a piece that leaves liquidity is `ExitPiece`.
            ExitReport memory r = _exitReport(e, res, bySelf);
            if (plan.take == 0) emit PositionExited(tokenId, e.owner, r);
            else emit ExitPiece(tokenId, e.owner, r, e.liquidity - take);
            if (res.swapIn > 0) emit SwapLeg(tokenId, xid, plan.sizeFeePips, res.totalFeePips, plan.feeSigned);
        }
    }

    /// @dev The link `d` may take this piece (it holds) when all of these are true: its config was written by the owner
    ///      with the very same rule as the old id (every `Config` field but `lastRunAt` and `budget`, which a move
    ///      sets), so a rule the owner rewrote on it never takes a piece; it is still the owner's (a burned id reads as
    ///      not); the Engine is allowed on all of the owner's positions (POSM's add needs it); no subscriber; the same
    ///      pool; the old position's width; and the gate band strictly inside it: lower + G < anchor.tickLo and
    ///      upper - G > anchor.tickHi. Strict, because the sizer needs its price limit (anchor -+ G) strictly inside the
    ///      range: at upper - G == anchor the limit reaches the top and no swap is sized, so the add would revert
    ///      `ZeroLiquidityMint`. Every centred range meets the strict band (width >= 2 * (G + ts)). Returns the link's
    ///      ticks.
    function _destHolds(uint256 d, Config memory cfg, Eval memory e)
        internal
        view
        returns (bool holds, int24 lo, int24 hi)
    {
        if (configOwner[d] != e.owner) return (false, 0, 0);
        Config memory dc = _configs[d];
        if (
            dc.mode != cfg.mode || dc.triggerTicks != cfg.triggerTicks || dc.slippageBps != cfg.slippageBps
                || dc.minInterval != cfg.minInterval || dc.flags != cfg.flags || dc.lowerTrigger != cfg.lowerTrigger
                || dc.upperTrigger != cfg.upperTrigger || dc.pairEpoch != cfg.pairEpoch
                || dc.maxSwapFeePips != cfg.maxSwapFeePips
        ) return (false, 0, 0);
        if (!IGoatPosmNft(address(POSM)).isApprovedForAll(e.owner, address(ENGINE))) return (false, 0, 0);
        try IGoatPosmNft(address(POSM)).ownerOf(d) returns (address o) {
            if (o != e.owner) return (false, 0, 0);
        } catch {
            return (false, 0, 0);
        }
        (PoolKey memory k, PositionInfo info) = POSM.getPoolAndPositionInfo(d);
        if (PoolId.unwrap(k.toId()) != e.poolId || info.hasSubscriber()) return (false, 0, 0);
        lo = info.tickLower();
        hi = info.tickUpper();
        if (hi - lo != e.tickUpper - e.tickLower) return (false, 0, 0);
        int256 g = e.rule.gate;
        holds = int256(lo) + g < int256(e.anchor.tickLo) && int256(hi) - g > int256(e.anchor.tickHi);
    }

    /// @dev The report of a RECENTER run or piece (`Reranged`, `RerangePiece`).
    function _rerangeReport(
        Eval memory e,
        GoatV4StewardEngine.Plan memory plan,
        GoatV4StewardEngine.Result memory res,
        bool bySelf
    ) internal pure returns (RerangeReport memory r) {
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
    }

    /// @dev The report of an EXIT run or piece (`PositionExited`, `ExitPiece`).
    function _exitReport(Eval memory e, GoatV4StewardEngine.Result memory res, bool bySelf)
        internal
        pure
        returns (ExitReport memory r)
    {
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
            address c0 = Currency.unwrap(e.key.currency0);
            address c1 = Currency.unwrap(e.key.currency1);
            (uint256 v, uint256 room) = REGISTRY.previewSwapBudget(c0, c1, e.p0, e.p1);
            if (v > room) revert SwapBudgetExceeded(v, room);
            uint256 room8 = REGISTRY.previewDepthRoom(c0, c1);
            if (e.valueUsd8 > room8) revert DepthRoomExceeded(e.valueUsd8, room8);
        }
        return e.upperSide;
    }

    /// @notice The position's automation status in one read (changes no state): mode, whether an operator run would pass
    ///         now and, if not, its error selector (as `previewTrigger`), the next move time and the moves left of a
    ///         RECENTER config, whether the Engine may act on the position, whether a swap config's pair version is
    ///         current, and whether the pair is open to swap flows on the position's pool.
    function statusOf(uint256 tokenId) external view returns (Status memory s) {
        Config memory cfg = _configs[tokenId];
        s.mode = cfg.mode;
        (s.ready,, s.reason) = this.previewTrigger(tokenId);
        if (cfg.mode == 0) return s;
        if (cfg.mode == MODE_RECENTER) {
            s.nextRunAt = uint40(uint256(cfg.lastRunAt) + cfg.minInterval);
            s.movesLeft = cfg.budget;
        }
        IGoatPosmNft nft = IGoatPosmNft(address(POSM));
        try nft.getApproved(tokenId) returns (address a) {
            s.permissionOk = a == address(ENGINE)
                || (cfg.flags & STANDING != 0 && nft.isApprovedForAll(configOwner[tokenId], address(ENGINE)));
        } catch {}
        bool swapCfg = cfg.mode == MODE_RECENTER || cfg.flags & (SWAP_ON_LOWER | SWAP_ON_UPPER) != 0;
        s.versionOk = !swapCfg;
        try POSM.getPoolAndPositionInfo(tokenId) returns (PoolKey memory key, PositionInfo) {
            try REGISTRY.poolInfo(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), PoolId.unwrap(key.toId()))
            returns (int24, uint32 ep, bool open, bool) {
                s.swapsOpen = open;
                if (swapCfg) s.versionOk = ep == cfg.pairEpoch;
            } catch {}
        } catch {}
    }
}
