// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Same ABI layout as v4-core `PoolKey` (Currency and IHooks are addresses). Only `hooks` is read.
struct PoolKeyAuto {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev The part of the v4 PositionManager this contract uses. A minimal interface instead of the full ABI, so
/// that no other capability can be called by mistake.
interface IPosmAuto {
    function ownerOf(uint256 tokenId) external view returns (address);
    /// @notice The position's pool key (used for the reviewed-hook check).
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKeyAuto memory, uint256);
    function getApproved(uint256 tokenId) external view returns (address);
    /// @notice ERC721Permit_v4 EIP-712 domain separator (used to check a permit that was already submitted).
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    /// @notice UnorderedNonce bitmap: a nonce is used when `nonces(owner, nonce >> 8) & (1 << uint8(nonce)) != 0`.
    function nonces(address owner, uint256 word) external view returns (uint256);
    /// @notice The position's packed info word; bit 0 is hasSubscriber (PositionInfoLibrary).
    function positionInfo(uint256 tokenId) external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable;
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external;
}

/**
 * @notice GoatAutoCompoundV4: keeper-triggered auto-compound for Uniswap v4 positions, without custody.
 *
 * @dev This contract holds no funds and makes no economic choice: no fee rate, swap route or amount. It answers
 * three questions: (1) is the caller an approved operator, (2) has the position owner turned this automation on,
 * on chain, and is it still the same owner, (3) has the minimum interval passed. If so, it sends the position to
 * the immutable `compoundor`. All compound and fee math lives in `GoatV4Compoundor`; there is no fee code here.
 *
 * @dev The owner's permit names `spender = address(this)`, that is, this contract's code, and the only thing that
 * code can do with the position is send it to `compoundor`. A keeper cannot point the permit anywhere else. An
 * operator can at worst run an allowed compound early or, through `executeWithReference` on a pair without an
 * on-chain anchor, pass a poor reference price; the loss is then limited to the fees collected in that compound,
 * and the owner's slippage setting does not limit it.
 *
 * @dev No `receive()`, `fallback` or `onERC721Received`, on purpose: the contract cannot hold ETH or keep an NFT
 * (`safeTransferFrom` to it reverts), so nothing can build up here and no emergency withdrawal is needed.
 *
 * @dev Subscribers: `PositionManager.transferFrom` unsubscribes a position that has a subscriber, so sending it
 * to the compoundor would silently cut that link. Positions with a subscriber are therefore rejected, both when
 * automation is turned on (`configToken`) and on every run. A subscriber's `notifyModifyLiquidity` never runs
 * during a compound, since the transfer happens before the collect.
 *
 * @dev MIT licensed. Revert Finance's `Automator.sol` and `AutoCollect.sol` (BUSL-1.1) were not copied; the
 * structure follows `GoatAutoCompoundV3`.
 */
contract GoatAutoCompoundV4 is Ownable2Step, ReentrancyGuard {
    // ------------------------------------------------------------- immutable

    /// @notice v4 PositionManager (ERC721 + ERC721Permit_v4)
    IPosmAuto public immutable positionManager;

    /// @notice The compound contract (`GoatV4Compoundor`); the only address a position can be sent to.
    address public immutable compoundor;

    // ------------------------------------------------------------- constants

    /// @notice Same as the upper bound in `GoatV4Compoundor._minOut`; a looser tolerance would make the floor
    /// meaningless.
    uint16 public constant MAX_SLIPPAGE_BPS = 2000;
    /// @notice Shortest `minInterval` an owner can set: at most one compound per position per hour.
    uint32 public constant MIN_INTERVAL = 3600;
    /// @notice Equal to ERC721Permit_v4's `PERMIT_TYPEHASH` (ERC721PermitHash.sol).
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");

    // ------------------------------------------------------------- state

    mapping(address => bool) public operators;
    bool public paused;

    /// @notice Adding an operator waits TIMELOCK and must then be applied within QUEUE_GRACE; removing one
    ///         is instant.
    uint256 public constant TIMELOCK = 24 hours;
    uint256 public constant QUEUE_GRACE = 7 days;
    /// @notice Queue timestamps. Operator entries are keyed by keccak256(abi.encode(operator, owner at queue time))
    ///         and reviewed-hook entries by keccak256(abi.encode(hook, codehash, owner at queue time)); the
    ///         preimages differ in length (64 and 96 bytes), so the keys cannot collide. An entry is bound to the
    ///         owner that queued it: a new owner cannot apply it, and it counts again only if that address becomes
    ///         owner again within the grace window.
    mapping(bytes32 => uint256) public queuedAt;

    /// @notice Guardian that can only stop things: `setPaused(true)` and `setOperator(op, false)`. It cannot
    ///         unpause, add operators or change anything else. 0 = none. The owner sets it instantly.
    address public guardian;

    /**
     * @notice Reviewed hooks: hook address => pinned code hash; 0 means not listed.
     * @dev A pool without a hook always passes. A pool with a hook passes only if the hook is listed and its live
     * code hash equals the pin (`_requireReviewedHook`, checked in `configToken` and on every run). The list starts
     * empty, so only hookless pools work until a hook is added. The owner (a multisig) manages it with
     * `setReviewedHook`. Removal is instant; adding or re-pinning waits 24 hours: `queueReviewedHook(hook, codehash)`,
     * then `setReviewedHook(hook, codehash)` within [eta, eta + QUEUE_GRACE]. The wait matters because listing a hook
     * lets positions in its pools that already turned automation on run again, so owners have time to react.
     * The pin catches a change of code (a CREATE2 redeploy or a changed 7702 delegation) but not a proxy's
     * implementation change, so hooks that are proxies or use DELEGATECALL are not listed. A listed hook does not
     * change the economic bound: a run can lose at most the fees it collects.
     */
    mapping(address => bytes32) public reviewedHookCodehash;
    /// @notice Hook permission bits that keep a hook off the list (the same mask as `GoatV4PairRegistry`):
    /// AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA (1<<0), AFTER_ADD_LIQUIDITY_RETURNS_DELTA (1<<1),
    /// AFTER_REMOVE_LIQUIDITY (1<<8), BEFORE_REMOVE_LIQUIDITY (1<<9). A compound always fails on a hook that returns
    /// liquidity deltas, and remove-liquidity callbacks add nothing to a compound.
    uint160 public constant HOOK_FORBIDDEN_BITS = 0x0303;

    struct Config {
        bool enabled;
        /// @notice true: claim mode (the fees go to the owner, principal untouched); false: compound.
        bool claimOnly;
        /**
         * @notice true: no signature is needed and the owner's standing approval is used.
         * @dev An explicit opt-in by the owner. In v4 an approval on a position is full authority over it,
         * withdrawing principal included, so a standing approval is not the default.
         */
        bool allowStandingApproval;
        uint16 maxSlippageBps;
        uint32 minInterval;
        /**
         * @notice Not taken from user input; only `execute` writes it.
         * @dev uint40 rather than uint32: a uint32 timestamp wraps in 2106, which would switch off the interval
         * check. uint40 lasts for tens of thousands of years.
         */
        uint40 lastRunAt;
        /**
         * @notice Smallest liquidity increase a compound must add; 0 = no minimum.
         * @dev The v3 version uses minimum fee amounts, but this contract never sees the fee amounts (the
         * compoundor does), so the minimum is a liquidity increase, read with `getPositionLiquidity` before and
         * after. Not used in claim mode, where liquidity does not change.
         */
        uint128 minLiquidityDelta;
    }

    mapping(uint256 => Config) public configs;
    /// @notice The owner at opt-in time; automation stops by itself when `ownerOf` differs.
    mapping(uint256 => address) public configOwner;

    // ------------------------------------------------------------- events

    event PositionConfigured(uint256 indexed tokenId, address indexed owner, Config cfg);
    /// @param usedPermit true when the owner's permit signature authorized this run: the `permit` call in this
    /// transaction succeeded, or the same permit had already been submitted and `_bankedPermitValid` accepted it.
    /// Always true in signature mode; false for a standing-approval run whose permit call was missing or failed.
    event AutoCompoundTriggered(
        uint256 indexed tokenId, address indexed owner, address indexed operator, bool claimOnly, bool usedPermit
    );
    event OperatorSet(address indexed operator, bool active);
    event PausedSet(bool paused);
    /// @notice An operator addition was queued; `setOperator(operator, true)` is possible in [eta, eta + QUEUE_GRACE].
    event OperatorQueued(address indexed operator, uint256 eta);
    /// @notice The guardian changed (0 = none).
    event GuardianSet(address indexed guardian);
    /// @notice The reviewed hook list changed (`codehash == 0` means removed).
    event ReviewedHookSet(address indexed hook, bytes32 codehash);
    /// @notice A hook addition or re-pin was queued; `setReviewedHook(hook, codehash)` is possible in
    /// [eta, eta + QUEUE_GRACE].
    event ReviewedHookQueued(address indexed hook, bytes32 codehash, uint256 eta);

    // ------------------------------------------------------------- errors

    error NotOperator();
    error Paused();
    error Expired();
    error NotConfigured();
    error OwnerChanged();
    error TooSoon();
    error NoLiquidity();
    error RenounceDisabled();
    error SlippageTooHigh();
    error IntervalTooShort();
    error NotPositionOwner();
    error ZeroAddress();
    error PermitRequired();
    error NftNotReturned();
    error ApprovalNotCleared();
    error RewardTooSmall();
    error HasSubscriber();
    error LiquidityChanged();
    /// @notice The position is approved to another address (for example the v4 automation engine); a run would
    /// silently clear that approval.
    error ForeignApproval();
    /// @notice `maxSlippageBps = 0` is rejected in compound mode; the compoundor does not accept a zero tolerance
    /// either.
    error SlippageZero();
    /// @notice No queued addition for (operator, current owner).
    error NotQueued();
    /// @notice The 24-hour delay has not passed.
    error TimelockNotReady();
    /// @notice The 7-day window for applying after the delay has passed.
    error TimelockExpired();
    /// @notice Queueing or adding while an ownership handover is pending.
    error HandoverPending();
    /// @notice The caller is neither the owner nor, for a stop action, the guardian.
    error NotOwnerOrGuardian();
    /// @notice The position's pool hook is not on the reviewed list, or its live code differs from the pin.
    error HookNotReviewed(address hook);
    /// @notice The hook cannot be listed: it has no code, is a 7702 delegation, its pin is not its live code hash,
    /// or it has a forbidden bit.
    error HookNotListable(address hook);

    /// @dev No zero check for `_owner`: `Ownable(_owner)` already reverts with `OwnableInvalidOwner` before the body
    /// runs.
    constructor(IPosmAuto _positionManager, address _compoundor, address _owner) Ownable(_owner) {
        if (address(_positionManager) == address(0) || _compoundor == address(0)) revert ZeroAddress();
        positionManager = _positionManager;
        compoundor = _compoundor;
    }

    // ------------------------------------------------------------- administration

    function _operatorId(address op) internal view returns (bytes32) {
        return keccak256(abi.encode(op, owner()));
    }

    /// @notice Queues an operator addition (owner only; not while an ownership handover is pending).
    function queueOperator(address op) external onlyOwner nonReentrant {
        if (op == address(0)) revert ZeroAddress();
        if (pendingOwner() != address(0)) revert HandoverPending();
        queuedAt[_operatorId(op)] = block.timestamp;
        emit OperatorQueued(op, block.timestamp + TIMELOCK);
    }

    /// @notice Sets or clears the guardian (owner, instant: the role can only stop things).
    function setGuardian(address g) external onlyOwner nonReentrant {
        guardian = g;
        emit GuardianSet(g);
    }

    /// @notice `active = true` applies a matured queue entry of the current owner (24 hours passed, within the
    ///         7-day grace); `active = false` is instant and also cancels the current owner's queued addition.
    ///         The guardian may only remove (`active = false`).
    function setOperator(address op, bool active) external nonReentrant {
        if (msg.sender != owner() && (active || msg.sender != guardian)) revert NotOwnerOrGuardian();
        if (op == address(0)) revert ZeroAddress();
        bytes32 id = _operatorId(op);
        if (active) {
            if (pendingOwner() != address(0)) revert HandoverPending();
            uint256 t = queuedAt[id];
            if (t == 0) revert NotQueued();
            if (block.timestamp < t + TIMELOCK) revert TimelockNotReady();
            if (block.timestamp > t + TIMELOCK + QUEUE_GRACE) revert TimelockExpired();
        }
        delete queuedAt[id];
        operators[op] = active;
        emit OperatorSet(op, active);
    }

    /// @notice The guardian may only pause (`p = true`); only the owner unpauses.
    function setPaused(bool p) external nonReentrant {
        if (msg.sender != owner() && (!p || msg.sender != guardian)) revert NotOwnerOrGuardian();
        paused = p;
        emit PausedSet(p);
    }

    function _hookId(address hook, bytes32 codehash) internal view returns (bytes32) {
        return keccak256(abi.encode(hook, codehash, owner()));
    }

    /**
     * @notice Queues adding a hook to the reviewed list, or re-pinning it (owner; not while an ownership handover
     * is pending). Apply with `setReviewedHook(hook, codehash)` within [eta, eta + QUEUE_GRACE].
     * @dev The entry is bound to (hook, codehash, queuing owner): another code hash or a new owner cannot use it.
     * The listing rules are checked here, so only a listable entry is announced, and again when it is applied.
     * Removal needs no queue. There is no cancel: an entry that is not applied lapses after the grace period.
     */
    function queueReviewedHook(address hook, bytes32 codehash) external onlyOwner nonReentrant {
        _requireListable(hook, codehash);
        if (pendingOwner() != address(0)) revert HandoverPending();
        queuedAt[_hookId(hook, codehash)] = block.timestamp;
        emit ReviewedHookQueued(hook, codehash, block.timestamp + TIMELOCK);
    }

    /**
     * @notice Adds a hook to the reviewed list (`codehash` = the hook's live code hash) or removes it (`codehash = 0`).
     * @dev Listing rules, the same as in `GoatV4PairRegistry`: the hook has code, is not a 7702 delegation
     * designator (0xef0100 followed by an address, 23 bytes), `codehash` equals its live `EXTCODEHASH`, and the
     * address has none of `HOOK_FORBIDDEN_BITS`. The bits are part of the address, so checking them here is
     * enough. Removal is always allowed, also during an ownership handover.
     * @dev Adding or re-pinning needs a matured queue entry of the current owner (`queueReviewedHook`, 24 hours
     * passed, within the 7-day grace) and no pending handover; the entry is used up. Order of checks: rules,
     * handover, queue.
     */
    function setReviewedHook(address hook, bytes32 codehash) external onlyOwner nonReentrant {
        if (hook == address(0)) revert ZeroAddress();
        if (codehash != bytes32(0)) {
            _requireListable(hook, codehash);
            if (pendingOwner() != address(0)) revert HandoverPending();
            bytes32 id = _hookId(hook, codehash);
            uint256 t = queuedAt[id];
            if (t == 0) revert NotQueued();
            if (block.timestamp < t + TIMELOCK) revert TimelockNotReady();
            if (block.timestamp > t + TIMELOCK + QUEUE_GRACE) revert TimelockExpired();
            delete queuedAt[id];
        }
        reviewedHookCodehash[hook] = codehash;
        emit ReviewedHookSet(hook, codehash);
    }

    /// @dev Listing rules shared by queueing and adding. A zero `codehash` never equals the live hash of an address
    /// with code, and an address without code has `n == 0`; both give `HookNotListable` (removal is not queued).
    function _requireListable(address hook, bytes32 codehash) internal view {
        if (hook == address(0)) revert ZeroAddress();
        uint256 n = hook.code.length;
        if (n == 0 || hook.codehash != codehash || uint160(hook) & HOOK_FORBIDDEN_BITS != 0) revert HookNotListable(hook);
        if (n == 23 && bytes3(hook.code) == bytes3(0xef0100)) revert HookNotListable(hook);
    }

    // ------------------------------------------------------------- opt-in

    /**
     * @notice On-chain opt-in per position. Only the position owner can call it.
     * @dev Unlike Revert Finance's `Automator.sol`, where an owner-controlled operator list is enough, every
     * position needs its owner's own on-chain opt-in.
     * @dev The config survives a transfer; automation only pauses while `ownerOf != configOwner`. If the NFT comes
     * back to the same address, the next run uses that owner's earlier mode and slippage (in standing-approval
     * mode a remaining `setApprovalForAll` is enough). To prevent that, call `configToken` with `enabled = false`
     * or revoke the approval first.
     * @dev Owners with code, 7702 accounts included, are checked by `PositionManager.permit` through ERC-1271.
     * If the account rejects the raw EIP-712 digest, signature mode cannot work and every run fails with
     * `PermitRequired`. This function cannot detect that, so the app should try `PositionManager.permit` with
     * eth_call first and offer standing-approval mode instead.
     */
    function configToken(uint256 tokenId, Config calldata cfg) external {
        if (positionManager.ownerOf(tokenId) != msg.sender) revert NotPositionOwner();

        /**
         * Subscriber check, here as well as in `execute`. A revert in `execute` only fails the keeper's
         * transaction, which the owner never sees; `configToken` is the owner's own transaction, so the owner
         * learns here that `PositionManager.unsubscribe(tokenId)` has to come first. `execute` checks again because a
         * subscriber can be added later. It is a bare revert, so the app should read `positionInfo(tokenId) & 1`
         * beforehand and show a warning.
         */
        if (cfg.enabled && positionManager.positionInfo(tokenId) & 1 == 1) revert HasSubscriber();
        if (cfg.maxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        // The compoundor rejects a zero tolerance in compound mode; reject it here, where the owner sees it.
        if (cfg.enabled && !cfg.claimOnly && cfg.maxSlippageBps == 0) revert SlippageZero();
        if (cfg.enabled && cfg.minInterval < MIN_INTERVAL) revert IntervalTooShort();
        // Another contract's approval on this position (for example the v4 automation engine) would be cleared
        // by every run; the owner sees the error here, in their own wallet. Runs check it too.
        if (cfg.enabled) _requireNoForeignApproval(tokenId);
        // Automation cannot be turned on in a pool with an unreviewed hook; runs check it too.
        if (cfg.enabled) _requireReviewedHook(tokenId);

        Config memory c = cfg;
        c.lastRunAt = configs[tokenId].lastRunAt; // the owner cannot reset it
        configs[tokenId] = c;
        configOwner[tokenId] = msg.sender;

        emit PositionConfigured(tokenId, msg.sender, c);
    }

    // ------------------------------------------------------------- automation

    /**
     * @notice Operator input. `execute` takes no economic parameter; `executeWithReference` adds a reference
     * price (see that function).
     * @param tokenId The position.
     * @param deadline Latest timestamp for the keeper's transaction.
     * @param permitDeadline Deadline the owner signed (part of the permit).
     * @param nonce Single-use nonce from the owner's permit.
     * @param signature The owner's `permit` signature; may be empty with `allowStandingApproval`.
     */
    struct ExecuteParams {
        uint256 tokenId;
        uint256 deadline;
        uint256 permitDeadline;
        uint256 nonce;
        bytes signature;
    }

    function execute(ExecuteParams calldata p) external nonReentrant {
        _execute(p, 0);
    }

    /**
     * @notice `execute` with a reference price that the keeper computes outside the transaction. The compoundor
     * uses it only when there is no on-chain anchor, for the price gate (spot must sit inside the band for the
     * pool's fee tier) and the swap floor.
     * @dev The reference is the one economic input an operator gives. It applies only to pairs without an on-chain
     * anchor and never withdraws principal; a poor reference can lose at most the fees collected in that compound.
     * The owner's `maxSlippageBps` is measured from the reference, so it gives no protection against a poor one.
     * Without a reference (`execute`), a pair without an anchor compounds with no swap.
     * @param refSqrtPriceX96 sqrtPriceX96 in the pool's own direction (token1/token0); 0 = no reference.
     */
    function executeWithReference(ExecuteParams calldata p, uint160 refSqrtPriceX96) external nonReentrant {
        _execute(p, refSqrtPriceX96);
    }

    function _execute(ExecuteParams calldata p, uint160 refSqrtPriceX96) internal {
        if (!operators[msg.sender]) revert NotOperator();
        if (paused) revert Paused();
        if (block.timestamp > p.deadline) revert Expired();

        Config memory cfg = configs[p.tokenId];
        if (!cfg.enabled) revert NotConfigured();

        // The payout address is fixed before any external call.
        address owner = positionManager.ownerOf(p.tokenId);
        if (owner != configOwner[p.tokenId]) revert OwnerChanged();
        if (owner == address(this) || owner == compoundor) revert OwnerChanged();
        uint128 liqBefore = positionManager.getPositionLiquidity(p.tokenId);
        if (liqBefore == 0) revert NoLiquidity();

        /**
         * Reject a position that has a subscriber. The NFT goes to the compoundor and back in this transaction,
         * and `PositionManager.transferFrom` unsubscribes a position on transfer, so a run would silently cut the
         * owner's link to a staking, reward or accounting integration. The owner has to unsubscribe first, knowing
         * what that does.
         */
        if (positionManager.positionInfo(p.tokenId) & 1 == 1) revert HasSubscriber();
        // A pool with a hook needs a listed hook whose live code matches the pin. Checked on every run, because the
        // list can shrink and code can change.
        _requireReviewedHook(p.tokenId);

        // The interval is recorded before any external call (reentrancy, and at most one run per interval).
        if (block.timestamp < uint256(cfg.lastRunAt) + cfg.minInterval) revert TooSoon();
        configs[p.tokenId].lastRunAt = uint40(block.timestamp);

        // Authority: the owner's single-use signature, or a standing approval the owner explicitly opted into.
        /**
         * Authority: two modes with separate rules.
         *
         *  - Signature mode (`allowStandingApproval = false`): the run needs the owner's permit for this tokenId,
         *    and the per-token approval must be in place at transfer time; `isApprovedForAll` does not count. The
         *    permit is tried first. If it reverts because the same permit was already submitted, the run goes
         *    ahead only when `_bankedPermitValid` accepts it (deadline not passed, signed by the owner, nonce
         *    used). Without a signature there is no run in this mode (`PermitRequired`).
         *  - Standing-approval mode: the owner's explicit opt-in. Any existing approval counts, and a signature,
         *    if given, is tried as well. `transferFrom` clears `getApproved[id]` on every run, so with a
         *    per-token `approve` alone this mode runs a single time.
         *
         * In signature mode an approval on its own is not consent, because `getApproved[id] == this` does not show
         * where it came from. An owner who wants to run on a plain one-time `approve` (for example an account that
         * cannot sign permits) chooses standing-approval mode.
         *
         * Revoking the nonce alone does not cancel a signature. To cancel one, sent or not, call
         * `revokeNonce(nonce)` and also clear the approval (`PositionManager.approve(address(0), tokenId)`) or turn
         * the automation off (`configToken` with `enabled = false`); the app's stop flow does all of these. Keep
         * permit deadlines short.
         */
        // permit and transfer overwrite or clear `getApproved`; do not silently remove another contract's approval.
        _requireNoForeignApproval(p.tokenId);
        bool usedPermit;
        if (p.signature.length > 0) {
            try positionManager.permit(address(this), p.tokenId, p.permitDeadline, p.nonce, p.signature) {
                usedPermit = true;
            } catch {
                // the same permit may already have been submitted; in signature mode `_bankedPermitValid` decides
            }
        }
        if (!cfg.allowStandingApproval) {
            if (!usedPermit) {
                if (!_bankedPermitValid(p, owner)) revert PermitRequired();
                usedPermit = true; // the owner's already submitted permit authorized this run
            }
            if (positionManager.getApproved(p.tokenId) != address(this)) revert PermitRequired();
        }

        /**
         * Send the position to the compoundor. With `from = owner`, the compoundor returns the NFT and the
         * proceeds to the owner, not to this contract.
         *
         * `data = (claimOnly, slippageBps)` comes from the owner's config, not from the keeper; the optional
         * third field `refSqrtPriceX96` comes from the keeper (see `executeWithReference`).
         */
        bytes memory data = refSqrtPriceX96 == 0
            ? abi.encode(cfg.claimOnly, uint256(cfg.maxSlippageBps))
            : abi.encode(cfg.claimOnly, uint256(cfg.maxSlippageBps), refSqrtPriceX96);
        positionManager.safeTransferFrom(owner, compoundor, p.tokenId, data);

        /**
         * Closing checks, measured rather than assumed:
         *  - the NFT is back with the owner;
         *  - the approval is cleared (solmate `transferFrom` deletes `getApproved[id]`, which makes the permit
         *    single use). A remaining approval would be a standing authority, so revert.
         */
        if (positionManager.ownerOf(p.tokenId) != owner) revert NftNotReturned();
        if (positionManager.getApproved(p.tokenId) == address(this)) revert ApprovalNotCleared();

        /**
         * Minimum increase. The compoundor already reverts with `NothingToCompound` when nothing has accrued;
         * `minLiquidityDelta` is an extra floor the owner may choose, so that a dust-sized increase does not use
         * up the interval.
         */
        /**
         * Liquidity check on every run, independent of the compoundor's own check: claim mode must leave
         * liquidity unchanged and compound mode must not lower it.
         */
        uint128 liqAfter = positionManager.getPositionLiquidity(p.tokenId);
        if (cfg.claimOnly) {
            if (liqAfter != liqBefore) revert LiquidityChanged();
        } else {
            if (liqAfter < liqBefore) revert LiquidityChanged();
            if (cfg.minLiquidityDelta > 0 && liqAfter - liqBefore < cfg.minLiquidityDelta) revert RewardTooSmall();
        }

        emit AutoCompoundTriggered(p.tokenId, owner, msg.sender, cfg.claimOnly, usedPermit);
    }

    // ------------------------------------------------------------- internal

    /// @dev `getApproved` must be empty or this contract. A per-position approval held by another contract (for
    /// example the v4 automation engine) would be overwritten by the permit and cleared by the transfer, which
    /// would switch that automation off without notice. Owners who use both should give the engine an approval
    /// for all positions (`setApprovalForAll`), or revoke any unused permit nonce for this contract when they
    /// approve the engine for one position.
    function _requireNoForeignApproval(uint256 tokenId) internal view {
        address prev = positionManager.getApproved(tokenId);
        if (prev != address(0) && prev != address(this)) revert ForeignApproval();
    }

    /// @dev A pool without a hook passes; with a hook, the pin must be set and the live `EXTCODEHASH` must equal it.
    function _requireReviewedHook(uint256 tokenId) internal view {
        (PoolKeyAuto memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        address h = key.hooks;
        if (h == address(0)) return;
        bytes32 pin = reviewedHookCodehash[h];
        if (pin == bytes32(0) || h.codehash != pin) revert HookNotReviewed(h);
    }

    /**
     * @dev Used when this transaction's `permit` call reverted: accepts the existing approval as coming from the
     * same permit, already submitted, when
     *  (1) `block.timestamp <= permitDeadline`, the deadline the owner signed;
     *  (2) the nonce is marked used in the owner's UnorderedNonce bitmap. The bit is also set by `revokeNonce`
     *      and by other permits with the same nonce, so cancelling a signature takes `revokeNonce` plus clearing
     *      the approval (`approve(address(0), tokenId)`) or `configToken` with `enabled = false`;
     *  (3) the signature is the owner's over the digest the PositionManager checks (`DOMAIN_SEPARATOR`, spender =
     *      this contract, tokenId, nonce, deadline), by the same rule as permit2's `SignatureVerification`.
     */
    function _bankedPermitValid(ExecuteParams calldata p, address owner) internal view returns (bool) {
        if (p.signature.length == 0 || block.timestamp > p.permitDeadline) return false;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                positionManager.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, address(this), p.tokenId, p.nonce, p.permitDeadline))
            )
        );
        if (!_isValidSig(owner, digest, p.signature)) return false;
        return positionManager.nonces(owner, p.nonce >> 8) & (uint256(1) << uint8(p.nonce)) != 0;
    }

    /// @dev Same rule as permit2's `SignatureVerification.verify` (used by `PositionManager.permit`), returning a
    /// bool instead of reverting: a signer without code uses ecrecover (65-byte r, s, v or 64-byte EIP-2098); a
    /// signer with code (a contract or a 7702 account) must return the ERC-1271 `isValidSignature` magic value.
    function _isValidSig(address signer, bytes32 digest, bytes calldata sig) internal view returns (bool) {
        if (signer.code.length == 0) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            if (sig.length == 65) {
                r = bytes32(sig[0:32]);
                s = bytes32(sig[32:64]);
                v = uint8(sig[64]);
            } else if (sig.length == 64) {
                r = bytes32(sig[0:32]);
                bytes32 vs = bytes32(sig[32:64]);
                s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
                v = uint8(uint256(vs >> 255)) + 27;
            } else {
                return false;
            }
            address rec = ecrecover(digest, v, r, s);
            return rec != address(0) && rec == signer;
        }
        (bool ok, bytes memory ret) = signer.staticcall(abi.encodeWithSelector(bytes4(0x1626ba7e), digest, sig));
        return ok && ret.length >= 32 && abi.decode(ret, (bytes32)) == bytes32(bytes4(0x1626ba7e));
    }

    /**
     * @notice Disabled: without an owner, operators, the guardian, pausing and the hook list could no longer be
     * managed, and an accidental call cannot be undone. Ownership moves with `transferOwnership` and
     * `acceptOwnership`.
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
