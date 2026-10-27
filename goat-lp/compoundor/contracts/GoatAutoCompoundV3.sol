// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import "./external/openzeppelin/access/Ownable.sol";
import "./external/openzeppelin/token/ERC20/SafeERC20.sol";
import "./external/openzeppelin/math/SafeMath.sol";
import "./external/openzeppelin/utils/ReentrancyGuard.sol";

// License: the Uniswap v3 libraries and interfaces are GPL-2.0-or-later, and a contract importing them
// becomes a derivative work. The MIT equivalents in ./external/mit are used instead. They are imported
// under the upstream names so the contract body stays unchanged. Their output matches the Uniswap
// originals bit for bit, including overflow behavior.
import {
    IUniV3Factory as IUniswapV3Factory,
    IUniV3Pool as IUniswapV3Pool,
    INpmMinimal as INonfungiblePositionManager,
    IV3RouterMinimal as IV3SwapRouter
} from "./external/mit/IUniV3Minimal.sol";
import {TickMathMIT as TickMath} from "./external/mit/TickMathMIT.sol";
import {LiquidityAmountsMIT as LiquidityAmounts} from "./external/mit/LiquidityAmountsMIT.sol";
import "./external/mit/FullMath.sol"; // MIT (from Uniswap v3-core)


/**
 * @notice Keeper-run automatic compounding for Uniswap v3 positions. The owner approves this contract
 *         for one position (`approve(this contract, tokenId)`) and opts in explicitly with `configToken`;
 *         a keeper then calls `execute()`.
 *
 * @dev Least privilege: `setApprovalForAll` is not needed. `NPM.increaseLiquidity` requires no approval
 *      at all (any address can add liquidity to any position), while `NPM.collect` does, and a
 *      per-position `approve` is enough for it.
 *
 *      A per-position `approve` still gives full control over that position, principal included
 *      (an approved address can call `decreaseLiquidity` and then `collect`):
 *        `approve(tokenId)`      -> full control of that position (principal included).
 *        `setApprovalForAll`     -> full control of all positions (principal included).
 *      So the narrowing is in scope (one position instead of all), not in power. A per-position
 *      approval limits the exposure to a single position and does not extend to the owner's others.
 *
 *      Approval slot: the position manager keeps one `getApproved` slot per position. `approve(this
 *      contract, id)` overwrites an earlier `approve(AutoExit/AutoRange, id)` on the same position: that
 *      stop-loss or re-range rule still looks active but cannot run ("Not approved"). The reverse also
 *      holds: a later per-position approval for AutoExit/AutoRange silently stops compounding. This
 *      contract cannot prevent an owner's `approve` call. To combine compounding with AutoExit/AutoRange
 *      on one position, the other contract needs `setApprovalForAll` (scope: all of that owner's
 *      positions); a per-position approval is only recommended when no other automation runs on the
 *      position. Keepers should react to any `Approval(owner, X, id)` event.
 *
 *      What actually limits the approval is not its scope but the code of the approved address: the
 *      approved address is this immutable contract, and it has no code path that removes principal.
 *      `decreaseLiquidity` is never called here and is not even declared in the minimal interface this
 *      contract uses, so it has no ABI for it. Anyone can confirm this by reading the source.
 *
 * Trust model
 *
 * A standing approval, in whatever scope, is acceptable only when both of these hold:
 *
 *  (1) On-chain opt-in. The approval alone grants nothing: a position without `configs[tokenId].enabled`
 *      is never touched, and if `configOwner[tokenId] != ownerOf(tokenId)` the automation stops by
 *      itself (when the position changes hands).
 *
 *  (2) No code path to principal. This file only calls `collect(...)` and `increaseLiquidity(...)`.
 *      There is no `decreaseLiquidity` and no `transferFrom`/`safeTransferFrom`. Even a misused
 *      approval can at worst "compound the fees". At entry, amounts already owed in `tokensOwed`
 *      (including principal the owner removed earlier with `decreaseLiquidity` and did not collect) are
 *      collected straight to `ownerOf(tokenId)` without passing through the contract; that is a payment
 *      to the owner, not a withdrawal. Through `executeWithReference` a keeper can also supply a bad
 *      reference price while the pool's own TWAP and the outside price are both unusable; the damage is
 *      limited to the fees of that compound, the owner's slippage setting does not limit it, and the
 *      reference is cross-checked with the pool's own TWAP when one can be computed.
 *
 * Deliberately absent (each one removes an attack surface):
 *   - Any path that runs caller- or keeper-supplied calldata (no external router calldata).
 *   - Any economic parameter chosen by the keeper on the `execute` path (its inputs are tokenId and
 *     deadline). On `executeWithReference` the reference price is an economic parameter; it is only
 *     used while the pool's own TWAP and the outside price are unusable, and it is cross-checked with
 *     the pool's own TWAP. For pools without a usable own TWAP or outside price, the choice of entry
 *     point is an economic parameter too: `execute` (reference 0) ends in SRC_NONE (no check, no swap,
 *     liquidity added at the spot price), while `executeWithReference` with an honest reference checks
 *     the same run. The owner has no setting that makes a check mandatory. The damage is limited to the
 *     fees of that run.
 *   - A keeper-chosen payout address. Every output goes only to `ownerOf(tokenId)` and `feeRecipient`.
 *   - Balances at rest. The fee is sent in the same transaction and a closing balance check is enforced.
 *   - Upgradeability: no proxy, no delegatecall, no selfdestruct, no general multicall.
 *   - `emergencyWithdrawNFT`: this contract never holds an NFT.
 *   - On-chain gas refunds (a refund path would be a new way to move ETH to a keeper-chosen address).
 *
 * Fee: 10% at most (MAX_REWARD_X64), charged only on the fees that were compounded. Keepers cannot
 * choose it; `setReward` can only lower it (a one-way ratchet).
 */
import {IGoatPriceAnchorV3} from "./IGoatPriceAnchorV3.sol";

/// @dev Extra `GoatPriceAnchor` views this contract uses. Kept local to this file so the shared
/// `IGoatPriceAnchorV3.sol` stays unchanged. The calls are wrapped in try/catch.
interface IAnchorPoolForGAC3 {
    function poolFor(address tokenA, address tokenB) external view returns (address pool, uint128 minDepth);

    function chainlinkAnchor(address tokenA, address tokenB)
        external
        view
        returns (bool ok, uint160 sqrtPriceX96, int24 tick);
}

/// @dev SwapRouter02 single-hop exact-input swap with a price limit (this router has no deadline field).
/// Kept local to this file so the shared `IUniV3Minimal` stays unchanged (same as `IV3RouterSingleForGSC`).
interface IV3RouterSingleForGAC3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract GoatAutoCompoundV3 is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    uint128 constant Q64 = 2**64;
    uint128 constant Q96 = 2**96;

    /// @notice Performance fee as a Q64 fraction, 10% (Q64 / 10) at deployment. Keepers cannot change it.
    uint64 public totalRewardX64 = 1844674407370955161;
    /// @notice Upper limit of the fee (10%). The fee can only be lowered, never raised.
    uint64 public constant MAX_REWARD_X64 = 1844674407370955161;

    /// @dev TWAP window: 1800 s. On Robinhood Chain a 60 s window usually holds no new observation
    /// (TWAP == spot); over 1800 s the natural deviation stays well inside the 100-tick limit.
    uint32 public constant TWAP_SECONDS = 1800;

    /// @notice Maximum age of the pool's latest observation for its own TWAP to be used: W / 10.
    /// @dev The `now` end of `observe([0, W])` is extrapolated with the current tick, so the spot tick
    /// carries a weight of A / W in the result (A = age of the latest observation). Limiting A to
    /// W / 10 limits the spot share of the TWAP to 10%. A trade that changes the tick writes a new
    /// observation, which resets A.
    /// @dev 180 s leaves a wide margin over the observation ages seen on the deepest Robinhood Chain
    /// pools. When the latest observation is older, `_twap` returns `ok = false` and the price check
    /// moves on to the next source: outside price -> caller's reference -> SRC_NONE. The outside price
    /// and reference paths do swap; only SRC_NONE runs without a swap.
    uint32 constant public MAX_STALENESS = 180; // = TWAP_SECONDS / 10
    uint32 public constant MAX_TWAP_TICK_DIFFERENCE = 100;

    uint16 public constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint32 public constant MIN_INTERVAL = 3600; // 1 hour: minimum time between runs of a position

    address public immutable weth;
    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    IV3SwapRouter public immutable swapRouter;
    /// @notice Outside price source (`GoatPriceAnchor`). Immutable, so no owner can point it at another
    /// source and switch off the slippage protection.
    IGoatPriceAnchorV3 public immutable priceAnchor;

    address public feeRecipient;
    address public pendingOwner;
    bool public paused;

    mapping(address => bool) public operators;

    /// @notice Queued changes wait TIMELOCK and must then be applied within QUEUE_GRACE.
    uint256 public constant TIMELOCK = 24 hours;
    uint256 public constant QUEUE_GRACE = 7 days;
    /// @notice queue id (bound to the owner that queued it: a new owner cannot apply it; it counts again only if that
    ///         same address becomes owner again inside the grace window) -> queue timestamp.
    mapping(bytes32 => uint256) public queuedAt;

    /// @notice Pause-only guardian. It may only call setPaused(true) and setOperator(op, false).
    address public guardian;

    struct CompoundConfig {
        bool enabled;
        bool swapEnabled;
        uint16 maxSlippageBps;
        uint32 minInterval;
        uint40 lastRunAt; // never taken from user input. uint40: a uint32 timestamp would wrap after 2106-02-07 and disable the cooldown
        uint128 minReward0;
        uint128 minReward1;
    }

    mapping(uint256 => CompoundConfig) public configs;
    /// @notice Owner at opt-in. If `ownerOf` differs from it, automation stops for that position.
    mapping(uint256 => address) public configOwner;

    event PositionConfigured(uint256 indexed tokenId, address indexed owner, CompoundConfig cfg);
    event Compounded(
        address indexed owner,
        uint256 indexed tokenId,
        uint256 compounded0,
        uint256 compounded1,
        uint256 fee0,
        uint256 fee1
    );
    event OperatorSet(address indexed operator, bool active);
    event FeeRecipientChanged(address indexed previous, address indexed next);

    /// @notice Emitted when a compound ran without a price check: neither the pool's own TWAP nor the
    /// outside price was usable and no reference price was given, so no swap was made. This is a
    /// monitoring signal only; `priceAnchor.hasSource` in the same block tells whether a source is
    /// configured for the pair, but a false result does not prove that there is none.
    event CompoundedWithoutAnchor(uint256 indexed tokenId);

    /// @notice Emitted when neither the pool's own TWAP nor the outside price was usable and the price
    /// check and swap minimum were derived from the reference price the caller computed off-chain
    /// (`refSqrtPriceX96`). A bad reference can cost at most the fees collected in that compound; the
    /// slippage limit is measured against the reference itself.
    event CompoundedWithCallerReference(uint256 indexed tokenId, uint160 refSqrtPriceX96);

    // Which price source the check used (the swap minimum is derived from the same source).
    uint8 internal constant SRC_NONE = 0;
    uint8 internal constant SRC_OWN_TWAP = 1;
    uint8 internal constant SRC_ANCHOR = 2;
    uint8 internal constant SRC_CALLER = 3;
    event RewardLowered(uint64 previous, uint64 next);
    event PausedSet(bool paused);
    event OperatorQueued(address indexed operator, uint256 eta);
    event GuardianSet(address indexed guardian);
    event OwnershipTransferStarted(address indexed previous, address indexed pending);

    constructor(
        INonfungiblePositionManager _nonfungiblePositionManager,
        IV3SwapRouter _swapRouter,
        address _feeRecipient,
        IGoatPriceAnchorV3 _priceAnchor
    ) {
        require(address(_nonfungiblePositionManager) != address(0), "zero npm");
        require(address(_swapRouter) != address(0), "zero router");
        require(_feeRecipient != address(0), "zero feeRecipient");
        require(_feeRecipient != address(this), "self feeRecipient"); // see setFeeRecipient
        require(address(_priceAnchor) != address(0), "zero anchor");
        priceAnchor = _priceAnchor;

        weth = _nonfungiblePositionManager.WETH9();
        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
        feeRecipient = _feeRecipient;
        emit FeeRecipientChanged(address(0), _feeRecipient);
    }

    // ------------------------------------------------------------------ admin

    function _operatorId(address op) internal view returns (bytes32) {
        return keccak256(abi.encode(op, owner()));
    }

    /// @notice Queues a keeper addition (same API as GoatAutoCompoundV4); apply it with setOperator(op, true) in [eta, eta + 7 d].
    function queueOperator(address op) external onlyOwner nonReentrant {
        require(op != address(0), "zero op");
        require(pendingOwner == address(0), "handover pending");
        queuedAt[_operatorId(op)] = block.timestamp;
        emit OperatorQueued(op, block.timestamp + TIMELOCK);
    }

    /// @notice Sets or clears the guardian (owner only, takes effect at once: the role can only stop things).
    function setGuardian(address g) external onlyOwner nonReentrant {
        guardian = g;
        emit GuardianSet(g);
    }

    /// @dev While an ownership transfer is pending (`pendingOwner != 0`) the current owner cannot add keepers
    /// or change `feeRecipient` or the fee, so every fee-related setting and the keeper set stay as the new
    /// owner approved them when it accepts. Removing keepers and `setPaused` stay available (protective).
    /// Limit: keepers added before the transfer started remain, so after accepting, the new owner should
    /// review all `OperatorSet`/`FeeRecipientChanged`/`RewardLowered` events since deployment. The current
    /// owner can also cancel the transfer (transferOwnership(0)), change settings and start it again, which
    /// is why that review is still needed.
    function setOperator(address op, bool active) external nonReentrant {
        require(msg.sender == owner() || (!active && msg.sender == guardian), "not owner or guardian");
        require(op != address(0), "zero op");
        require(!active || pendingOwner == address(0), "handover pending");
        bytes32 id = _operatorId(op);
        if (active) {
            uint256 t = queuedAt[id];
            require(t != 0, "not queued");
            require(block.timestamp >= t + TIMELOCK, "timelock");
            require(block.timestamp <= t + TIMELOCK + QUEUE_GRACE, "expired");
        }
        delete queuedAt[id];
        operators[op] = active;
        emit OperatorSet(op, active);
    }

    function setFeeRecipient(address next) external onlyOwner nonReentrant {
        require(next != address(0), "zero feeRecipient");
        // If it were this contract, fee transfers would stay in its balance and every run with a fee
        // would revert on the "balance invariant" check.
        require(next != address(this), "self feeRecipient");
        require(pendingOwner == address(0), "handover pending"); // see setOperator
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    /// @notice Lowers the fee. It can never be raised.
    function setReward(uint64 next) external onlyOwner nonReentrant {
        // An owner with a pending transfer cannot trigger this one-way change.
        require(pendingOwner == address(0), "handover pending");
        require(next <= totalRewardX64, "reward can only go down");
        emit RewardLowered(totalRewardX64, next);
        totalRewardX64 = next;
    }

    /// @notice Pauses or unpauses keeper runs. The guardian may only pause; unpausing is the owner's.
    function setPaused(bool p) external nonReentrant {
        require(msg.sender == owner() || (p && msg.sender == guardian), "not owner or guardian");
        paused = p;
        emit PausedSet(p);
    }

    /// @dev Two-step ownership transfer; the one-step path is closed.
    /// `next = address(0)` cancels a pending transfer (the owner does not change; `acceptOwnership`
    /// cannot be called from the zero address). The contract can never be left without an owner.
    function transferOwnership(address next) public virtual override onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner(), next);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pendingOwner");
        pendingOwner = address(0);
        _transferOwnership(msg.sender);
    }

    // ------------------------------------------------------------------- user

    /// @notice Opts a position in to automation explicitly (or updates or disables it). Only the position owner can call it.
    /// @dev `lastRunAt` is kept from storage, never taken from the input; otherwise the cooldown would be meaningless.
    function configToken(uint256 tokenId, CompoundConfig calldata cfg) external {
        require(nonfungiblePositionManager.ownerOf(tokenId) == msg.sender, "not position owner");
        require(cfg.maxSlippageBps <= MAX_SLIPPAGE_BPS, "slippage too high");
        if (cfg.enabled) {
            require(cfg.minInterval >= MIN_INTERVAL, "interval too short");
            // `_minOut` turns 0 into the 5% default (the loosest minimum), so a stored and displayed 0
            // would really mean 5%. With swaps on, 0 is rejected.
            if (cfg.swapEnabled) require(cfg.maxSlippageBps != 0, "zero slippage");
        }

        CompoundConfig memory c = cfg;
        c.lastRunAt = configs[tokenId].lastRunAt;
        configs[tokenId] = c;
        configOwner[tokenId] = msg.sender;

        emit PositionConfigured(tokenId, msg.sender, c);
    }

    // ------------------------------------------------------------- automation

    /// @notice The keeper's only input. It carries no economic parameter.
    struct ExecuteParams {
        uint256 tokenId;
        uint256 deadline;
    }

    struct State {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 preOwed0;
        uint128 preOwed1;
        uint256 amount0;
        uint256 amount1;
        uint256 reward0;
        uint256 reward1;
        uint256 maxAdd0;
        uint256 maxAdd1;
        uint256 compounded0;
        uint256 compounded1;
        uint256 fee0;
        uint256 fee1;
        uint256 pre0;
        uint256 pre1;
        address owner;
        // Amounts `increaseLiquidity` actually pulled from this contract (balance difference).
        uint256 pulled0;
        uint256 pulled1;
        // Price check result. floorSqrtP = 0 -> no swap and no second check.
        uint160 floorSqrtP;
        uint32 maxDev;
        // Outside price that is usable as well in step 1 (own TWAP): (sqrt, band). xGate = 0 -> none.
        uint160 xSqrtP;
        uint32 xGate;
        int24 tickAtGate;
    }

    function execute(ExecuteParams calldata p) external nonReentrant {
        _execute(p, 0);
    }

    /**
     * @notice `execute` plus a reference price the keeper computed off-chain. The reference is only used
     * when neither the pool's own TWAP nor the outside price is usable.
     * @dev Trust model: this is the one place where a keeper gives an economic input. Its bounds: it only
     * applies in that case, principal is never removed, and the damage is limited to the fees collected
     * in that compound. The owner's `maxSlippageBps` does not limit a bad reference (the swap minimum is
     * computed from the reference itself).
     * @param refSqrtPriceX96 sqrtPriceX96 in the pool's own direction; 0 = no reference.
     */
    function executeWithReference(ExecuteParams calldata p, uint160 refSqrtPriceX96) external nonReentrant {
        _execute(p, refSqrtPriceX96);
    }

    function _execute(ExecuteParams calldata p, uint160 refSqrtPriceX96) internal {
        require(operators[msg.sender], "not operator");
        require(!paused, "paused");
        require(block.timestamp <= p.deadline, "expired");

        State memory s;
        CompoundConfig memory cfg = configs[p.tokenId];
        require(cfg.enabled, "not configured");

        // the payout address is fixed before the calls that move tokens
        s.owner = nonfungiblePositionManager.ownerOf(p.tokenId);
        require(s.owner == configOwner[p.tokenId], "owner changed");
        require(s.owner != address(this), "self position");

        // cooldown: written before the external calls (reentrancy and run-frequency guard)
        require(block.timestamp >= uint256(cfg.lastRunAt).add(cfg.minInterval), "too soon");
        configs[p.tokenId].lastRunAt = uint40(block.timestamp);

        _loadPosition(p.tokenId, s);
        require(s.liquidity > 0, "no liquidity");
        // `tokensOwed` cannot tell principal from fees: `collect()` writes fees there too. So the owed
        // amounts are kept out of the fee base entirely: they go to the owner in full, without passing
        // through the contract. Only the owed amounts are collected (not max/max): max/max would also
        // sweep the new fees to the owner and leave nothing to compound.
        if (s.preOwed0 != 0 || s.preOwed1 != 0) {
            nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams(p.tokenId, s.owner, s.preOwed0, s.preOwed1)
            );
        }

        // tokens that were already in the contract are not paid out to this owner
        s.pre0 = IERC20(s.token0).balanceOf(address(this));
        s.pre1 = IERC20(s.token1).balanceOf(address(this));

        (s.amount0, s.amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(p.tokenId, address(this), type(uint128).max, type(uint128).max)
        );

        // The collected amount is newly accrued fees only: the owed amounts were paid to the owner at
        // entry. It is the input to the threshold. The fee base, however, is not everything collected
        // but the amount actually compounded (`s.compounded*`, below): if everything is compounded, the
        // fee is about 9.09% of the collected amount.
        s.reward0 = s.amount0;
        s.reward1 = s.amount1;

        // Below the threshold the run reverts (it does not return): the revert undoes the `collect`, so
        // no tokens stay in the contract and the "no balance at rest" rule holds.
        // The threshold only applies to sides with a non-zero minimum, and it passes when either of those
        // is reached. With both minimums 0 there is no threshold (a run with nothing to add is caught by
        // "nothing to compound" below).
        require(
            (cfg.minReward0 == 0 && cfg.minReward1 == 0) ||
                (cfg.minReward0 != 0 && s.reward0 >= cfg.minReward0) ||
                (cfg.minReward1 != 0 && s.reward1 >= cfg.minReward1),
            "below threshold"
        );

        // Price check before compounding. While the pool's own TWAP or the outside price is usable (or
        // the caller gave a reference price), a pool price outside its band reverts the run; with none
        // of them the run uses the unchecked spot price with SRC_NONE (no swap, but liquidity is still
        // added). The check is a precondition for the whole compound, not only for the swap:
        // `increaseLiquidity(amount0Min=0, amount1Min=0)` is itself priced, since liquidity is minted at
        // the current pool price, so the add carries the same risk even when no swap is needed. A
        // revert also undoes the `collect`; the position and tokens are untouched and the run can be
        // retried later. This contract has no claim mode (only GoatSelfCompoundor has one).
        {
            uint8 src = _requireUnmanipulated(s, refSqrtPriceX96); // writes s.floorSqrtP/maxDev/xSqrtP/xGate
            if (src == SRC_NONE) emit CompoundedWithoutAnchor(p.tokenId);
            else if (src == SRC_CALLER) emit CompoundedWithCallerReference(p.tokenId, refSqrtPriceX96);

            if (s.floorSqrtP != 0) {
                (, s.tickAtGate, , , , , ) = IUniswapV3Pool(factory.getPool(s.token0, s.token1, s.fee)).slot0();
                // The swap minimum comes from the source the price check used (own TWAP, outside price or
                // the caller's reference price). The swap lets more of the collected fees be added back.
                if (cfg.swapEnabled) _swapToRatio(s, cfg.maxSlippageBps, p.deadline);
                // The price the mint will see is checked again (a failure reverts): the first check ran
                // before the swap, and `increaseLiquidity(min 0/0)` mints at the price after the swap.
                // Our own swap already has a price limit (it stops inside the band, partial fill;
                // `_gateEdgeLimit`), so this catches an unexpected move (or an error) and applies the
                // outside price band again.
                _requireStillGated(s);
            }
        }

        s.maxAdd0 = s.amount0.mul(Q64).div(uint256(totalRewardX64).add(Q64));
        s.maxAdd1 = s.amount1.mul(Q64).div(uint256(totalRewardX64).add(Q64));

        _increase(p.tokenId, s, p.deadline);

        // A run that adds no liquidity reverts, so it cannot use up the cooldown (`lastRunAt`), and the
        // owed collect at entry is undone too (same as NothingToCompound in GoatV4Compoundor).
        require(s.compounded0 > 0 || s.compounded1 > 0, "nothing to compound");

        // The owed collect at entry (and later token transfers to the owner) can call back into the owner;
        // if the NFT changed hands meanwhile, the run reverts (same as NftNotReturned in
        // GoatAutoCompoundV4). Trust model (1): if configOwner != ownerOf, automation stops.
        require(nonfungiblePositionManager.ownerOf(p.tokenId) == s.owner, "owner changed");

        // Fee base = the amounts actually added. Thanks to the owed collect at entry, no principal can be
        // included here (see the reasoning in GoatSelfCompoundor).
        s.fee0 = s.compounded0.mul(totalRewardX64).div(Q64);
        s.fee1 = s.compounded1.mul(totalRewardX64).div(Q64);

        _payout(s);

        // "End at zero" is enforced on chain: this call must not have changed the contract's balances
        // (tokens sent to it from outside stay where they are).
        require(IERC20(s.token0).balanceOf(address(this)) == s.pre0, "balance0 invariant");
        require(IERC20(s.token1).balanceOf(address(this)) == s.pre1, "balance1 invariant");

        emit Compounded(s.owner, p.tokenId, s.compounded0, s.compounded1, s.fee0, s.fee1);
    }

    // --------------------------------------------------------------- internal

    /// @dev Separate stack frame (avoids "stack too deep" on 0.7.6).
    function _loadPosition(uint256 tokenId, State memory s) internal view {
        (
            ,
            ,
            s.token0,
            s.token1,
            s.fee,
            s.tickLower,
            s.tickUpper,
            s.liquidity,
            ,
            ,
            s.preOwed0,
            s.preOwed1
        ) = nonfungiblePositionManager.positions(tokenId);
    }

    function _increase(uint256 tokenId, State memory s, uint256 deadline) internal {
        if (s.maxAdd0 == 0 && s.maxAdd1 == 0) return;

        /**
         * With one-sided fees and a skipped swap, `increaseLiquidity` computes zero liquidity for an
         * in-range position and fails with an unclear error at `require(amount > 0)` in
         * `UniswapV3Pool.mint`. Stop here with a clear error instead. The revert undoes the `collect`,
         * no tokens stay in the contract and the position is untouched.
         */
        {
            IUniswapV3Pool pool_ = IUniswapV3Pool(factory.getPool(s.token0, s.token1, s.fee));
            (uint160 sp_, , , , , , ) = pool_.slot0();
            uint128 liq_ = LiquidityAmounts.getLiquidityForAmounts(
                sp_,
                TickMath.getSqrtRatioAtTick(s.tickLower),
                TickMath.getSqrtRatioAtTick(s.tickUpper),
                s.maxAdd0,
                s.maxAdd1
            );
            require(liq_ > 0, "nothing to compound");
        }

        if (s.maxAdd0 > 0) SafeERC20.safeApprove(IERC20(s.token0), address(nonfungiblePositionManager), s.maxAdd0);
        if (s.maxAdd1 > 0) SafeERC20.safeApprove(IERC20(s.token1), address(nonfungiblePositionManager), s.maxAdd1);

        // The position manager's `pay` can settle a WETH9 amount from its own ETH balance (ETH someone left
        // in it); `compounded` is then larger than what was pulled. Leftovers use the real balance
        // difference; the fee base stays `compounded`.
        uint256 b0 = IERC20(s.token0).balanceOf(address(this));
        uint256 b1 = IERC20(s.token1).balanceOf(address(this));
        (, s.compounded0, s.compounded1) = nonfungiblePositionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams(tokenId, s.maxAdd0, s.maxAdd1, 0, 0, deadline)
        );
        s.pulled0 = b0.sub(IERC20(s.token0).balanceOf(address(this)));
        s.pulled1 = b1.sub(IERC20(s.token1).balanceOf(address(this)));

        if (s.maxAdd0 > 0) SafeERC20.safeApprove(IERC20(s.token0), address(nonfungiblePositionManager), 0);
        if (s.maxAdd1 > 0) SafeERC20.safeApprove(IERC20(s.token1), address(nonfungiblePositionManager), 0);

        // After a compound with a swap, `tokensOwed` can be non-zero: it is the LP fee that our rebalancing
        // swap paid to this position's own liquidity, which `increaseLiquidity` records in `tokensOwed`.
        // This small amount is collected straight to the owner, so the next run starts clean. The contract
        // balance does not change and the closing balance checks still hold. It cannot be principal: there
        // is no `decreaseLiquidity` in this call.
        {
            (, , , , , , , , , , uint128 owedAfter0, uint128 owedAfter1) = nonfungiblePositionManager.positions(tokenId);
            if (owedAfter0 > 0 || owedAfter1 > 0) {
                nonfungiblePositionManager.collect(
                    INonfungiblePositionManager.CollectParams(tokenId, s.owner, type(uint128).max, type(uint128).max)
                );
            }
        }
    }

    /// @dev Pays the fee to the fee recipient and the rest to the position owner, both in the same transaction.
    function _payout(State memory s) internal {
        // leftover = amount held - amount actually pulled (not `compounded`)
        uint256 left0 = s.amount0.sub(s.pulled0);
        uint256 left1 = s.amount1.sub(s.pulled1);

        if (left0 > s.fee0) SafeERC20.safeTransfer(IERC20(s.token0), s.owner, left0.sub(s.fee0));
        if (left1 > s.fee1) SafeERC20.safeTransfer(IERC20(s.token1), s.owner, left1.sub(s.fee1));
        if (s.fee0 > 0) SafeERC20.safeTransfer(IERC20(s.token0), feeRecipient, s.fee0);
        if (s.fee1 > 0) SafeERC20.safeTransfer(IERC20(s.token1), feeRecipient, s.fee1);
    }

    struct SwapState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 priceX96;
        uint160 lim; // price limit (edge of the price check's band)
        uint256 positionAmount0;
        uint256 positionAmount1;
        uint256 delta0;
        uint256 delta1;
        bool sell0;
        uint256 minOut;
        uint256 spent; // input the router actually pulled (balance difference)
        uint256 out;
    }

    /// @dev Swaps part of the collected fees to the position's ratio. The swap venue is the immutable
    /// `swapRouter` and the path is the position's own fee tier: keepers choose no route.
    function _swapToRatio(State memory s, uint16 slippageBps, uint256 deadline) internal {
        deadline; // SwapRouter02 has no deadline field; execute() already checks it
        SwapState memory w;
        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(s.token0, s.token1, s.fee));
        (w.sqrtPriceX96, w.tick, , , , , ) = pool.slot0();

        // The reference price comes from the price check (`_requireUnmanipulated`), whichever source was used.
        if (s.floorSqrtP == 0) return;
        // Already checked by the price check; repeated so this function also holds on its own.
        if (!_withinTicks(s.floorSqrtP, w.tick, s.maxDev)) return;
        // If the outside price's sqrt is not inside its band around the spot (its tick can differ by one), the limit is undefined: no swap.
        if (s.xGate != 0 && !_withinTicks(s.xSqrtP, w.tick, s.xGate)) return;

        // `sqrt * sqrt` can overflow uint256; FullMath uses a 512-bit intermediate result.
        // The spot priceX96 is only used for the ratio (sizing); below sqrtP = 2^48 it rounds to 0 -> no swap.
        w.priceX96 = FullMath.mulDiv(uint256(w.sqrtPriceX96), uint256(w.sqrtPriceX96), Q96);
        if (w.priceX96 == 0) return;

        (w.positionAmount0, w.positionAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            w.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(s.tickLower),
            TickMath.getSqrtRatioAtTick(s.tickUpper),
            Q96
        );

        if (w.positionAmount0 == 0) {
            w.delta0 = s.amount0;
            w.sell0 = true;
        } else if (w.positionAmount1 == 0) {
            w.delta1 = s.amount1;
            w.sell0 = false;
        } else {
            // A ratio such as `ratioX96 = pos0*Q96/pos1` followed by `ratioX96*priceX96` overflows when the
            // spot price is very close to the lower end of the range (small pos1). This uses the ratio-free
            // derivation of GoatV4Compoundor instead: R = pos0/pos1, P = priceX96/Q96.
            //   sell0: delta0 = (amount0 - R*amount1) / (1 + R*P)
            //   else : delta1 = (amount1 - amount0/R) / (1 + 1/(R*P))   (directly; not derived from delta0)
            // `amount1*pos0/pos1` may not fit in uint256 (spot price just above sqrtLower and a large
            // amount1). If floor(pos0/pos1) >= floor(MAX/amount1), the product is > MAX - amount1 >= amount0
            // (collected fees fit in uint128), so the excess is certainly in token1: use MAX without
            // calling mulDiv (same direction, no revert).
            uint256 wanted0 = (s.amount1 != 0 && w.positionAmount0 / w.positionAmount1 >= type(uint256).max / s.amount1)
                ? type(uint256).max
                : FullMath.mulDiv(s.amount1, w.positionAmount0, w.positionAmount1); // R*amount1
            w.sell0 = s.amount0 > wanted0;
            if (w.sell0) {
                w.delta0 = FullMath.mulDiv(
                    s.amount0 - wanted0,
                    Q96,
                    uint256(Q96).add(FullMath.mulDiv(w.positionAmount0, w.priceX96, w.positionAmount1))
                );
            } else {
                uint256 wanted1 = FullMath.mulDiv(s.amount0, w.positionAmount1, w.positionAmount0); // amount0/R
                if (s.amount1 <= wanted1) return; // already at the ratio
                uint256 rp = FullMath.mulDiv(w.positionAmount0, w.priceX96, w.positionAmount1); // R*P*Q96
                if (rp == 0) return;
                w.delta1 = FullMath.mulDiv(s.amount1 - wanted1, Q96, uint256(Q96).add(FullMath.mulDiv(Q96, Q96, rp)));
            }
        }

        // Our own swap cannot leave the price check's band. The price limit is within one tick of the edge
        // of the band around the reference price; with an outside price as well in step 1, the narrower of
        // the two limits applies (zeroForOne lowers the price -> the larger limit; the other direction ->
        // the smaller one). On a partial fill the minimum is pro rata and the rest is returned (as in
        // GoatSelfCompoundor). A position that is large relative to the pool's depth therefore does not
        // make the run revert: it swaps up to the band edge and still compounds.
        w.lim = _gateEdgeLimit(s.floorSqrtP, w.tick, s.maxDev, w.sell0);
        if (s.xGate != 0) {
            uint160 xLim = _gateEdgeLimit(s.xSqrtP, w.tick, s.xGate, w.sell0);
            if (w.sell0 ? xLim > w.lim : xLim < w.lim) w.lim = xLim;
        }
        if (w.sell0 ? w.sqrtPriceX96 <= w.lim : w.sqrtPriceX96 >= w.lim) return;

        // Fair output from the checked sqrt price, in two steps (as in GoatSelfCompoundor; a rounded
        // priceX96 would lose precision on low-priced pairs). If the minimum comes out as 0, no
        // unprotected swap is made.
        if (w.sell0) {
            if (w.delta0 == 0 || w.delta0 > s.amount0) return;
            w.minOut = _minOut(
                _netOfLpFee(FullMath.mulDiv(FullMath.mulDiv(w.delta0, s.floorSqrtP, Q96), s.floorSqrtP, Q96), s.fee),
                slippageBps
            );
        } else {
            if (w.delta1 == 0 || w.delta1 > s.amount1) return;
            w.minOut = _minOut(
                _netOfLpFee(FullMath.mulDiv(FullMath.mulDiv(w.delta1, Q96, s.floorSqrtP), Q96, s.floorSqrtP), s.fee),
                slippageBps
            );
        }
        if (w.minOut == 0) return;

        _swap(s, w);
        if (w.sell0) {
            s.amount0 = s.amount0.sub(w.spent);
            s.amount1 = s.amount1.add(w.out);
        } else {
            s.amount1 = s.amount1.sub(w.spent);
            s.amount0 = s.amount0.add(w.out);
        }
    }

    /// @dev Single-hop exact-input swap with a price limit, through the immutable `swapRouter`.
    /// On a partial fill the minimum is kept per unit (it scales linearly with amountIn), so the router's own minimum is 0
    /// and the check is done here. Spent and received amounts are measured from real balance differences: SwapRouter02 `pay`
    /// can settle a WETH9 amount from its own ETH balance (ETH someone left in the router), and then nothing is pulled from this contract.
    function _swap(State memory s, SwapState memory w) internal {
        address tokenIn = w.sell0 ? s.token0 : s.token1;
        address tokenOut = w.sell0 ? s.token1 : s.token0;
        uint256 amountIn = w.sell0 ? w.delta0 : w.delta1;
        uint256 bIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 bOut = IERC20(tokenOut).balanceOf(address(this));
        SafeERC20.safeApprove(IERC20(tokenIn), address(swapRouter), amountIn);
        IV3RouterSingleForGAC3(address(swapRouter)).exactInputSingle(
            IV3RouterSingleForGAC3.ExactInputSingleParams(tokenIn, tokenOut, s.fee, address(this), amountIn, 0, w.lim)
        );
        SafeERC20.safeApprove(IERC20(tokenIn), address(swapRouter), 0);
        w.spent = bIn.sub(IERC20(tokenIn).balanceOf(address(this)));
        w.out = IERC20(tokenOut).balanceOf(address(this)).sub(bOut);
        require(w.spent <= amountIn, "overspent");
        uint256 floor_ = w.spent == amountIn ? w.minOut : FullMath.mulDivRoundingUp(w.minOut, w.spent, amountIn);
        require(w.out >= floor_, "Too little received");
    }

    /// @dev Swap minimum: from the source the price check used (own TWAP / outside price / caller's reference).
    /// The bps upper limit is `MAX_SLIPPAGE_BPS`, enforced in `configToken`; with swaps on, 0 is rejected there.
    /// @dev Deducts the pool's static LP fee from a fair output. The swap pays this fee to LPs; a
    /// minimum computed from the fee-free fair output made swaps with a low tolerance revert
    /// needlessly. Counterpart in v4: `GoatV4Compoundor._netOfLpFee`.
    function _netOfLpFee(uint256 x, uint24 fee_) internal pure returns (uint256) {
        return FullMath.mulDiv(x, uint256(1000000).sub(uint256(fee_)), 1000000);
    }

    function _minOut(uint256 fairOut, uint16 bps) internal pure returns (uint256) {
        // `configToken` enforces bps <= 500, so no upper bound check is needed here. bps = 0 can only be
        // stored in a config with swaps off (where `_minOut` is not called).
        uint256 b = bps == 0 ? 500 : uint256(bps);
        return fairOut.mul(uint256(10000).sub(b)).div(10000);
    }

    /// @dev `_twap` without its staleness check, used only to cross-check a caller's reference price.
    /// However old the latest observation is, it returns the time-weighted average whenever
    /// `observe([0, TWAP_SECONDS])` can be computed (the stale part is extrapolated with the current tick).
    function _twapIgnoringStaleness(IUniswapV3Pool pool) internal view returns (int24 tick, bool ok) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = 0;
        ago[1] = TWAP_SECONDS;
        try pool.observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 delta = cum[0] - cum[1];
            int56 window = int56(TWAP_SECONDS);
            int24 t = int24(delta / window);
            if (delta < 0 && delta % window != 0) t--;
            return (t, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @dev TWAP tick of the pool. It is not valid when the window holds no real observation:
     * if the target time `now - W` falls after the latest observation, `observe([0, W])` extrapolates
     * both ends with the current tick and the TWAP equals the spot price exactly (the check would mean
     * nothing). A real TWAP only needs `now - lastTs <= W`; the rule enforced is stricter:
     * `now - lastTs <= MAX_STALENESS = 180 s` (= W / 10), which limits the spot share to 10% (see
     * `MAX_STALENESS`). When older, `ok = false` and the price check moves on to the next source.
     */
    function _twap(IUniswapV3Pool pool) internal view returns (int24 tick, bool ok) {
        (, , uint16 obsIndex, uint16 card, , , ) = pool.slot0();
        if (card == 0) return (0, false);
        (uint32 lastTs, , , bool init) = pool.observations(obsIndex);
        if (!init) return (0, false);
        uint32 nowTs = uint32(block.timestamp);
        if (lastTs > nowTs || nowTs - lastTs > MAX_STALENESS) return (0, false);

        uint32[] memory ago = new uint32[](2);
        ago[0] = 0;
        ago[1] = TWAP_SECONDS;
        try pool.observe(ago) returns (int56[] memory cum, uint160[] memory) {
            // Round negative ticks down. Solidity division truncates toward zero, while Uniswap's
            // `OracleLibrary.consult` rounds negative values down. Pools with negative ticks (for
            // example WETH/USDG on Robinhood Chain) take this branch all the time. Same rounding as
            // `GoatPriceAnchor`.
            int56 delta = cum[0] - cum[1];
            int56 window = int56(TWAP_SECONDS);
            int24 t = int24(delta / window);
            if (delta < 0 && delta % window != 0) t--;
            return (t, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @dev Precondition for a compound, enforced while a price source is available.
     *
     * Design:
     *  1) Skipping only the swap when the price check fails, but still adding the liquidity, would not
     *     be enough: `increaseLiquidity(amount0Min=0, amount1Min=0)` is itself priced, since liquidity is
     *     minted at the current pool price. The check is therefore a precondition for the whole compound,
     *     not part of the swap path (swapEnabled = false is covered too).
     *  2) Rejecting every compound without a price source would block the product: many pools on
     *     Robinhood Chain, such as those of stock tokens, often have no fresh observation, so compounds
     *     would only work on the deepest pairs.
     *
     * Rule: enforce the check while a source is usable, otherwise compound without it. A pool price that
     * has moved away from a usable source is rejected, and pairs with no usable source still compound.
     * The risk accepted there is limited to the fees: relative to an undisturbed run, the loss is at most
     * the fees collected in that run, and principal is never withdrawn. For pairs without an outside price
     * and a fee tier of 500 (0.05%) or lower, this contract has no claim mode, so keepers should not run such
     * positions, or only through `executeWithReference` with an honest reference (GoatSelfCompoundor and
     * GoatAutoCompoundV4 offer a claim mode instead). This branch is only reached when the pool's own TWAP
     * is not usable; the real remedy is to grow that pool's observation buffer
     * (`increaseObservationCardinalityNext`, callable by anyone).
     * The outside price (step 2) comes only from Chainlink or from a pool the anchor owner assigned
     * with a 24 hour delay (`GoatPriceAnchor`); the factory is not scanned.
     * The no-check path is also used when a source exists but is not usable at the moment.
     */
    /// @return src price source used (SRC_*). The result is written to `s`: `s.floorSqrtP` is the sqrt price the swap minimum is based on (0 = no swap),
    ///         `s.maxDev` the allowed deviation for that source (ticks), and `s.xSqrtP`/`s.xGate` an outside price that is usable as well,
    ///         only in step 1 (own TWAP) (sqrt, band; xGate = 0: none). The swap limit uses the narrower of the two bands,
    ///         and the check after the swap applies both.
    function _requireUnmanipulated(State memory s, uint160 refSqrtPriceX96)
        internal
        view
        returns (uint8 src)
    {
        // The result is written to `s` (floorSqrtP, maxDev, xSqrtP, xGate), not returned, because of the 0.7.6 stack limit.
        s.floorSqrtP = 0;
        s.maxDev = 0;
        s.xSqrtP = 0;
        s.xGate = 0;
        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(s.token0, s.token1, s.fee));
        if (address(pool) == address(0)) return SRC_NONE;   // no pool for the position (cannot happen)
        (, int24 tick, , , , , ) = pool.slot0();

        // 1) Primary: the TWAP of the position's own pool, if fresh.
        (int24 twapTick, bool ok) = _twap(pool);
        if (ok) {
            int24 dev = tick > twapTick ? tick - twapTick : twapTick - tick;
            require(uint32(dev) < MAX_TWAP_TICK_DIFFERENCE, "price manipulated");
            // A fresh own TWAP does not override the outside price: if the outside price is usable, the
            // spot price must also be inside its band (a failure reverts). Cost (accepted by the owner):
            // when a stock price feed is paused, for example over a weekend, pairs outside the band revert;
            // the swap minimum is still based on the own TWAP.
            // The outside price (sqrt, band) is kept as well: the swap limit uses the narrower of the two
            // bands, and the check after the swap applies both (`_requireStillGated`).
            // Note: `priceAnchor.anchor` is called here without try/catch (a failure reverts): the
            // production `GoatPriceAnchor.anchor` is written not to revert; if it did, compounding on these
            // pools would stop (principal is not affected).
            (s.xSqrtP, s.xGate) = _ownTwapAnchorBand(s, address(pool), tick);
            s.floorSqrtP = TickMath.getSqrtRatioAtTick(twapTick);
            s.maxDev = MAX_TWAP_TICK_DIFFERENCE;
            return SRC_OWN_TWAP;
        }

        /**
         * 2) The observation of the pool's own TWAP is stale (or the TWAP cannot be computed). Returning
         * here would leave the pool with no check at all, which happens in practice on pools that trade
         * rarely.
         *
         * So the check falls back to the outside price: `GoatPriceAnchor` returns Chainlink or a pool its
         * owner assigned with a 24 hour delay, a stronger reference; the factory is not scanned.
         */
        (bool aOk, uint160 aSqrt, int24 anchorTick) = _anchorFor(s, address(pool));
        if (aOk) {
            uint32 gate = _anchorGateTicks(s.fee);
            int24 dev2 = tick > anchorTick ? tick - anchorTick : anchorTick - tick;
            require(uint32(dev2) < gate, "price manipulated");
            s.floorSqrtP = aSqrt; // the swap minimum already uses the outside price
            s.maxDev = gate;
            return SRC_ANCHOR;
        }

        /**
         * 3b) If the caller supplied a reference price computed off-chain (the keeper's
         *     `executeWithReference`), the price check and the swap minimum use it. A price fixed before
         *     the transaction cannot be moved by trades inside it. The reference is a sqrtPriceX96 in the
         *     pool's own direction (token1/token0). Without a reference, the run has no check and no swap.
         */
        if (refSqrtPriceX96 != 0) {
            require(
                refSqrtPriceX96 >= TickMath.MIN_SQRT_RATIO && refSqrtPriceX96 < TickMath.MAX_SQRT_RATIO,
                "bad reference"
            );
            uint32 gate3 = _anchorGateTicks(s.fee);
            require(_withinTicks(refSqrtPriceX96, tick, gate3), "price manipulated");
            // If a TWAP of the pool can still be computed (even from a stale observation, as long as the
            // `observe` history covers the window), the reference must also be inside its band. A TWAP
            // stays close to the longer-term price, so a reference equal to a recently moved spot price
            // is rejected here, while a correct reference derived from the same pool's history passes.
            // When `observe` cannot be computed at all (low cardinality), this extra check is skipped.
            {
                (int24 anyTwapTick, bool twapComputable) = _twapIgnoringStaleness(pool);
                if (twapComputable) require(_withinTicks(refSqrtPriceX96, anyTwapTick, gate3), "price manipulated");
            }
            s.floorSqrtP = refSqrtPriceX96;
            s.maxDev = gate3;
            return SRC_CALLER;
        }

        /**
         * 3) No usable source: run without a price check and without a swap. This also applies when a
         *    source exists but is not usable right now, so a pair cannot be blocked by its price source.
         *    In v3 this branch is only reached when the pool's own TWAP is not usable, for one of two reasons:
         *     (i)  the pool has not traded for longer than MAX_STALENESS. v3 writes an observation on
         *          every tick change, so the spot price has not moved during that time.
         *     (ii) the observation is fresh but the TWAP cannot be computed (low cardinality). The spot
         *          price is then not checked; the risk is limited to the fees
         *          (no swap, principal is never withdrawn).
         *    Both conditions can also be caused deliberately, so the spot price here counts as unchecked.
         */
        return SRC_NONE;
    }

    /// @dev Outside price cross-check and swap band for step 1 (own TWAP). If the outside price is usable,
    /// the spot price must be within `_anchorGateTicks(fee)` of it (otherwise "price manipulated"); returns (sqrt, band), or (0, 0).
    function _ownTwapAnchorBand(State memory s, address pool, int24 tick) internal view returns (uint160 xSqrtP, uint32 xGate) {
        (bool aOk, uint160 aSqrt, int24 aTick) = _anchorFor(s, pool);
        if (!aOk) return (0, 0);
        xGate = _anchorGateTicks(s.fee);
        int24 devA = tick > aTick ? tick - aTick : aTick - tick;
        require(uint32(devA) < xGate, "price manipulated");
        xSqrtP = aSqrt;
    }

    /// @dev Band for step 2 (outside price), by fee tier: max(100, fee in bps + 50) ticks.
    /// A pool can drift from the outside price by up to its own fee before arbitrage pays; the extra 50
    /// covers the 0.5% deviation threshold of Chainlink feeds. Among v3 fee tiers only the 1% tier changes
    /// (150). Step 1 (the pool's own TWAP) is unchanged: there the pool is compared with itself. Counterpart in v4: `GoatV4Compoundor._gateTicks`.
    uint32 constant public ANCHOR_FEED_LAG_TICKS = 50;
    uint32 constant public ANCHOR_MAX_GATE_TICKS = 1050;

    /// @dev |tick(sqrtP) - spotTick| < maxDev, without converting to a tick (TickMathMIT has no
    /// getTickAtSqrtRatio). floor(tick(sqrtP)) in [spot-maxDev+1, spot+maxDev-1]
    /// <=> sqrtAt(spot-maxDev+1) <= sqrtP < sqrtAt(spot+maxDev).
    function _withinTicks(uint160 sqrtP, int24 spotTick, uint32 maxDev) internal pure returns (bool) {
        int24 lo = spotTick - int24(maxDev) + 1;
        int24 hi = spotTick + int24(maxDev);
        if (lo < TickMath.MIN_TICK) lo = TickMath.MIN_TICK;
        if (hi > TickMath.MAX_TICK) hi = TickMath.MAX_TICK;
        return sqrtP >= TickMath.getSqrtRatioAtTick(lo) && sqrtP < TickMath.getSqrtRatioAtTick(hi);
    }

    /// @dev The spot price after the swap (the price the mint will see) must be inside the price check's band,
    /// and, if an outside price was usable as well in step 1 (own TWAP), inside its band too (a failure reverts). Our own swap
    /// stops inside the narrower of the two bands (`_gateEdgeLimit`), so this check only reverts on an unexpected price move
    /// (or an error). If the tick has not changed since the check, the check's own result stands (the outside price's sqrt
    /// and tick can differ by one; in that case the swap is skipped).
    function _requireStillGated(State memory s) internal view {
        (, int24 tNow, , , , , ) = IUniswapV3Pool(factory.getPool(s.token0, s.token1, s.fee)).slot0();
        if (tNow == s.tickAtGate) return;
        require(_withinTicks(s.floorSqrtP, tNow, s.maxDev), "price manipulated");
        if (s.xGate != 0) require(_withinTicks(s.xSqrtP, tNow, s.xGate), "price manipulated");
    }

    /// @dev Same as `_gateEdgeLimit` in GoatSelfCompoundor. floorTick = the largest t with sqrtAt(t) <= floorSqrtP,
    /// searched within the band the price check already confirmed (`_withinTicks(floor, spotTick, maxDev)` <=> floorTick in
    /// [spot-maxDev+1, spot+maxDev-1]). The limit keeps the end tick e inside [floorTick-maxDev+1, floorTick+maxDev-1],
    /// so `_withinTicks(floor, e, maxDev)` holds after the swap.
    function _gateEdgeLimit(uint160 floorSqrtP, int24 spotTick, uint32 maxDev, bool zeroForOne)
        internal
        pure
        returns (uint160 lim)
    {
        int24 lo = spotTick - int24(maxDev) + 1;
        int24 hi = spotTick + int24(maxDev) - 1;
        if (lo < TickMath.MIN_TICK) lo = TickMath.MIN_TICK;
        if (hi > TickMath.MAX_TICK) hi = TickMath.MAX_TICK;
        while (lo < hi) {
            int24 mid = lo + (hi - lo + 1) / 2;
            if (TickMath.getSqrtRatioAtTick(mid) <= floorSqrtP) lo = mid;
            else hi = mid - 1;
        }
        if (zeroForOne) {
            int24 t = lo - int24(maxDev) + 1;
            if (t < TickMath.MIN_TICK) t = TickMath.MIN_TICK;
            lim = TickMath.getSqrtRatioAtTick(t) + 1;
        } else {
            int24 t = lo + int24(maxDev);
            if (t > TickMath.MAX_TICK) t = TickMath.MAX_TICK;
            lim = TickMath.getSqrtRatioAtTick(t) - 1;
        }
    }

    function _anchorGateTicks(uint24 fee_) internal pure returns (uint32) {
        uint32 band = uint32(fee_ / 100) + ANCHOR_FEED_LAG_TICKS;
        if (band <= MAX_TWAP_TICK_DIFFERENCE) return MAX_TWAP_TICK_DIFFERENCE;
        return band > ANCHOR_MAX_GATE_TICKS ? ANCHOR_MAX_GATE_TICKS : band;
    }

    /// @dev Outside price for the pair. A price taken from the position's own pool is not an independent reference
    /// (the band check would compare the pool with itself). If the anchor's assigned v3 pool is this pool,
    /// only the Chainlink path is accepted; without Chainlink the outside price counts as unavailable (the next
    /// source is used). If `poolFor` cannot be called (an older anchor or a mock), the assigned pool counts as none.
    function _anchorFor(State memory s, address pool) internal view returns (bool ok, uint160 sqrtP, int24 t) {
        (ok, sqrtP, t) = priceAnchor.anchor(s.token0, s.token1);
        if (!ok) return (false, 0, 0);
        address src;
        try IAnchorPoolForGAC3(address(priceAnchor)).poolFor(s.token0, s.token1) returns (address p_, uint128) {
            src = p_;
        } catch {}
        if (src != pool) return (ok, sqrtP, t);
        try IAnchorPoolForGAC3(address(priceAnchor)).chainlinkAnchor(s.token0, s.token1) returns (
            bool o_,
            uint160 q_,
            int24 t_
        ) {
            return (o_, q_, t_);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @notice Disabled. Without an owner, `setOperator`, `setPaused` and `feeRecipient` would be frozen for good (a keeper could no longer be removed by the owner).
    /// An accidental call could not be undone; ownership moves with `transferOwnership` + `acceptOwnership`.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }
}
