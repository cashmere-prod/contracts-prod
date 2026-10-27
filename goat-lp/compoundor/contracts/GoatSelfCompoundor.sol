// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import "./external/openzeppelin/access/Ownable.sol";
import {IGoatPriceAnchorV3} from "./IGoatPriceAnchorV3.sol";
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

/// @dev Extra `GoatPriceAnchor` views, used to see which source an outside price came from. Kept local
/// to this file so the shared `IGoatPriceAnchorV3` stays unchanged. Both exist on `GoatPriceAnchor`:
/// `poolFor` is the v3 pool assigned to the pair, `chainlinkAnchor` the Chainlink path (`anchor()` tries Chainlink first).
interface IAnchorPoolForGSC {
    function poolFor(address tokenA, address tokenB) external view returns (address pool, uint128 minDepth);
    function chainlinkAnchor(address tokenA, address tokenB)
        external
        view
        returns (bool ok, uint160 sqrtPriceX96, int24 tick);
}

/// @dev SwapRouter02 single-hop swap with a price limit (this router has no deadline field).
/// Kept local to this file so the shared `IUniV3Minimal` stays unchanged.
interface IV3RouterSingleForGSC {
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


/**
 * @notice One-click compounding for Uniswap v3 positions. The position owner sends the NFT to this
 *         contract; it collects the fees, adds them back as liquidity, pays a 10% fee on what was
 *         added back and returns the NFT in the same transaction.
 * @dev Cashmere/GoatStreet fork of revert.finance SelfCompoundor (MIT).
 *      Changes from the original:
 *      1) A 10% protocol fee instead of 0% (totalRewardX64 = Q64 / 10 = 1844674407370955161), charged
 *         only on the fees that were compounded or claimed. Amounts already owed to the position
 *         (`tokensOwed`, which can include principal) are not part of the fee base: at entry they are
 *         collected straight to the owner, in full.
 *      2) The fee is sent to `feeRecipient` in the same transaction, and the contract holds nothing
 *         between calls (the same rule as Revert's V4Utils: "It does not hold any ERC20 or NFTs").
 *         This is what makes measuring by balance differences sound. `emergencyWithdraw*` only exists
 *         for assets sent here by mistake and is not used in normal operation.
 *      3) Two-step ownership transfer (transferOwnership + acceptOwnership).
 *      4) Price checks before compounding: the pool's own TWAP (maxTWAPTickDifference = 100 ticks,
 *         about 1%; TWAPSeconds = 1800; MAX_STALENESS = 180), then the outside price from
 *         `priceAnchor`, then a reference price supplied by the owner (see `_requireUnmanipulated`).
 *         When none of them is usable, the compound runs without a swap.
 */
contract GoatSelfCompoundor is Ownable, ReentrancyGuard {

    using SafeMath for uint256;

    uint128 constant Q64 = 2**64;
    uint128 constant Q96 = 2**96;

    // Fork change: 10% performance fee (Q64 / 10; fits in uint64). The base is only the fees that were
    // compounded, never principal, so nothing is taken from the position itself. Because at most
    // amount / 1.1 is added back, a full compound pays about 9.09% of the collected fees, which is
    // exactly 10% of the amount compounded. Revert's SelfCompoundor sets this to 0.
    uint64 constant public totalRewardX64 = 1844674407370955161; // = 2**64 / 10 = 10%
    uint32 constant public maxTWAPTickDifference = 100; // 1% max tick difference
    /// @dev TWAP window for the pool's own price check. On Robinhood Chain a 60 second window usually
    /// holds no new observation, so the TWAP equals the spot price and the deviation check would
    /// compare the spot price with itself. Over 1800 s the natural deviation stays well inside the
    /// 100-tick limit, so normal trading passes and a moved price is caught.
    uint32 constant public TWAPSeconds = 1800; // 30 minutes

    /// @notice Maximum age of the pool's latest observation for its own TWAP to be used: W / 10.
    /// @dev The `now` end of `observe([0, W])` is extrapolated with the current tick, so the spot tick
    /// carries a weight of A / W in the result (A = age of the latest observation). Limiting A to
    /// W / 10 limits the spot share of the TWAP to 10%. A trade that changes the tick writes a new
    /// observation, which resets A.
    /// @dev 180 s leaves a wide margin over the observation ages seen on the deepest Robinhood Chain
    /// pools. When the latest observation is older, the own-TWAP step is skipped and the price check
    /// falls back to the outside price, then to the owner's reference price; with neither, the
    /// compound runs without a swap.
    uint32 constant public MAX_STALENESS = 180; // = TWAPSeconds / 10

    // uniswap v3 components
    IUniswapV3Factory immutable public factory;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    IV3SwapRouter immutable public swapRouter;
    /// @notice Outside price source (`GoatPriceAnchor`). Immutable: it cannot be pointed elsewhere.
    IGoatPriceAnchorV3 immutable public priceAnchor;

    // autocompound event
    event AutoCompounded(
        address indexed account,
        uint256 indexed tokenId,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1
    );

    /// @notice Address that receives the protocol fee, in the same transaction. The contract keeps
    /// no balance between calls: every call ends with the balances it started with.
    /// It must be able to receive the pool's tokens; if a fee transfer fails, the compound reverts.
    address public feeRecipient;

    event FeeRecipientChanged(address indexed previous, address indexed next);

    /// @notice Emitted when a compound ran without a price check: neither the pool's own TWAP nor the
    /// outside price was usable and no reference price was given, so no swap was made. This is a
    /// monitoring signal only; `priceAnchor.hasSource` in the same block tells whether a source is
    /// configured for the pair, but a false result does not prove that there is none.
    event CompoundedWithoutAnchor(uint256 indexed tokenId);

    /// @notice Emitted when neither the pool's own TWAP nor the outside price was usable and the price
    /// check and swap minimum were derived from the reference price the caller computed off-chain
    /// (`refSqrtPriceX96`). A bad reference can cost at most the fees collected in that compound; the
    /// slippage limit is measured against the reference itself (on this path the NFT owner supplies it).
    event CompoundedWithCallerReference(uint256 indexed tokenId, uint160 refSqrtPriceX96);

    // Which price source the check used (the swap minimum is derived from the same source).
    uint8 internal constant SRC_NONE = 0;
    uint8 internal constant SRC_OWN_TWAP = 1;
    uint8 internal constant SRC_ANCHOR = 2;
    uint8 internal constant SRC_CALLER = 3;

    constructor(
        INonfungiblePositionManager _nonfungiblePositionManager,
        IV3SwapRouter _swapRouter,
        address _feeRecipient,
        IGoatPriceAnchorV3 _priceAnchor
    ) {
        require(address(_nonfungiblePositionManager) != address(0) && address(_swapRouter) != address(0));
        require(_feeRecipient != address(0), "zero feeRecipient");
        // The contract cannot be its own fee recipient: every compound or claim with a fee would then
        // fail the closing balance check.
        require(_feeRecipient != address(this), "self feeRecipient");
        require(address(_priceAnchor) != address(0), "zero anchor");
        priceAnchor = _priceAnchor;
        feeRecipient = _feeRecipient;
        emit FeeRecipientChanged(address(0), _feeRecipient);

        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
    }

    /**
     * @notice Owner-only recovery of assets sent to this contract by mistake.
     */
    /// @notice Recovers a position NFT that was sent with a plain `transferFrom` instead of
    /// `safeTransferFrom`: that does not call `onERC721Received`, so the NFT would otherwise stay
    /// in this contract. In normal operation the contract holds no NFT.
    function emergencyWithdrawNFT(uint256 tokenId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId);
    }

    /// @notice Proposed new owner, confirmed by `acceptOwnership`. The vendored OpenZeppelin `Ownable`
    /// for 0.7.6 has no two-step transfer, and a one-step transfer to a wrong address would lose
    /// `setFeeRecipient` and the recovery functions for good, so the proposed owner must accept the transfer itself.
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previous, address indexed pending);

    /// @dev Overrides `transferOwnership`: the one-step transfer path is closed. The call only records
    /// the candidate; the transfer completes with `acceptOwnership`. `next = address(0)` cancels a
    /// pending transfer (the owner does not change, and address(0) cannot call `acceptOwnership`).
    /// Ownership can never become zero: renounce is disabled.
    function transferOwnership(address next) public virtual override onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner(), next);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pendingOwner");
        pendingOwner = address(0);
        _transferOwnership(msg.sender);
    }

    /// @notice Changes the fee recipient (onlyOwner).
    /// @dev Blocked while an ownership transfer is pending, so the outgoing owner cannot change the fee
    /// recipient the new owner approved just before acceptance. The pending transfer can be cancelled
    /// first with `transferOwnership(address(0))`, which is visible on chain. Cancelling, changing and
    /// proposing again therefore gets around this lock only in the open, and a new owner can set its
    /// approved recipient again right after `acceptOwnership` (acceptance clears `pendingOwner`).
    /// The contract itself cannot be the fee recipient.
    function setFeeRecipient(address next) external onlyOwner nonReentrant {
        require(pendingOwner == address(0), "handover pending");
        require(next != address(0), "zero feeRecipient");
        require(next != address(this), "self feeRecipient");
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    /// @dev Sends the fee to the fee recipient right away; if the transfer fails, the whole call reverts.
    function _payFee(address token, uint256 amount) internal {
        if (amount > 0) SafeERC20.safeTransfer(IERC20(token), feeRecipient, amount);
    }

    function emergencyWithdrawBalances(address[] calldata tokens, address to) external onlyOwner nonReentrant {

        require(to != address(0));

        uint count = tokens.length;
        uint i;
        for(;i<count;++i) {
            IERC20 token = IERC20(tokens[i]);
            uint256 balance = token.balanceOf(address(this));
            // Zero balances are skipped (some tokens reject zero-amount transfers).
            if (balance > 0) SafeERC20.safeTransfer(token, to, balance);
        }
    }

    /**
     * @dev When receiving a Uniswap V3 NFT, executes autocompound and returns NFT in same tx.
     *      `data` is either empty (compound with a swap, 5% slippage) or abi-encoded as
     *      (bool doSwap, bool claimOnly, uint256 slippageBps, bytes returnData), optionally followed by
     *      uint160 refSqrtPriceX96. `returnData` is passed along when the NFT is sent back.
     */
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external nonReentrant returns (bytes4) {
        require(msg.sender == address(nonfungiblePositionManager), "!univ3 pos");

        bool doSwap;
        bool claimOnly;
        uint256 slippageBps;
        bytes memory returnData;
        uint160 refSqrtPriceX96;

        if (data.length > 0) {
            // Fork change: Revert decodes (bool, bytes). This fork adds claim mode and a swap slippage
            // tolerance: (bool, bool, uint256, bytes), with an optional fifth field
            // (bool, bool, uint256, bytes, uint160 refSqrtPriceX96).
            // The two layouts are told apart by the offset of the `bytes` field: right after a 4-word
            // head (0x80) in the short layout, after a 5-word head (0xa0) in the long one. Only the NFT
            // owner reaches this path, so a non-canonical encoding only affects that owner.
            uint256 bytesOffset = data.length >= 128 ? abi.decode(data[96:128], (uint256)) : 0;
            if (bytesOffset == 0xa0) {
                (doSwap, claimOnly, slippageBps, returnData, refSqrtPriceX96) =
                    abi.decode(data, (bool, bool, uint256, bytes, uint160));
            } else {
                (doSwap, claimOnly, slippageBps, returnData) = abi.decode(data, (bool, bool, uint256, bytes));
            }
            // An explicitly encoded 0 is not turned into 5%: for a compound with a swap it is rejected
            // (it would otherwise be the loosest minimum). The 5% default applies only to empty data,
            // where 500 is set explicitly below.
            require(claimOnly || !doSwap || slippageBps != 0, "slippage 0");
        } else {
            doSwap = true; // default: compound with a swap, default tolerance (5%), empty returnData
            slippageBps = 500;
        }
        // Inputs are checked here for every mode (as in GoatV4Compoundor): a tolerance above 20% or an
        // out-of-range reference price is rejected whether or not a swap follows.
        require(slippageBps <= 2000, "slippage too high");
        require(
            refSqrtPriceX96 == 0 ||
                (refSqrtPriceX96 >= TickMath.MIN_SQRT_RATIO && refSqrtPriceX96 < TickMath.MAX_SQRT_RATIO),
            "bad reference"
        );

        (, , , , , , , uint128 liqAtEntry, , , , ) = nonfungiblePositionManager.positions(tokenId);

        _autoCompound(tokenId, from, doSwap, claimOnly, slippageBps, refSqrtPriceX96);

        // Before the NFT is returned: it must still be held by this contract, and its liquidity must not
        // have decreased during the call. Otherwise nothing is returned and the transaction reverts.
        require(nonfungiblePositionManager.ownerOf(tokenId) == address(this), "nft left mid-flight");
        {
            (, , , , , , , uint128 liqAtExit, , , , ) = nonfungiblePositionManager.positions(tokenId);
            require(liqAtExit >= liqAtEntry, "liquidity decreased");
        }

        nonfungiblePositionManager.safeTransferFrom(address(this), from, tokenId, returnData);

        return this.onERC721Received.selector;
    }

    // state used during autocompound execution
    struct AutoCompoundState {
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 compounded0;
        uint256 compounded1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        uint256 priceX96;
        // Balances at entry. Leftovers are computed from real balance changes rather than the amounts
        // reported by `collect` or the router, and every call must end with exactly these balances, so
        // tokens that were already in the contract are never paid out to a user (same rule as
        // `GoatAutoCompoundV3`).
        uint256 pre0;
        uint256 pre1;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        // Price check source and swap minimum (kept in the struct because of stack depth).
        uint160 refSqrtP;
        uint160 floorSqrtP;
        uint32 floorMaxDev;
        uint8 anchorSrc;
        int24 tickAtGate; // tick seen by the price check (to check again after the swap)
        // In step 1 (own TWAP), the outside price's sqrt and band when it is usable as well. The swap
        // limit and the check after the swap respect both bands.
        uint160 xAnchorSqrtP;
        uint32 xAnchorGate; // 0 = no usable outside price in step 1 (presence flag; a band is always > 0)
    }

    /**
     * @notice Autocompounds for a given NFT
     * @param tokenId token id
     * @param from address which sent NFT
     * @param doSwap is swap requested
     * @param claimOnly send the collected fees, minus the protocol fee, to `from` instead of compounding
     * @param slippageBps swap slippage tolerance in basis points
     * @param refSqrtPriceX96 optional reference price from the owner, as a sqrtPriceX96 (0 = none)
     */
    function _autoCompound(uint256 tokenId, address from, bool doSwap, bool claimOnly, uint256 slippageBps, uint160 refSqrtPriceX96) internal
    {
        AutoCompoundState memory state;
        state.refSqrtP = refSqrtPriceX96;

        /**
         * `tokensOwed` cannot tell principal from fees: `collect()` in v3-periphery pokes the position
         * and writes accrued fees to the same slot. So the owed amounts are kept out of the fee base
         * entirely: if they are non-zero, `collect(tokenId, from, owed0, owed1)` pays exactly those
         * amounts straight to the owner, without a fee and without passing through this contract.
         * Everything collected into the contract afterwards is newly accrued fees, and principal is
         * never inside. Only the owed amounts are collected here (not max/max), because max/max would
         * also sweep the new fees to the owner and leave nothing to compound. The effect is the same
         * as the owner calling `collect` first.
         */
        {
            uint128 owed0_;
            uint128 owed1_;
            (, , state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, , , , owed0_, owed1_) =
                nonfungiblePositionManager.positions(tokenId);
            if (owed0_ != 0 || owed1_ != 0) {
                nonfungiblePositionManager.collect(
                    INonfungiblePositionManager.CollectParams(tokenId, from, owed0_, owed1_)
                );
            }
        }

        // Tokens that were already in the contract are not paid out to this user (see the struct).
        state.pre0 = IERC20(state.token0).balanceOf(address(this));
        state.pre1 = IERC20(state.token1).balanceOf(address(this));

        // collect fees
        (state.amount0, state.amount1) = nonfungiblePositionManager.collect(INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max));

        // Claim mode (fork addition): no compound. 10% of the collected fees is taken as the fee and the
        // rest is paid to the owner. Principal (liquidity) is not touched.
        if (claimOnly) {
            // Fee base = everything collected here. The owed amounts were paid to the owner at entry
            // (above), so the collected amount is only newly accrued fees.
            state.amount0Fees = state.amount0.mul(totalRewardX64).div(Q64);
            state.amount1Fees = state.amount1.mul(totalRewardX64).div(Q64);
            if (state.amount0.sub(state.amount0Fees) > 0) {
                SafeERC20.safeTransfer(IERC20(state.token0), from, state.amount0.sub(state.amount0Fees));
            }
            if (state.amount1.sub(state.amount1Fees) > 0) {
                SafeERC20.safeTransfer(IERC20(state.token1), from, state.amount1.sub(state.amount1Fees));
            }
            _payFee(state.token0, state.amount0Fees);
            _payFee(state.token1, state.amount1Fees);
            // Claim mode ends with the same closing balance check as a compound, so a token that
            // delivers less than reported can never be topped up from tokens held by the contract.
            require(IERC20(state.token0).balanceOf(address(this)) == state.pre0, "balance0 invariant");
            require(IERC20(state.token1).balanceOf(address(this)) == state.pre1, "balance1 invariant");
            emit AutoCompounded(from, tokenId, 0, 0, state.amount0Fees, state.amount1Fees, state.token0, state.token1);
            return;
        }

        // only if there are balances to work with - start autocompounding process
        if (state.amount0 > 0 || state.amount1 > 0) {

            SwapParams memory swapParams = SwapParams(
                state.token0,
                state.token1,
                state.fee,
                state.tickLower,
                state.tickUpper,
                state.amount0,
                state.amount1,
                block.timestamp
            );

            // Price check before compounding. While the pool's own TWAP, the outside price or a reference
            // price is usable, a pool price outside its band reverts the compound; with none of them the
            // compound runs without a price check and without a swap. The check is a precondition for the
            // whole compound, not only for the swap: `increaseLiquidity(amount0Min=0, amount1Min=0)` is
            // itself priced, since liquidity is minted at the current pool price, so the add carries the
            // same risk even when no swap is needed. A revert also undoes the `collect`; the position and
            // tokens are untouched and the owner can retry later.
            // Claim mode has no price check: it uses no price (collect, fee, pay out).
            (state.anchorSrc, state.floorSqrtP, state.floorMaxDev, state.xAnchorSqrtP, state.xAnchorGate) =
                _requireUnmanipulated(state.token0, state.token1, state.fee, state.refSqrtP);
            if (state.floorSqrtP != 0) {
                (, state.tickAtGate, , , , , ) =
                    IUniswapV3Pool(factory.getPool(state.token0, state.token1, state.fee)).slot0();
            }
            if (state.anchorSrc == SRC_NONE) emit CompoundedWithoutAnchor(tokenId);
            else if (state.anchorSrc == SRC_CALLER) emit CompoundedWithCallerReference(tokenId, state.refSqrtP);

            // The swap minimum comes from the source the price check used (own TWAP, outside price or
            // the owner's reference price).
            if (doSwap && state.floorSqrtP != 0) {
                (state.amount0, state.amount1) = _swapToPriceRatio(
                    swapParams, slippageBps, state.floorSqrtP, state.floorMaxDev, state.xAnchorSqrtP, state.xAnchorGate
                );
            }
            // `increaseLiquidity` (minimums 0/0) mints at the price after the swap, so the price the mint
            // will see goes through the check again (a failure reverts). Our own swap already stops at the
            // band edge (`_gateEdgeLimit`; the narrower of both bands when the outside price is also used
            // in step 1), so this check only reverts on an unexpected price move (or an error). If the
            // tick has not changed since the check, the check's own result stands (the outside price's
            // sqrt and tick can differ by one; in that case the swap is skipped and the compound runs
            // without a swap).
            if (state.floorSqrtP != 0) {
                (, int24 tNow, , , , , ) =
                    IUniswapV3Pool(factory.getPool(state.token0, state.token1, state.fee)).slot0();
                if (tNow != state.tickAtGate) {
                    require(_withinTicks(state.floorSqrtP, tNow, state.floorMaxDev), "price err");
                    // If an outside price was usable in step 1, the mint price must be inside its band too.
                    if (state.xAnchorGate != 0) {
                        require(_withinTicks(state.xAnchorSqrtP, tNow, state.xAnchorGate), "price err");
                    }
                }
            }

            state.maxAddAmount0 = state.amount0.mul(Q64).div(uint(totalRewardX64).add(Q64));
            state.maxAddAmount1 = state.amount1.mul(Q64).div(uint(totalRewardX64).add(Q64));

            // deposit liquidity into tokenId
            // One-sided fees with a skipped swap can give zero liquidity for an in-range position, which
            // would fail with an unclear error at `require(amount > 0)` in `UniswapV3Pool.mint`. Stop with
            // a clear error instead; the revert undoes the `collect`.
            if (state.maxAddAmount0 > 0 || state.maxAddAmount1 > 0) {
                {
                    (uint160 sp_, , , , , , ) =
                        IUniswapV3Pool(factory.getPool(state.token0, state.token1, state.fee)).slot0();
                    require(
                        LiquidityAmounts.getLiquidityForAmounts(
                            sp_,
                            TickMath.getSqrtRatioAtTick(state.tickLower),
                            TickMath.getSqrtRatioAtTick(state.tickUpper),
                            state.maxAddAmount0,
                            state.maxAddAmount1
                        ) > 0,
                        "nothing to compound"
                    );
                }

                if (state.maxAddAmount0 > 0) {
                    SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), state.maxAddAmount0);
                }
                if (state.maxAddAmount1 > 0) {
                    SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), state.maxAddAmount1);
                }

                (, state.compounded0, state.compounded1) = nonfungiblePositionManager.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams(
                        tokenId,
                        state.maxAddAmount0,
                        state.maxAddAmount1,
                        0,
                        0,
                        block.timestamp
                    )
                );

                if (state.maxAddAmount0 > 0) {
                    SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), 0);
                }
                if (state.maxAddAmount1 > 0) {
                    SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), 0);
                }

                // After a compound with a swap, `tokensOwed` can be non-zero: it is the LP fee that our own
                // rebalancing swap paid to this position's liquidity, which `increaseLiquidity` records in
                // `tokensOwed`. This small amount is collected straight to the owner, so the next compound
                // starts clean. The contract balance does not change and the closing balance checks still
                // hold. It cannot be principal: there is no `decreaseLiquidity` in this call.
                {
                    (, , , , , , , , , , uint128 owedAfter0, uint128 owedAfter1) = nonfungiblePositionManager.positions(tokenId);
                    if (owedAfter0 > 0 || owedAfter1 > 0) {
                        nonfungiblePositionManager.collect(
                            INonfungiblePositionManager.CollectParams(tokenId, from, type(uint128).max, type(uint128).max)
                        );
                    }
                }

                // Fee base = the amounts actually added. The entry collect paid the owed amounts to the
                // owner, so no principal can be included here, and no exemption is applied to balances
                // after the swap.
                state.amount0Fees = state.compounded0.mul(totalRewardX64).div(Q64);
                state.amount1Fees = state.compounded1.mul(totalRewardX64).div(Q64);
            }

            // return remaining tokens to owner
            // Leftovers come from the real balance difference. The position manager and SwapRouter02 `pay()`
            // pay WETH from their own ETH balance first, so while they hold ETH the reported amounts
            // (`compounded`, the swap input) can be larger than what was actually pulled from this contract.
            // The fee base is still `compounded` (the reported amount added);
            // leftover = balance - entry balance - fee.
            {
                uint256 left0 = IERC20(state.token0).balanceOf(address(this)).sub(state.pre0).sub(state.amount0Fees);
                uint256 left1 = IERC20(state.token1).balanceOf(address(this)).sub(state.pre1).sub(state.amount1Fees);
                if (left0 > 0) SafeERC20.safeTransfer(IERC20(state.token0), from, left0);
                if (left1 > 0) SafeERC20.safeTransfer(IERC20(state.token1), from, left1);
            }

            // the fee goes to the fee recipient right away; nothing accumulates in the contract
            _payFee(state.token0, state.amount0Fees);
            _payFee(state.token1, state.amount1Fees);
        }

        // Closing balance check: the contract ends with exactly the balances it had at entry, no more
        // and no less. This enforces V4Utils' "It does not hold any ERC20 or NFTs" rule on chain; it is
        // the same rule as in `GoatAutoCompoundV3`.
        require(IERC20(state.token0).balanceOf(address(this)) == state.pre0, "balance0 invariant");
        require(IERC20(state.token1).balanceOf(address(this)) == state.pre1, "balance1 invariant");

        emit AutoCompounded(from, tokenId, state.compounded0, state.compounded1, state.amount0Fees, state.amount1Fees, state.token0, state.token1);
    }

    /// @dev Swap minimum: the fair output at the sqrt price of the source the price check used
    /// (`floorSqrtP`: own TWAP, outside price or the owner's reference price), computed in two
    /// `FullMath.mulDiv` steps, net of the LP fee, times (10000 - bps) / 10000. A rounded priceX96
    /// is not used. The minimum is not given to the router (partial fills): `_swapSingle` enforces it
    /// on the real balance change, pro rata to the amount spent. The frontend therefore does not need
    /// to know the swap amount. The 5% default applies only to empty data (the entry sets 500); an
    /// explicit 0 is rejected for a compound with a swap.
    /// The upper limit is 20%: a looser tolerance would make the protection meaningless.
    /// @dev Deducts the pool's static LP fee from a fair output. The swap pays this fee to LPs; a
    /// minimum computed from the fee-free fair output made swaps with a low tolerance revert
    /// needlessly. Counterpart in v4: `GoatV4Compoundor._netOfLpFee`.
    function _netOfLpFee(uint256 x, uint24 fee_) internal pure returns (uint256) {
        return FullMath.mulDiv(x, uint256(1000000).sub(uint256(fee_)), 1000000);
    }

    /// Applies the slippage tolerance in bps. bps = 0 is not mapped to 5% here: the entry
    /// (`onERC721Received`) sets 500 for empty data and rejects an explicit 0 for a compound with a
    /// swap. The range is checked again here as a second line of defense.
    function _minOut(uint256 fairOut, uint256 bps) internal pure returns (uint256) {
        require(bps != 0 && bps <= 2000, "slippage too high");
        return fairOut.mul(uint256(10000).sub(bps)).div(10000);
    }



    function _getTWAPTick(IUniswapV3Pool pool, uint32 twapPeriod) internal view returns (int24, bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0; // now
        secondsAgos[1] = twapPeriod; // start of the window
        // pool observe may fail when there is not enough history available
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            // Round negative ticks down. Solidity division truncates toward zero, while Uniswap's
            // `OracleLibrary.consult` rounds negative values down. Pools with negative ticks (for
            // example WETH/USDG on Robinhood Chain) take this branch all the time. Same rounding as
            // `GoatPriceAnchor`.
            int56 delta = tickCumulatives[0] - tickCumulatives[1];
            int56 window = int56(twapPeriod);
            int24 t = int24(delta / window);
            if (delta < 0 && delta % window != 0) t--;
            return (t, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev True when the pool's own TWAP can be trusted for the price check. If the window holds no real
    /// observation, `observe()` extrapolates both ends with the current tick; (cum0 - cum1) / period
    /// then equals the spot tick exactly and the deviation check compares the spot price with itself.
    /// That happens when the pool has not traded for TWAPSeconds, which is common on thin pools.
    /// The rule enforced is stricter than W: the latest observation must be at most MAX_STALENESS
    /// (180 s) old. See `MAX_STALENESS`: the `now` end of `observe` is extrapolated with the current
    /// tick, so the spot price weighs A / W in the TWAP, and A <= W / 10 limits that weight to 10%.
    /// When this returns false, step 1 is skipped and the outside price, the reference price or the
    /// no-swap path is used instead.
    function _twapWindowHasObservation(IUniswapV3Pool pool) internal view returns (bool) {
        (, , uint16 obsIndex, uint16 card, , , ) = pool.slot0();
        if (card == 0) return false;
        (uint32 lastTs, , , bool init) = pool.observations(obsIndex);
        if (!init) return false;
        uint32 nowTs = uint32(block.timestamp);
        if (lastTs > nowTs) return false; // unexpected clock state: treat as stale
        return nowTs - lastTs <= MAX_STALENESS;
    }

    /**
     * @dev Precondition for a compound, enforced while a price source is available.
     *
     * Design:
     *  1) Skipping only the swap when the price check fails, but still adding the liquidity, would not
     *     be enough: `increaseLiquidity(amount0Min=0, amount1Min=0)` is itself priced, since liquidity is
     *     minted at the current pool price. The check is therefore a precondition for the whole compound,
     *     not part of the swap path (doSwap = false is covered too).
     *  2) Rejecting every compound without a price source would block the product: many pools on
     *     Robinhood Chain, such as those of stock tokens, often have no fresh observation, so compounds
     *     would only work on the deepest pairs.
     *
     * Rule: enforce the check while a source is usable, otherwise compound without it. A pool price that
     * has moved away from a usable source is rejected, and pairs with no usable source still compound.
     * The risk accepted there is limited to the fees: relative to an undisturbed compound, the loss is at
     * most the fees collected in that compound, and principal is never withdrawn. For pairs without an
     * outside price and a fee tier of 500 (0.05%) or lower, claim mode is recommended; this contract is only
     * triggered by the NFT owner (there is no keeper), and the frontend selects claim mode
     * (claimOnly = true) for these pairs by default. This branch is only reached when the pool's own
     * TWAP is not usable; the real remedy is to grow that pool's observation buffer
     * (`increaseObservationCardinalityNext`, callable by anyone).
     * The outside price (step 2) comes only from Chainlink or from a pool the anchor owner assigned
     * with a 24 hour delay (`GoatPriceAnchor`); the factory is not scanned.
     * The no-check path is also used when a source exists but is not usable at the moment.
     */
    /// @return src price source used (SRC_*)
    /// @return floorSqrtP sqrt price the swap minimum is based on (0 = no swap)
    /// @return maxDev allowed deviation for that source, in ticks
    /// @return xSqrtP in step 1 (own TWAP), the sqrt price of an outside price that is usable as well (0 = none);
    ///         the swap limit and the check after the swap respect its band too
    /// @return xGate band of that outside price (`_anchorGateTicks(fee)`)
    function _requireUnmanipulated(address token0_, address token1_, uint24 fee_, uint160 refSqrtP)
        internal
        view
        returns (uint8 src, uint160 floorSqrtP, uint32 maxDev, uint160 xSqrtP, uint32 xGate)
    {
        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(token0_, token1_, fee_));
        if (address(pool) == address(0)) return (SRC_NONE, 0, 0, 0, 0);        // no pool for the position (cannot happen)
        (, int24 tick, , , , , ) = pool.slot0();

        // 1) Primary: the pool's own TWAP, if its latest observation is fresh.
        if (_twapWindowHasObservation(pool)) {
            (int24 twapTick, bool ok) = _getTWAPTick(pool, TWAPSeconds);
            if (ok) {
                _requireMaxTickDifference(tick, twapTick, maxTWAPTickDifference);
                // A fresh own TWAP does not override the outside price: if the outside price (for example
                // Chainlink) is usable, the spot price must also be inside its band (a failure reverts).
                // Known cost: when a stock price feed is paused, for example over a weekend, and the
                // market moves further from it than the band, compounds on those pairs revert until the
                // feed resumes (claim mode still works).
                // The outside price (sqrt, band) is returned as well: the swap limit uses the narrower of
                // the two bands, and the check after the swap applies both.
                (xSqrtP, xGate) = _ownTwapAnchorBand(pool, token0_, token1_, fee_, tick);
                return (SRC_OWN_TWAP, TickMath.getSqrtRatioAtTick(twapTick), maxTWAPTickDifference, xSqrtP, xGate);
            }
        }

        /**
         * 2) The pool's own observation is stale or its TWAP cannot be computed: fall back to the outside
         * price from `priceAnchor`, a stronger reference.
         */
        (bool aOk, uint160 aSqrt, int24 anchorTick) = _anchorFor(pool, token0_, token1_);
        if (aOk) {
            uint32 gate = _anchorGateTicks(fee_);
            _requireMaxTickDifference(tick, anchorTick, gate);
            return (SRC_ANCHOR, aSqrt, gate, 0, 0); // the swap minimum already uses the outside price
        }

        /**
         * 3b) If the caller supplied a reference price computed off-chain (the optional fifth field of
         *     the NFT data), the price check and the swap minimum use it. A price fixed before the
         *     transaction cannot be moved by trades inside it. The reference is a sqrtPriceX96 in the
         *     pool's own direction (token1/token0). Without a reference, the compound runs without a swap.
         */
        if (refSqrtP != 0) {
            require(refSqrtP >= TickMath.MIN_SQRT_RATIO && refSqrtP < TickMath.MAX_SQRT_RATIO, "bad reference");
            uint32 gate3 = _anchorGateTicks(fee_);
            require(_withinTicks(refSqrtP, tick, gate3), "price err");
            // If a TWAP of the pool can still be computed (even from a stale observation, as long as the
            // `observe` history covers the window), the reference must also be inside its band. A TWAP
            // stays close to the longer-term price, so a reference equal to a recently moved spot price
            // is rejected here, while a correct reference derived from the same pool's history passes.
            // When `observe` cannot be computed at all (low cardinality), this extra check is skipped.
            {
                (int24 anyTwapTick, bool twapComputable) = _getTWAPTick(pool, TWAPSeconds);
                if (twapComputable) require(_withinTicks(refSqrtP, anyTwapTick, gate3), "price err");
            }
            return (SRC_CALLER, refSqrtP, gate3, 0, 0);
        }

        /**
         * 3) No usable source: compound without a price check and without a swap. This also applies when
         *    a source exists but is not usable right now, so a pair cannot be blocked by its price source.
         *    In v3 this branch is only reached when the pool's own TWAP is not usable, for one of two reasons:
         *     (i)  the pool has not traded for longer than MAX_STALENESS. v3 writes an observation on
         *          every tick change, so the spot price has not moved during that time;
         *     (ii) the observation is fresh but the TWAP cannot be computed (low cardinality). The spot
         *          price is then not checked.
         *    Both conditions can also be caused deliberately, so the spot price here counts as unchecked.
         *    In both cases the risk is limited to the fees (no swap, principal is never withdrawn).
         */
        return (SRC_NONE, 0, 0, 0, 0);
    }

    /// @dev Outside price cross-check and swap band for step 1 (own TWAP). If the outside price is usable,
    /// the spot price must be within `_anchorGateTicks(fee)` of it (otherwise "price err"); returns (sqrt, band), or (0, 0).
    function _ownTwapAnchorBand(IUniswapV3Pool pool, address token0_, address token1_, uint24 fee_, int24 tick)
        internal
        view
        returns (uint160 xSqrtP, uint32 xGate)
    {
        (bool aOk, uint160 aSqrt, int24 aTick) = _anchorFor(pool, token0_, token1_);
        if (!aOk) return (0, 0);
        xGate = _anchorGateTicks(fee_);
        _requireMaxTickDifference(tick, aTick, xGate);
        xSqrtP = aSqrt;
    }

    /// @dev Outside price for the pair. A price taken from the position's own pool is not an independent
    /// reference: if the anchor's assigned v3 pool (`poolFor`) is this pool and the answer does not come
    /// from Chainlink (`anchor()` tries Chainlink first), the band check would compare the pool with itself.
    /// Such an answer counts as unusable (ok = false).
    /// For an anchor that does not implement `poolFor` / `chainlinkAnchor` (such as a mock; the production
    /// anchor is the immutable `GoatPriceAnchor`, which implements both) the assigned pool counts as none.
    /// Only the NFT owner calls this contract, for their own position, so a failing `try` only affects that call.
    function _anchorFor(IUniswapV3Pool pool, address token0_, address token1_)
        internal
        view
        returns (bool ok, uint160 sqrtP, int24 aTick)
    {
        (ok, sqrtP, aTick) = priceAnchor.anchor(token0_, token1_);
        if (!ok) return (false, 0, 0);
        address src;
        try IAnchorPoolForGSC(address(priceAnchor)).poolFor(token0_, token1_) returns (address p_, uint128) {
            src = p_;
        } catch {}
        if (src != address(pool)) return (ok, sqrtP, aTick);
        bool clOk;
        try IAnchorPoolForGSC(address(priceAnchor)).chainlinkAnchor(token0_, token1_) returns (bool o_, uint160, int24) {
            clOk = o_;
        } catch {}
        if (!clOk) return (false, 0, 0);
    }

    /// @dev Band for step 2 (outside price), by fee tier: max(100, fee in bps + 50) ticks.
    /// A pool can drift from the outside price by up to its own fee before arbitrage pays; the extra 50
    /// covers the 0.5% deviation threshold of Chainlink feeds. Among v3 fee tiers only the 1% tier changes
    /// (150). Step 1 (the pool's own TWAP) is unchanged: there the pool is compared with itself.
    /// Counterpart in v4: `GoatV4Compoundor._gateTicks`.
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

    function _anchorGateTicks(uint24 fee_) internal pure returns (uint32) {
        uint32 band = uint32(fee_ / 100) + ANCHOR_FEED_LAG_TICKS;
        if (band <= maxTWAPTickDifference) return maxTWAPTickDifference;
        return band > ANCHOR_MAX_GATE_TICKS ? ANCHOR_MAX_GATE_TICKS : band;
    }

    function _requireMaxTickDifference(int24 tick, int24 other, uint32 maxDifference) internal pure {
        require(other > tick && (uint48(other - tick) < maxDifference) || other <= tick && (uint48(tick - other) < maxDifference), "price err");
    }

    // state used during swap execution
    struct SwapState {
        uint256 positionAmount0;
        uint256 positionAmount1;
        int24 tick;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        // spot price: used only to size the swap (ratio). The swap minimum is not based on it.
        uint256 priceX96;
        uint256 delta0; // sell0: token0 amount to sell
        uint256 delta1; // !sell0: token1 amount to sell
        bool sell0;
        // swap limit, minimum and measured result
        uint160 lim; // price limit at the band edge
        uint256 minOut; // minimum output for a full fill (pro rata for a partial fill)
        uint256 spent; // input spent (real balance difference)
        uint256 out; // output received (real balance difference)
    }

    struct SwapParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 deadline;
    }

    // swaps to the position ratio at the spot price, with a minimum output based on the checked price
    /// @param xSqrtP / xGate: in step 1, an outside price that is usable as well (xGate = 0: none). The swap's
    ///        end price then also stays inside that band; if the spot price is outside it, there is no swap.
    function _swapToPriceRatio(SwapParams memory params, uint256 slippageBps, uint160 floorSqrtP, uint32 maxDev, uint160 xSqrtP, uint32 xGate)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        SwapState memory state;

        amount0 = params.amount0;
        amount1 = params.amount1;

        // get price
        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(params.token0, params.token1, params.fee));

        (state.sqrtPriceX96,state.tick,,,,,) = pool.slot0();

        // The reference price comes from the price check (`_requireUnmanipulated`): own TWAP, outside
        // price or the owner's reference price, whichever was used.
        if (floorSqrtP == 0) {
            return (amount0, amount1);
        }
        // Already checked by the price check; repeated so this function also holds on its own.
        if (!_withinTicks(floorSqrtP, state.tick, maxDev)) {
            return (amount0, amount1);
        }
        // If the outside price's sqrt is not inside its band around the spot (its tick can differ by
        // one), the limit is undefined: no swap.
        if (xGate != 0 && !_withinTicks(xSqrtP, state.tick, xGate)) {
            return (amount0, amount1);
        }

        // `sqrt * sqrt` can overflow uint256; FullMath uses a 512-bit intermediate.
        state.priceX96 = FullMath.mulDiv(uint256(state.sqrtPriceX96), uint256(state.sqrtPriceX96), Q96);
        // Below sqrtP = 2^48 the spot priceX96 rounds down to 0 and the ratio cannot be computed: no swap.
        if (state.priceX96 == 0) {
            return (amount0, amount1);
        }

        // calculate ideal position amounts
        state.sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(params.tickLower);
        state.sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(params.tickUpper);
        (state.positionAmount0, state.positionAmount1) = LiquidityAmounts.getAmountsForLiquidity(
                                                            state.sqrtPriceX96,
                                                            state.sqrtPriceX96Lower,
                                                            state.sqrtPriceX96Upper,
                                                            Q96); // dummy value we just need ratio

        // Swap sizing without an intermediate ratio value (same derivation as `_swapToRatio` in
        // GoatV4Compoundor). A ratio such as `pos0 * Q96 / pos1` blows up when the spot price is very
        // close to the lower tick (pos1 ~ 1), and multiplying it by priceX96 could overflow.
        // R = pos0/pos1, P = priceX96/Q96:
        //   sell0: delta0 = (amount0 - R*amount1) / (1 + R*P)
        //   sell1: delta1 = (amount1 - amount0/R) / (1 + 1/(R*P))   (delta1 computed directly)
        if (state.positionAmount0 == 0) {
            state.delta0 = amount0;
            state.sell0 = true;
        } else if (state.positionAmount1 == 0) {
            state.delta1 = amount1;
            state.sell0 = false;
        } else {
            // `amount1 * pos0 / pos1` may not fit in uint256 (spot price just above sqrtLower and a large
            // amount1). If floor(pos0/pos1) >= floor(MAX/amount1), the product is > MAX - amount1 >= amount0
            // (collected fees fit in uint128), so the excess is certainly in token1: use MAX without
            // calling mulDiv (same direction, no revert).
            uint256 wanted0 = (amount1 != 0 && state.positionAmount0 / state.positionAmount1 >= type(uint256).max / amount1)
                ? type(uint256).max
                : FullMath.mulDiv(amount1, state.positionAmount0, state.positionAmount1); // R*amount1
            state.sell0 = amount0 > wanted0;
            if (state.sell0) {
                state.delta0 = FullMath.mulDiv(
                    amount0 - wanted0,
                    Q96,
                    uint256(Q96).add(FullMath.mulDiv(state.positionAmount0, state.priceX96, state.positionAmount1))
                );
            } else {
                uint256 wanted1 = FullMath.mulDiv(amount0, state.positionAmount1, state.positionAmount0); // amount0/R
                if (amount1 <= wanted1) return (amount0, amount1); // already at the ratio
                uint256 rp = FullMath.mulDiv(state.positionAmount0, state.priceX96, state.positionAmount1); // R*P*Q96
                if (rp == 0) return (amount0, amount1);
                state.delta1 = FullMath.mulDiv(amount1 - wanted1, Q96, uint256(Q96).add(FullMath.mulDiv(Q96, Q96, rp)));
            }
        }

        // Our own swap cannot leave the price check's band. The price limit is within one tick of the
        // edge of the band around the reference price; on a partial fill the minimum is pro rata and
        // the rest is returned.
        state.lim = _gateEdgeLimit(floorSqrtP, state.tick, maxDev, state.sell0);
        // With an outside price as well, the narrower of the two limits applies (zeroForOne lowers the
        // price -> the larger limit; the other direction -> the smaller one).
        if (xGate != 0) {
            uint160 xLim = _gateEdgeLimit(xSqrtP, state.tick, xGate, state.sell0);
            if (state.sell0 ? xLim > state.lim : xLim < state.lim) state.lim = xLim;
        }
        if (state.sell0 ? state.sqrtPriceX96 <= state.lim : state.sqrtPriceX96 >= state.lim) {
            return (amount0, amount1);
        }

        // Fair output from the checked sqrt price, in two steps (no rounded priceX96). If the minimum
        // comes out as 0, no unprotected swap is made.
        if (state.sell0) {
            if (state.delta0 == 0 || state.delta0 > amount0) return (amount0, amount1);
            state.minOut = _minOut(
                _netOfLpFee(FullMath.mulDiv(FullMath.mulDiv(state.delta0, floorSqrtP, Q96), floorSqrtP, Q96), params.fee),
                slippageBps
            );
            if (state.minOut == 0) return (amount0, amount1);
            _swapSingle(params, state, true, state.delta0);
            amount0 = amount0.sub(state.spent);
            amount1 = amount1.add(state.out);
        } else {
            if (state.delta1 == 0 || state.delta1 > amount1) return (amount0, amount1);
            state.minOut = _minOut(
                _netOfLpFee(FullMath.mulDiv(FullMath.mulDiv(state.delta1, Q96, floorSqrtP), Q96, floorSqrtP), params.fee),
                slippageBps
            );
            if (state.minOut == 0) return (amount0, amount1);
            _swapSingle(params, state, false, state.delta1);
            amount1 = amount1.sub(state.spent);
            amount0 = amount0.add(state.out);
        }
    }

    /// @dev Price limit at the edge of the band. floorTick = the largest t with sqrtAt(t) <= floorSqrtP,
    /// searched within the band the price check already confirmed (`_withinTicks(floor, spotTick, maxDev)` <=>
    /// floorTick in [spot-maxDev+1, spot+maxDev-1]). The limit keeps the end tick e inside
    /// [floorTick-maxDev+1, floorTick+maxDev-1], so `_withinTicks(floor, e, maxDev)` holds after the swap.
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

    /// @dev Single-hop exact-input swap with a price limit. On a partial fill the minimum is kept per
    /// unit (it scales linearly with amountIn), so the router's own minimum is 0 and the check is done
    /// here. Spent and received amounts are measured from real balance differences: when the router pays
    /// WETH from its own ETH, the reported input was not pulled from this contract.
    function _swapSingle(SwapParams memory params, SwapState memory state, bool zeroForOne, uint256 amountIn) internal {
        address tokenIn = zeroForOne ? params.token0 : params.token1;
        address tokenOut = zeroForOne ? params.token1 : params.token0;
        uint256 bIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 bOut = IERC20(tokenOut).balanceOf(address(this));
        SafeERC20.safeApprove(IERC20(tokenIn), address(swapRouter), amountIn);
        IV3RouterSingleForGSC(address(swapRouter)).exactInputSingle(
            IV3RouterSingleForGSC.ExactInputSingleParams(
                tokenIn, tokenOut, params.fee, address(this), amountIn, 0, state.lim
            )
        );
        SafeERC20.safeApprove(IERC20(tokenIn), address(swapRouter), 0);
        state.spent = bIn.sub(IERC20(tokenIn).balanceOf(address(this)));
        state.out = IERC20(tokenOut).balanceOf(address(this)).sub(bOut);
        require(state.spent <= amountIn, "overspent");
        uint256 floor_ = state.spent == amountIn
            ? state.minOut
            : FullMath.mulDivRoundingUp(state.minOut, state.spent, amountIn);
        require(state.out >= floor_, "Too little received");
    }

    /// @notice Disabled. Without an owner, `feeRecipient` and the recovery functions would be frozen for good.
    /// An accidental call could not be undone; ownership moves with `transferOwnership` + `acceptOwnership`.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }
}
