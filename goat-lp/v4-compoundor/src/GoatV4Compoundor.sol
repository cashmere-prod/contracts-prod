// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// MIT copy of the v4-core test helper, so that production code does not import test utilities.
import {CurrencySettler} from "./GoatCurrencySettler.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
// MIT replacement for the v4-core test helper, whose licence identifier is UNLICENSED.
import {GoatLiquidityAmounts as LiquidityAmounts} from "./GoatLiquidityAmounts.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @dev Uniswap v4 has no oracle (v4-core has no `observe()`), so the outside price comes from a separate contract,
/// `GoatPriceAnchor`: a Chainlink price, or the TWAP of the Uniswap v3 pool assigned to the pair.
interface IGoatPriceAnchor {
    function anchor(address tokenA, address tokenB)
        external view returns (bool ok, uint160 sqrtPriceX96, int24 tick);
    function hasSource(address tokenA, address tokenB) external view returns (bool);
    /// @notice v4 native ETH maps to this address; also used for the WETH fallback in `_refund`.
    function weth() external view returns (address);
}

interface IWeth9 {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Public immutables of the v4-periphery PositionManager (Permit2Forwarder.permit2, NativeWrapper.WETH9),
/// read by the constructor to check the deployment.
interface IPosmDeps {
    function permit2() external view returns (address);
    function WETH9() external view returns (address);
}

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @notice GoatV4Compoundor: one-click compound for Uniswap v4 positions, with a 10% fee on what is added back.
 *         The owner sends the position NFT here; the contract collects the fees, adds them back as liquidity,
 *         forwards the fee (10% of the amount compounded; in claim mode 10% of the amount collected) to
 *         `feeRecipient` in the same transaction, and returns the rest and the NFT to the owner in that same
 *         transaction. Nothing is kept in the contract.
 *
 *         Fee recipient: the owner can change `feeRecipient` (`setFeeRecipient`, which emits
 *         `FeeRecipientChanged`; zero, this contract and changes during an ownership handover are rejected).
 *         A native fee is sent with 100,000 gas and wrapped to WETH if the recipient reverts or runs out of gas,
 *         so the compound still goes through. If an ERC20 or WETH transfer to the recipient reverts, the whole
 *         transaction reverts: the NFT stays with its owner, nothing is lost, and compounding in that token
 *         waits until the owner changes the recipient.
 *
 *         Subscribers: sending the NFT here ends the position's v4 `subscriber` link (PositionManager
 *         unsubscribes on transfer), and this contract cannot see that afterwards. The app reads `positionInfo`
 *         bit 0 and warns before sending such a position; `GoatAutoCompoundV4` rejects it.
 *
 * @dev Written from scratch, since Revert Finance's V4Utils is BUSL. Dependencies are MIT only: v4-core and
 *      v4-periphery primitives, the Permit2 interface, OpenZeppelin (Ownable2Step, ReentrancyGuard,
 *      SafeERC20, Math) and the MIT copies `GoatCurrencySettler` and `GoatLiquidityAmounts`. Robinhood's
 *      canonical v4 pool hook has the before-swap flag but no add or remove liquidity flags, so collect and
 *      increase never call it; in other pools the hook is untrusted code (see the note below). With an anchor,
 *      or a caller reference, a rebalancing swap runs in the position's own pool (`_swapToRatio`) and does call
 *      that pool's hook. When spot is inside the gate but on the unfavourable side of the anchor, the swap is
 *      skipped.
 *
 *      One-sided fees: when no swap is possible (no anchor, unfavourable spot, pool fee above 10%) and the
 *      liquidity to add is 0, the call reverts with `NothingToCompound` rather than handing the collected fees
 *      back free of charge; the owner can use claim mode or collect on Uniswap. On a partial match the unmatched
 *      remainder is returned without a fee.
 *
 *      Fee math, the same 10% as the v3 compound contracts: maxAdd = amount * Q64 / (reward + Q64), about
 *      amount / 1.1 (90.9%). The fee base is the position's liquidity increase, converted to amounts at the same
 *      `sqrtP` and capped at maxAdd, not the balance change: fee = compounded * reward / Q64, 10% of the amount
 *      compounded, sent to `feeRecipient` in the same transaction and never more than what is left.
 */
/// @dev Hooks: the owner picks the position, so `key.hooks` may be untrusted code, and it is called during collect,
/// increase and swap. Hooks are not allowlisted here, since that would exclude legitimate pools and the invariants
/// do not depend on the hook behaving:
///   1. The contract ends every call holding nothing; all payouts are its own transfers, not under hook control.
///   2. The fee is 10% of the measured amount compounded, capped at maxAdd; a hook can only make it smaller.
///   3. The Permit2 approval is for the exact amount, expires with the current block and names only the
///      PositionManager, so a hook cannot use it.
///   4. Entry is nonReentrant, and if the hook reverts the whole transaction reverts.
/// What remains is limited to the owner's own position and pool.
contract GoatV4Compoundor is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using PositionInfoLibrary for PositionInfo;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    uint256 internal constant Q64 = 2 ** 64;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q192 = 2 ** 192;

    /// Largest allowed distance between spot and anchor (100 ticks, about 1%).
    int24 internal constant MAX_TWAP_TICK_DELTA = 100;

    /**
     * @dev Gate tolerance by fee tier. A pool can sit away from the market by up to its own fee before arbitrage
     * pays, so a fixed 100-tick gate would stop pools whose fee is above 1%. Tolerance = max(100, fee_bps + 50),
     * capped at `MAX_GATE_TICKS`:
     *  - fee_bps = `fee / 100` (1 tick is about 1 bps);
     *  - +50 covers Chainlink's 0.5% deviation threshold, the lag of one feed. A Chainlink anchor is the ratio of
     *    two feeds, so when neither of them is USDG both may lag in opposite directions; the gate can then reject
     *    an honest spot in narrow pools, which only delays the compound;
     *  - the cap, `MAX_GATE_TICKS`, is a 10% fee plus the lag.
     * Pools with a dynamic fee get no widening, because their hook sets the fee.
     */
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;

    /**
     * @dev No rebalancing swap in a pool whose static fee is above this (10%): such a swap would cost the owner
     * more than it adds, and the gate tolerance stops at 1050 ticks (10.5%) anyway. Without the swap only the part
     * that matches the position's ratio is added, and the rest is returned.
     */
    uint24 internal constant MAX_REBALANCE_FEE = 100_000; // 10%
    int24 internal constant FEED_LAG_TICKS = 50;
    int24 internal constant MAX_GATE_TICKS = 1050;

    function _gateTicks(uint24 fee) internal pure returns (int24) {
        if (fee & DYNAMIC_FEE_FLAG != 0) return MAX_TWAP_TICK_DELTA;
        int24 band = int24(uint24(fee / 100)) + FEED_LAG_TICKS;
        if (band <= MAX_TWAP_TICK_DELTA) return MAX_TWAP_TICK_DELTA;
        return band > MAX_GATE_TICKS ? MAX_GATE_TICKS : band;
    }

    // Fee: 10% (Q64 / 10, fits uint64), charged only on the fees added back, never on principal. Since
    // maxAdd = amount / 1.1, a full compound charges about 9.09% of the collected fees, which is exactly 10%
    // of the amount compounded.
    uint64 public constant totalRewardX64 = 1844674407370955161; // = 2**64 / 10 = 10%

    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    IAllowanceTransfer public immutable permit2;
    /// @notice Manipulation-resistant price anchor, needed because v4 has no oracle.
    IGoatPriceAnchor public immutable priceAnchor;

    /// @notice Address that receives the fee, in the same transaction.
    /// @dev Like Revert Finance's V4Utils, the contract holds no tokens or NFTs between calls: the fee leaves in the
    /// same transaction, so no balance builds up here. If this address cannot receive an ERC20 or WETH transfer,
    /// compounding reverts; if it rejects native ETH or uses too much gas, the fee is paid in WETH (`_refund`).
    /// The owner can change it with `setFeeRecipient`.
    address public feeRecipient;

    /// @notice Emitted when `Actions.SWEEP` brings in ETH that someone else left in the PositionManager. Not
    /// protocol revenue: v4-periphery's SWEEP takes the whole native balance, and SWEEP is the only way to get
    /// back unspent `msg.value`. It is made visible by this event and can be recovered with
    /// `emergencyWithdrawBalances`.
    event StrandedNativeSwept(uint256 amount);
    event StrandedNativeWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Running total of ETH of unknown origin that `Actions.SWEEP` brought into this contract. Not protocol
     *         revenue.
     *
     * @dev In v4-periphery `SWEEP` takes the PositionManager's whole native balance, so ETH another user left
     * there arrives together with ours. SWEEP cannot be skipped: an unbalanced position leaves much of
     * `msg.value` unspent, and that ETH belongs to the user.
     *
     * @dev Counting it on chain and emitting an event lets native withdrawals through `emergencyWithdrawBalances`
     * be reconciled. The fee does not depend on this value; its base is the liquidity increase.
     *
     * @dev The counter is a running lower bound and does not match `StrandedNativeWithdrawn` one to one: a
     * withdrawal takes the whole native balance (including ETH sent in directly) and can cover several sweeps.
     * Reconciliation: sum(Withdrawn) >= sum(Swept) - balance.
     */
    uint256 public strandedNativeSwept;

    event AutoCompounded(
        address indexed account,
        uint256 indexed tokenId,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        Currency currency0,
        Currency currency1
    );

    event FeeRecipientChanged(address indexed previous, address indexed next);

    /**
     * @notice This compound ran without an anchor: no swap and no price gate.
     * @dev Monitoring signal. If `priceAnchor.hasSource(c0, c1)` is true in that block, a configured source (a
     * feed or an assigned pool) has gone quiet and needs attention; if false, the pair has no source configured.
     * `hasSource` is not called on chain, to save gas.
     */
    event CompoundedWithoutAnchor(uint256 indexed tokenId);

    /**
     * @notice There was no on-chain anchor; the gate and the swap floor used the caller's reference price
     * (`refSqrtPriceX96`).
     * @dev The reference is computed off chain from recent prices before the transaction is sent, so a price moved
     * afterwards fails the gate. The caller is trusted for it: a poor reference can lose at most the fees
     * collected, and `slippageBps` is measured from the reference, so it gives no protection against a poor one.
     */
    event CompoundedWithCallerReference(uint256 indexed tokenId, uint160 refSqrtPriceX96);

    error NotPositionManager();
    error NothingToCompound();
    error SelfSend();
    error RenounceDisabled();
    error NotPoolManager();
    error SwapSlippage();
    error ZeroFeeRecipient();
    /// @dev feeRecipient cannot be this contract: the closing balance check would block every path that pays a fee.
    error SelfFeeRecipient();
    /// @dev An ownership handover is pending (pendingOwner != 0); the fee recipient cannot change until it completes.
    error HandoverPending();
    /// @dev NFT data must be 0, 64 or 96 bytes long.
    error BadData();
    /// @dev With non-empty data, slippageBps = 0 is invalid in compound mode.
    error SlippageZero();
    /// @dev Inconsistent constructor dependencies: an address without code, or a WETH or Permit2 mismatch.
    error BadDeployment();
    /// @dev The swap deltas have the wrong signs for the swap direction.
    error BadSwapDelta();

    /// @notice Default swap tolerance (5%) for an NFT sent with empty `data`.
    uint256 internal constant DEFAULT_SLIPPAGE_BPS = 500;

    // There is no external router and no caller-supplied calldata: the only swap runs in the position's own pool.

    constructor(
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2,
        IGoatPriceAnchor _priceAnchor,
        address _feeRecipient
    )
        Ownable(msg.sender)
    {
        require(
            address(_positionManager) != address(0) && address(_permit2) != address(0)
                && address(_priceAnchor) != address(0),
            "zero addr"
        );
        if (_feeRecipient == address(0)) revert ZeroFeeRecipient();
        if (_feeRecipient == address(this)) revert SelfFeeRecipient();
        // The anchor and the PositionManager must have code; the anchor's WETH must be the PositionManager's
        // WETH9 (used for the native fallback); and `_permit2`, which receives unlimited token approvals, must be
        // the PositionManager's own Permit2.
        if (address(_priceAnchor).code.length == 0 || address(_positionManager).code.length == 0) {
            revert BadDeployment();
        }
        if (IPosmDeps(address(_positionManager)).permit2() != address(_permit2)) revert BadDeployment();
        if (_priceAnchor.weth() != IPosmDeps(address(_positionManager)).WETH9()) revert BadDeployment();
        positionManager = _positionManager;
        poolManager = _positionManager.poolManager();
        permit2 = _permit2;
        priceAnchor = _priceAnchor;
        feeRecipient = _feeRecipient;
        emit FeeRecipientChanged(address(0), _feeRecipient);
    }

    /// @notice Changes the fee recipient (owner only). It must be able to receive ETH and tokens.
    /// @dev Disabled while an ownership handover is pending, so an outgoing owner cannot redirect the fees; the new
    /// owner sets it after `acceptOwnership`, in the same batch.
    function setFeeRecipient(address next) external onlyOwner nonReentrant {
        if (pendingOwner() != address(0)) revert HandoverPending();
        if (next == address(0)) revert ZeroFeeRecipient();
        if (next == address(this)) revert SelfFeeRecipient();
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    /// @dev Sends the fee to `feeRecipient` straight away; if that fails the whole transaction reverts, so fees
    /// never build up in the contract.
    function _payFee(Currency c, uint256 amount) private {
        /**
         * A native fee goes through the same gas-limited path as `_refund` (100,000 gas, WETH on failure), so the
         * recipient gets no unlimited callback while the NFT is held here. If the WETH transfer fails too, the call
         * reverts. The main protections are `nonReentrant` and the NFT and liquidity checks in `onERC721Received`.
         */
        if (amount > 0) _refund(c, feeRecipient, amount);
    }

    /// @notice Gas limit for native payouts to a recipient's code.
    /// @dev Unlimited gas would let a recipient burn the caller's gas; 100,000 is plenty for contract wallets that
    /// accept ETH.
    uint256 private constant NATIVE_REFUND_GAS = 100_000;

    event NativeRefundFellBackToWeth(address indexed to, uint256 amount);

    /**
     * @dev Pays `to`. ERC20: a plain transfer. Native: a call with `NATIVE_REFUND_GAS`; if the recipient reverts or
     * runs out of gas, the ETH is wrapped and sent as WETH, so a single recipient that cannot take ETH does not
     * block the compound (and the fee) for its position. If the WETH transfer fails as well, the call reverts
     * rather than keep the funds, which the closing balance check would not allow anyway.
     *
     * Robinhood Chain's WETH wraps exactly 1:1. Payouts are pushed because the contract keeps nothing between
     * calls; a pull model (Revert Finance's `accountBalances` and `withdrawBalance`) would need custody.
     */
    function _refund(Currency c, address to, uint256 amount) private {
        if (amount == 0) return;
        if (!c.isAddressZero()) {
            c.transfer(to, amount);
            return;
        }
        (bool ok,) = to.call{value: amount, gas: NATIVE_REFUND_GAS}("");
        if (ok) return;

        address w = priceAnchor.weth();
        IWeth9(w).deposit{value: amount}();
        require(IWeth9(w).transfer(to, amount), "weth refund failed");
        emit NativeRefundFellBackToWeth(to, amount);
    }

    receive() external payable {} // receives native ETH from collect and leftovers

    /**
     * @notice Recovers a position NFT sent with a plain `transferFrom`, which skips `onERC721Received` and would
     * otherwise stay here for good. The normal flow returns every NFT in the same transaction, so an NFT found
     * here was sent by mistake.
     */
    function emergencyWithdrawNFT(uint256 tokenId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        IERC721(address(positionManager)).safeTransferFrom(address(this), to, tokenId);
    }

    /**
     * @notice Recovery (owner only); use currency = address(0) for native ETH.
     * @dev Fees never build up here (each compound or claim forwards them to `feeRecipient`), so this only
     * recovers unexpected leftovers: tokens sent in by others and ETH from a native SWEEP.
     */
    /**
     * @dev Recovers assets sent by mistake. Not part of the normal flow, in which the closing balance check makes
     * every call end with the contract holding nothing.
     *
     * @dev Native withdrawals also emit `StrandedNativeWithdrawn`: that ETH is most likely what
     * `strandedNativeSwept` counted and is not protocol revenue, so the event allows reconciliation.
     */
    function emergencyWithdrawBalances(Currency[] calldata tokens, address to) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        uint256 n = tokens.length;
        for (uint256 i; i < n; ++i) {
            uint256 bal = tokens[i].balanceOfSelf();
            if (bal == 0) continue;
            if (tokens[i].isAddressZero()) emit StrandedNativeWithdrawn(to, bal);
            tokens[i].transfer(to, bal);
        }
    }

    /**
     * @dev Compounds a received v4 position NFT and returns it to its owner in the same transaction.
     */
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        // As in Revert Finance's V4Utils: reject a transfer from this contract itself, whose payout would mix
        // with the contract's own balance.
        if (from == address(this)) revert SelfSend();

        // data: abi.encode(bool claimOnly, uint256 slippageBps)
        //    or abi.encode(bool claimOnly, uint256 slippageBps, uint160 refSqrtPriceX96).
        // slippageBps is the tolerance for the rebalancing swap; the minimum output itself is computed here, from
        // the anchor. refSqrtPriceX96 is an optional reference price computed off chain, used only when there is
        // no on-chain anchor (see `CompoundedWithCallerReference`). Empty data: compound mode with the default
        // tolerance. The 64-byte form works as before. Only 0, 64 or 96 bytes are accepted, since another length
        // could silently drop the reference, and with non-empty data compound mode needs slippageBps > 0; the
        // default applies to empty data only.
        bool claimOnly;
        uint256 slippageBps;
        uint160 refSqrtPriceX96;
        if (data.length == 0) {
            slippageBps = DEFAULT_SLIPPAGE_BPS;
        } else {
            if (data.length == 96) {
                (claimOnly, slippageBps, refSqrtPriceX96) = abi.decode(data, (bool, uint256, uint160));
            } else if (data.length == 64) {
                (claimOnly, slippageBps) = abi.decode(data, (bool, uint256));
            } else {
                revert BadData();
            }
            if (!claimOnly && slippageBps == 0) revert SlippageZero();
        }
        if (refSqrtPriceX96 != 0) {
            require(
                refSqrtPriceX96 >= TickMath.MIN_SQRT_PRICE && refSqrtPriceX96 < TickMath.MAX_SQRT_PRICE,
                "bad reference"
            );
        }
        // Checked at entry, so the same input is rejected whether or not a swap turns out to be needed.
        require(slippageBps <= 2000, "slippage too high");

        uint128 liqAtEntry = positionManager.getPositionLiquidity(tokenId);

        _autoCompound(tokenId, from, claimOnly, slippageBps, refSqrtPriceX96);

        /**
         * The NFT must still be here and its liquidity must not have dropped, whatever ran during the compound;
         * otherwise there is no payout and the whole transaction reverts. Compounding only adds liquidity and
         * claiming never changes it.
         */
        require(IERC721(address(positionManager)).ownerOf(tokenId) == address(this), "nft left mid-flight");
        require(positionManager.getPositionLiquidity(tokenId) >= liqAtEntry, "liquidity decreased");

        // Return the NFT to its owner (the v4 PositionManager is an ERC721).
        IERC721(address(positionManager)).safeTransferFrom(address(this), from, tokenId);

        return this.onERC721Received.selector;
    }

    struct State {
        Currency currency0;
        Currency currency1;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 maxAdd0;
        uint256 maxAdd1;
        uint256 compounded0;
        uint256 compounded1;
        uint256 fee0;
        uint256 fee1;
        // Balances before collect, so that tokens others sent to the contract are not paid out as this owner's fees.
        uint256 pre0;
        uint256 pre1;
        // ETH of others that `Actions.SWEEP` brought in. Used only for the closing balance check, not for the fee.
        uint256 sweptForeignNative;
    }

    function _autoCompound(
        uint256 tokenId,
        address from,
        bool claimOnly,
        uint256 slippageBps,
        uint160 refSqrtPriceX96
    ) internal {
        State memory s;
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        s.currency0 = key.currency0;
        s.currency1 = key.currency1;
        s.tickLower = info.tickLower();
        s.tickUpper = info.tickUpper();

        // This owner's fees = balance after collect - balance before collect. The snapshot keeps tokens that
        // others sent to the contract out of this owner's payout.
        s.pre0 = s.currency0.balanceOfSelf();
        s.pre1 = s.currency1.balanceOfSelf();

        // 1) Collect the fees: decrease liquidity by 0, then TAKE_PAIR to this contract.
        _collect(tokenId, key);

        s.amount0 = s.currency0.balanceOfSelf() - s.pre0;
        s.amount1 = s.currency1.balanceOfSelf() - s.pre1;
        /**
         * Nothing collected: revert with `NothingToCompound`, as the `liq == 0` case below does, so that an empty
         * run fails instead of using up the automation interval.
         */
        if (s.amount0 == 0 && s.amount1 == 0) revert NothingToCompound();

        // 1b) Claim mode: no compound. 10% of the collected fees is the fee and the rest goes to the owner;
        // liquidity is untouched and the NFT is returned.
        if (claimOnly) {
            s.fee0 = (s.amount0 * totalRewardX64) / Q64;
            s.fee1 = (s.amount1 * totalRewardX64) / Q64;
            if (s.amount0 > s.fee0) _refund(s.currency0, from, s.amount0 - s.fee0);
            if (s.amount1 > s.fee1) _refund(s.currency1, from, s.amount1 - s.fee1);
            // the fee goes straight to feeRecipient; nothing builds up here
            _payFee(s.currency0, s.fee0);
            _payFee(s.currency1, s.fee1);
            // claim mode: in = amount_i, out = fee_i + (amount_i - fee_i), so the closing balance is pre_i
            require(s.currency0.balanceOfSelf() == s.pre0, "balance0 invariant");
            require(s.currency1.balanceOfSelf() == s.pre1, "balance1 invariant");
            emit AutoCompounded(from, tokenId, 0, 0, s.fee0, s.fee1, s.currency0, s.currency1);
            return;
        }

        // 2) Rebalance: in range, getLiquidityForAmounts takes the smaller of the two per-token liquidities, so
        // one-sided fees add nothing. Part of the fees is swapped toward the position's ratio, in the position's
        // own pool through the PoolManager: no caller calldata, no external router, no unlimited approval. The
        // minimum output is computed here from the anchor (or the caller's reference); the caller only gives the
        // `slippageBps` tolerance.
        //
        // The price gate is a precondition of the whole compound, not only of the swap, because adding liquidity
        // at a moved price mints at a bad ratio too. With a usable anchor, a spot outside the gate reverts the
        // compound and leaves the position and tokens untouched; without one, the compound runs without a swap at
        // the current spot (see `_requireUnmanipulated`). Claim mode returned above and uses no price.
        /**
         * The anchor is read once and passed on. Nothing between the gate and the swap changes the anchor's
         * sources (the swap is in the v4 pool), so a second read would return the same result.
         */
        (bool okAnchor, uint160 anchorSqrtP, int24 anchorTick, bool fromCaller) =
            _requireUnmanipulated(key, refSqrtPriceX96);
        if (!okAnchor) emit CompoundedWithoutAnchor(tokenId);
        else if (fromCaller) emit CompoundedWithCallerReference(tokenId, refSqrtPriceX96);

        _swapToRatio(key, s, slippageBps, okAnchor, anchorSqrtP, anchorTick);
        s.amount0 = s.currency0.balanceOfSelf() - s.pre0;
        s.amount1 = s.currency1.balanceOfSelf() - s.pre1;

        // 3) Amounts to add, with 10% held back for the fee.
        s.maxAdd0 = (s.amount0 * Q64) / (uint256(totalRewardX64) + Q64);
        s.maxAdd1 = (s.amount1 * Q64) / (uint256(totalRewardX64) + Q64);

        // Approvals come before the `sqrtP` read (see `_approveForIncrease`). The approval is `maxAdd_i`; actual
        // spending is limited by the tighter `cap_i`.
        _approveForIncrease(key, s.maxAdd0, s.maxAdd1);

        {
            (uint160 sqrtP, int24 tickNow,,) = poolManager.getSlot0(key.toId());
            // Gate again at the price the mint is sized at: our own swap (bounded at the gate edge) or a token or
            // hook callback may have moved it since `_requireUnmanipulated`. Without an anchor there is no gate.
            if (okAnchor) {
                int24 devNow = tickNow > anchorTick ? tickNow - anchorTick : anchorTick - tickNow;
                require(devNow < _gateTicks(key.fee), "price manipulated");
            }
            uint160 sqrtLo = TickMath.getSqrtPriceAtTick(s.tickLower);
            uint160 sqrtHi = TickMath.getSqrtPriceAtTick(s.tickUpper);
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLo, sqrtHi, s.maxAdd0, s.maxAdd1);

            // Nothing can be added: revert instead of handing the collected fees back free of charge. The owner can
            // use claim mode or collect on Uniswap. The fee applies only to the part compounded, so with a small
            // match the unmatched rest is returned without a fee; collecting on Uniswap is free anyway.
            if (liq == 0) revert NothingToCompound();

            {
                /**
                 * Fee base: the position's liquidity increase, not the change in this contract's balance. Token and
                 * hook code runs during `_increase` and could move tokens in and out of the contract, so a balance
                 * difference is not a reliable measure; `getPositionLiquidity` is position state that neither can
                 * rewrite.
                 *
                 * The increase is converted back to amounts at the same `sqrtP` that sized `liq` from `maxAdd_i`, so
                 * `used_i <= maxAdd_i` holds and the contract never promises more than it holds.
                 */
                /**
                 * Tight maximums. `PositionManager._increase` checks the principal it takes
                 * (`liquidityDelta - feesAccrued`) against `amount0Max` and `amount1Max`, so the maximums are set to
                 * the amounts needed for `liq` at the same `sqrtP`, plus 1 wei. If the price moves between this read
                 * and the mint (for example in a hook), the pool asks for more than the maximum on one side and the
                 * mint reverts; only a dust-sized shift fits within the 1 wei margin. The fee split therefore follows
                 * the tokens actually used, with no price source needed. This covers moves inside the transaction
                 * only; a price moved before it is the gate's job.
                 *
                 * The margin is 1 wei because the pool rounds up while `getAmountsForLiquidity` rounds down. Each
                 * maximum is capped at `amount_i`, not `maxAdd_i`: on the binding side `need_i` can equal `maxAdd_i`,
                 * and capping there would revert an honest compound by 1 wei.
                 */
                uint256 cap0;
                uint256 cap1;
                {
                    (uint256 need0, uint256 need1) =
                        LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLo, sqrtHi, liq);
                    cap0 = need0 + 1;
                    cap1 = need1 + 1;
                    if (cap0 > s.amount0) cap0 = s.amount0;
                    if (cap1 > s.amount1) cap1 = s.amount1;
                }

                uint128 liqBefore = positionManager.getPositionLiquidity(tokenId);

                // `Actions.SWEEP` takes the PositionManager's whole ETH balance, including ETH left there by others.
                // `_increase` measures that amount right before its call; it is used for accounting only, not the fee.
                s.sweptForeignNative = _increase(tokenId, key, liq, cap0, cap1);

                uint128 liqAfter = positionManager.getPositionLiquidity(tokenId);
                // Revert rather than charge nothing: with `liq > 0` the liquidity must have increased.
                if (liqAfter <= liqBefore) revert NothingToCompound();
                uint128 liqAdded = liqAfter - liqBefore;

                (uint256 used0, uint256 used1) =
                    LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLo, sqrtHi, liqAdded);
                s.compounded0 = used0 > s.maxAdd0 ? s.maxAdd0 : used0;
                s.compounded1 = used1 > s.maxAdd1 ? s.maxAdd1 : used1;
                s.fee0 = (s.compounded0 * totalRewardX64) / Q64;
                s.fee1 = (s.compounded1 * totalRewardX64) / Q64;
            }
        }

        // 4) Return the rest to the owner and send the fee to feeRecipient. left = this owner's part that was not
        // compounded (tokens sent in by others excluded).
        /**
         * The fee and the refund come from different sources on purpose:
         *  - the fee base is the position's liquidity increase, which token or hook code cannot change;
         *  - the refund is everything of this owner's that is actually left in the contract.
         *
         * The refund is not `amount - compounded`: the liquidity-derived `compounded` can slightly exceed what the
         * pool actually took, because `getAmountsForLiquidity` and the pool round differently. Paying from the real
         * balance gives the owner that difference and makes the closing balance check exact.
         */
        uint256 left0 = s.currency0.balanceOfSelf() - s.pre0 - s.sweptForeignNative;
        uint256 left1 = s.currency1.balanceOfSelf() - s.pre1;
        // The fee never exceeds what is left.
        if (s.fee0 > left0) s.fee0 = left0;
        if (s.fee1 > left1) s.fee1 = left1;
        if (left0 > s.fee0) _refund(s.currency0, from, left0 - s.fee0);
        if (left1 > s.fee1) _refund(s.currency1, from, left1 - s.fee1);
        _payFee(s.currency0, s.fee0);
        _payFee(s.currency1, s.fee1);

        /**
         * Closing check, enforced on chain: the contract keeps nothing. `left_i` is everything of this owner's still
         * here, and all of it leaves as refund plus fee, so the closing balance must equal `pre_i` and rounding
         * differences cannot build up.
         *
         * On the native side the ETH that `SWEEP` brought in from others is added to the expected balance
         * (accounting only, not the fee).
         */
        require(s.currency0.balanceOfSelf() == s.pre0 + s.sweptForeignNative, "balance0 invariant");
        require(s.currency1.balanceOfSelf() == s.pre1, "balance1 invariant");
        if (s.sweptForeignNative > 0) {
            strandedNativeSwept += s.sweptForeignNative;
            emit StrandedNativeSwept(s.sweptForeignNative);
        }

        emit AutoCompounded(from, tokenId, s.compounded0, s.compounded1, s.fee0, s.fee1, s.currency0, s.currency1);
    }

    /// @dev Swap floor: (10000 - bps) / 10000 of the fair output at the anchor price, net of the swap fee. bps is
    /// monotonic: 0 means no tolerance (the 5% default applies only to empty data, in `onERC721Received`). The upper
    /// bound is 20%; a looser one would make the floor meaningless.
    /**
     * @dev Deducts the pool's known static LP fee from the fair output. The swap pays that fee to the LPs; without
     * the deduction, a pool whose fee is at or above the tolerance could never meet the floor. A dynamic fee is not
     * deducted, since the hook sets it (the same reason as in `_gateTicks`).
     */
    /// @dev The PoolManager protocol fee for this direction is deducted too (swap fee = protocolFee +
    /// lpFee * (1 - protocolFee); protocolFee is at most 0.1% and only Uniswap governance sets it). A dynamic LP fee
    /// is not deducted, so a hook cannot loosen the floor; where it is too high the swap is skipped (`_swapToRatio`).
    function _netOfLpFee(uint256 x, uint24 fee, uint16 protocolFee) internal pure returns (uint256) {
        uint24 lp = fee & DYNAMIC_FEE_FLAG != 0 ? 0 : fee;
        return _netOfFee(x, protocolFee == 0 ? lp : ProtocolFeeLibrary.calculateSwapFee(protocolFee, lp));
    }

    function _netOfFee(uint256 x, uint24 swapFee) internal pure returns (uint256) {
        if (swapFee >= 1_000_000) return 0;
        return FullMath.mulDiv(x, 1_000_000 - uint256(swapFee), 1_000_000);
    }

    /// @dev Fair output from the square-root price directly, without a truncated `priceX96`, which would loosen the
    /// floor at very small prices. zeroForOne: in * s^2 / Q96^2; otherwise in * Q96^2 / s^2. For sqrtP < 2^128
    /// (practically every pool) s^2 fits in uint256 and a single mulDiv is exact; larger values take two steps,
    /// with a dust-sized error.
    function _quote(uint256 amountIn, uint160 sqrtP, bool zeroForOne) internal pure returns (uint256) {
        if (sqrtP <= type(uint128).max) {
            uint256 p = uint256(sqrtP) * uint256(sqrtP);
            return zeroForOne ? FullMath.mulDiv(amountIn, p, Q192) : FullMath.mulDiv(amountIn, Q192, p);
        }
        if (zeroForOne) return FullMath.mulDiv(FullMath.mulDiv(amountIn, sqrtP, Q96), sqrtP, Q96);
        return FullMath.mulDiv(FullMath.mulDiv(amountIn, Q96, sqrtP), Q96, sqrtP);
    }

    function _minOut(uint256 fairOut, uint256 bps) internal pure returns (uint256) {
        require(bps <= 2000, "slippage too high");
        return (fairOut * (10000 - bps)) / 10000;
    }

    /// @dev Computes and runs the swap that brings the fees to the position's ratio.
    /// Math ported from Revert Finance's SelfCompoundor._swapToPriceRatio (MIT).
    /**
     * @dev Precondition of a compound, applied when an anchor is available.
     *
     * The gate guards the whole compound rather than only the swap, because adding liquidity at a moved price
     * mints at a bad ratio as well. Rejecting every pair without an anchor would block most v4 pairs (v4 has no
     * oracle), so the rule is: enforce with an anchor, run without a swap otherwise. Without an anchor the exposure
     * is limited to the collected fees; principal is never withdrawn. Claim mode never calls this function.
     */
    /**
     * @dev If the anchor is unavailable, for whatever reason, the compound runs without one: no swap and no gate.
     * If it is available and spot is outside the gate, the compound reverts with "price manipulated".
     *
     * Anchor sources: Chainlink when both tokens have a feed, otherwise the single v3 pool the owner assigned to
     * the pair after a 24-hour public wait. The factory is never scanned, so an unassigned pool cannot become the
     * anchor. A Chainlink anchor goes quiet only when a feed is older than its age limit; an assigned pool when it
     * has not traded for 6 hours or its depth is below `minDepth`.
     *
     * Without an on-chain anchor, the caller may pass a reference computed off chain (`refSqrtPriceX96`: the
     * keeper through `executeWithReference`, a user as the third field of the NFT data). The pair then runs with
     * the gate and the swap; only without a reference does it run without a swap. Gate tolerance by fee tier:
     * `_gateTicks`. `CompoundedWithoutAnchor` is emitted for monitoring.
     */
    function _requireUnmanipulated(PoolKey memory key, uint160 refSqrtPriceX96)
        internal
        view
        returns (bool okAnchor, uint160 anchorSqrtP, int24 anchorTick, bool fromCaller)
    {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        (okAnchor, anchorSqrtP, anchorTick) = priceAnchor.anchor(c0, c1);
        // ok = true with an out-of-range price would be corrupt anchor data: fail with a clear reason.
        // GoatPriceAnchor never returns it.
        if (okAnchor) {
            require(anchorSqrtP >= TickMath.MIN_SQRT_PRICE && anchorSqrtP < TickMath.MAX_SQRT_PRICE, "bad anchor");
        }
        if (!okAnchor) {
            // No on-chain anchor. A reference computed off chain (sqrtPriceX96 in the pool's own direction,
            // token1/token0) takes its place for the gate and the swap floor; a price moved after the reference
            // was taken fails the gate. Without a reference: no swap and no price gate (see the notes above).
            if (refSqrtPriceX96 == 0) return (false, 0, 0, false);
            okAnchor = true;
            fromCaller = true;
            anchorSqrtP = refSqrtPriceX96;
            anchorTick = TickMath.getTickAtSqrtPrice(refSqrtPriceX96);
        }
        (, int24 spotTick,,) = poolManager.getSlot0(key.toId());
        int24 dev = spotTick > anchorTick ? spotTick - anchorTick : anchorTick - spotTick;
        // With an anchor, the gate is mandatory.
        require(dev < _gateTicks(key.fee), "price manipulated");
    }

    function _swapToRatio(
        PoolKey memory key,
        State memory s,
        uint256 slippageBps,
        bool okAnchor,
        uint160 anchorSqrtP,
        int24 anchorTick
    ) internal {
        if (s.amount0 == 0 && s.amount1 == 0) return;
        // No rebalancing in pools whose static fee is above MAX_REBALANCE_FEE (see that constant).
        if (key.fee & DYNAMIC_FEE_FLAG == 0 && key.fee > MAX_REBALANCE_FEE) return;

        (uint160 sqrtP, int24 spotTick, uint24 protocolFee, uint24 slot0LpFee) = poolManager.getSlot0(key.toId());
        // `sqrtP * sqrtP` can overflow uint256 (sqrtPriceX96 goes up to about 1.46e48), which would break pools
        // whose raw price exceeds 2^64; FullMath.mulDiv uses a 512-bit intermediate.
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), Q96);
        if (priceX96 == 0) return;

        // A floor derived from spot would move with spot, so the floor comes from the independent anchor, which
        // `_requireUnmanipulated` already read in this transaction. No anchor: no swap. The liquidity is then
        // added at the current spot, and the exposure is limited to the fees collected in this compound.
        if (!okAnchor) return;

        // Checked again so that this function stands on its own; the caller has already applied the gate.
        int24 dev = spotTick > anchorTick ? spotTick - anchorTick : anchorTick - spotTick;
        if (dev >= _gateTicks(key.fee)) return;

        // The swap amount comes from spot (a wrong amount is only inefficient); the floor, which is what matters,
        // comes from the anchor through `_quote`.

        (uint256 pos0, uint256 pos1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtPriceAtTick(s.tickLower),
            TickMath.getSqrtPriceAtTick(s.tickUpper),
            uint128(Q96) // dummy liquidity: only the ratio matters
        );

        bool sell0;
        uint256 delta0;
        if (pos0 == 0) {
            // Price above the range: the position is all token1, so sell all token0.
            delta0 = s.amount0;
            sell0 = true;
        } else if (pos1 == 0) {
            // Price below the range: the position is all token0, so sell all token1.
            delta0 = FullMath.mulDiv(s.amount1, Q96, priceX96);
            sell0 = false;
        } else {
            /**
             * Derived without large intermediates: a ratio such as pos0 * Q96 / pos1 overflows when the price is
             * close to the lower end of the range and pos1 is tiny, and mulDiv would revert just the same.
             *
             * R = pos0/pos1 (target token0/token1 ratio), P = priceX96/Q96 (token1 per token0).
             * Selling delta0 token0 buys delta0*P token1, and the ratio lands on R:
             *     (amount0 - delta0) / (amount1 + delta0*P) = R
             *  => delta0 * (1 + R*P) = amount0 - R*amount1
             *  => delta0 = (amount0 - R*amount1) / (1 + R*P)
             * Every term is a bounded mulDiv:
             *   R*amount1      = mulDiv(amount1, pos0, pos1)          -> below amount0 in the sell0 branch
             *   (1 + R*P)*Q96  = Q96 + mulDiv(pos0, priceX96, pos1)   -> about O(1)*Q96
             * because near a range edge P shrinks as pos0/pos1 grows, so their product stays bounded.
             */
            // `amount1 * pos0 / pos1` may not fit uint256 (price just above the lower end, large amount1). If
            // floor(pos0/pos1) >= floor(MAX/amount1), the product exceeds MAX - amount1 >= amount0, so the excess is
            // certainly in token1: use MAX without calling mulDiv (same direction, no revert).
            uint256 wantedZeroForOne = (s.amount1 != 0 && pos0 / pos1 >= type(uint256).max / s.amount1)
                ? type(uint256).max
                : FullMath.mulDiv(s.amount1, pos0, pos1); // R*amount1
            sell0 = s.amount0 > wantedZeroForOne;
            if (sell0) {
                uint256 denomX96 = Q96 + FullMath.mulDiv(pos0, priceX96, pos1); // (1 + R*P)*Q96
                if (denomX96 == 0) return;
                delta0 = FullMath.mulDiv(s.amount0 - wantedZeroForOne, Q96, denomX96);
            } else {
                // Mirror case, excess in token1: delta1 = (amount1 - amount0/R) / (1 + 1/(R*P))
                uint256 wantedOneForZero = FullMath.mulDiv(s.amount0, pos1, pos0); // amount0/R
                if (s.amount1 <= wantedOneForZero) return; // already at the ratio
                uint256 rp = FullMath.mulDiv(pos0, priceX96, pos1); // R*P*Q96
                if (rp == 0) return;
                uint256 denomX96 = Q96 + FullMath.mulDiv(Q96, Q96, rp); // (1 + 1/(R*P))*Q96
                if (denomX96 == 0) return;
                uint256 delta1calc = FullMath.mulDiv(s.amount1 - wantedOneForZero, Q96, denomX96);
                // Convert to delta0, since delta1 is recomputed below as delta0*P.
                delta0 = FullMath.mulDiv(delta1calc, Q96, priceX96);
            }
        }

        // Our own swap cannot push spot out of the gate band around the anchor: the price limit is one tick inside
        // the band, or the floor price if that is tighter. If spot is already at the limit there is no swap (the
        // matched part is still added). With a tolerance narrower than the band, a large rebalance fills partly,
        // up to the floor price, instead of failing with `SwapSlippage`.
        uint160 lim = _swapLimit(anchorTick, _gateTicks(key.fee), anchorSqrtP, slippageBps, sell0);
        if (sell0 ? sqrtP <= lim : sqrtP >= lim) return;
        uint256 amountIn;
        if (sell0) {
            if (delta0 == 0 || delta0 > s.amount0) return;
            amountIn = delta0;
        } else {
            amountIn = FullMath.mulDiv(delta0, priceX96, Q96);
            if (amountIn == 0 || amountIn > s.amount1) return;
        }
        uint16 pf = sell0 ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee) : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
        uint256 minOut = _minOut(_netOfLpFee(_quote(amountIn, anchorSqrtP, sell0), key.fee, pf), slippageBps);
        // If the floor cannot be met even with zero price impact at the current spot (after the real swap fee; the
        // slot0 lpFee in a dynamic pool), the swap would fail with `SwapSlippage`. Skip it instead: the matched part
        // is added at the gated spot and the rest is returned; with one-sided fees the result is `NothingToCompound`.
        // A hook that overrides the LP fee in `beforeSwap` is not visible here; in such a pool the swap reverts with
        // `SwapSlippage` instead of being skipped, and nothing is lost.
        {
            uint24 lpNow = key.fee & DYNAMIC_FEE_FLAG != 0 ? slot0LpFee : key.fee;
            uint24 feeNow = pf == 0 ? lpNow : ProtocolFeeLibrary.calculateSwapFee(pf, lpNow);
            if (_netOfFee(_quote(amountIn, sqrtP, sell0), feeNow) < minOut) return;
        }
        _poolSwap(key, sell0, amountIn, minOut, lim);
    }

    // Context passed through unlock (decoded in unlockCallback).
    struct SwapCtx {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMin;
        uint160 sqrtPriceLimitX96;
    }

    function _poolSwap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint160 limit)
        internal
    {
        poolManager.unlock(abi.encode(SwapCtx(key, zeroForOne, amountIn, amountOutMin, limit)));
    }

    /// @dev sqrtPriceLimit one tick inside the gate band, so the tick t after the swap has
    /// |t - anchorTick| <= g - 1 < g. The +1 / -1 wei keeps a swap that stops exactly on a tick boundary from being
    /// recorded one tick lower (v4 records tick = tickNext - 1 when it crosses in the zeroForOne direction).
    function _gateEdgeLimit(int24 anchorTick, int24 g, bool zeroForOne) internal pure returns (uint160 lim) {
        if (zeroForOne) {
            int24 t = anchorTick - g + 1;
            if (t < TickMath.MIN_TICK) t = TickMath.MIN_TICK;
            lim = TickMath.getSqrtPriceAtTick(t) + 1;
        } else {
            int24 t = anchorTick + g;
            if (t > TickMath.MAX_TICK) t = TickMath.MAX_TICK;
            lim = TickMath.getSqrtPriceAtTick(t) - 1;
        }
    }

    /// @dev The tighter of the gate-edge limit and the floor-price limit (zeroForOne: the larger, otherwise the
    /// smaller).
    function _swapLimit(int24 anchorTick, int24 g, uint160 anchorSqrtP, uint256 bps, bool zeroForOne)
        internal
        pure
        returns (uint160 lim)
    {
        lim = _gateEdgeLimit(anchorTick, g, zeroForOne);
        uint160 f = _floorLimit(anchorSqrtP, bps, zeroForOne);
        if (zeroForOne ? f > lim : f < lim) lim = f;
    }

    /// @dev The marginal price implied by the floor. If the swap ends at a marginal price no worse than this, the
    /// average fill is no worse either, so out >= in * anchor * (1 - fee) * (1 - bps), the `_proRata` floor in a
    /// static-fee pool. zeroForOne: sqrt = anchorSqrt * sqrt(1 - bps/1e4), rounded up; otherwise
    /// anchorSqrt / sqrt(1 - bps/1e4), rounded down (rounding only tightens the limit). bps <= 2000
    /// (`onERC721Received`, `_minOut`).
    function _floorLimit(uint160 anchorSqrtP, uint256 bps, bool zeroForOne) internal pure returns (uint160) {
        if (zeroForOne) {
            uint256 k = Math.sqrt(FullMath.mulDivRoundingUp(10000 - bps, Q192, 10000), Math.Rounding.Ceil);
            uint256 f = FullMath.mulDivRoundingUp(anchorSqrtP, k, Q96); // k <= Q96 -> f <= anchorSqrtP
            return f <= TickMath.MIN_SQRT_PRICE ? TickMath.MIN_SQRT_PRICE + 1 : uint160(f);
        }
        uint256 k1 = Math.sqrt(FullMath.mulDiv(10000, Q192, 10000 - bps));
        uint256 f1 = FullMath.mulDiv(anchorSqrtP, k1, Q96);
        return f1 >= TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE - 1 : uint160(f1);
    }

    /// @dev The floor is linear in amountIn: a partial fill at the price limit keeps the same floor per unit
    /// (rounded up).
    function _proRata(uint256 minOut, uint256 paid, uint256 amountIn) internal pure returns (uint256) {
        if (paid >= amountIn) return minOut;
        return FullMath.mulDivRoundingUp(minOut, paid, amountIn);
    }

    /// @dev PoolManager.unlock callback: swaps, pays the input and takes the output.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapCtx memory c = abi.decode(data, (SwapCtx));

        BalanceDelta d = poolManager.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: -int256(c.amountIn), // negative = exact input
                sqrtPriceLimitX96: c.sqrtPriceLimitX96
            }),
            ""
        );

        // The signs must match the direction (input <= 0, output >= 0); otherwise a negative output, possible with a
        // hook that returns deltas, would wrap into a large uint128 and pass the floor. Negating a value <= 0 is
        // checked arithmetic, so int128.min reverts instead of overflowing.
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (c.zeroForOne ? (a0 > 0 || a1 < 0) : (a1 > 0 || a0 < 0)) revert BadSwapDelta();
        uint256 paid = SafeCast.toUint128(c.zeroForOne ? -a0 : -a1);
        uint256 out = SafeCast.toUint128(c.zeroForOne ? a1 : a0);
        if (paid > c.amountIn) revert BadSwapDelta();
        if (out < _proRata(c.amountOutMin, paid, c.amountIn)) revert SwapSlippage();
        if (c.zeroForOne) {
            // currency0 is owed (negative), currency1 is owed to us (positive)
            c.key.currency0.settle(poolManager, address(this), paid, false);
            c.key.currency1.take(poolManager, address(this), out, false);
        } else {
            c.key.currency1.settle(poolManager, address(this), paid, false);
            c.key.currency0.take(poolManager, address(this), out, false);
        }
        return "";
    }

    // DECREASE_LIQUIDITY(0) + TAKE_PAIR(this): collects the fees.
    function _collect(uint256 tokenId, PoolKey memory key) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    // INCREASE_LIQUIDITY + two CLOSE_CURRENCY (+ SWEEP of unspent native ETH): adds the liquidity.
    /**
     * @dev CLOSE_CURRENCY pulls ERC20 from this contract through Permit2 on a negative delta, so two approvals are
     * needed. They are given before the `sqrtP` read, because a token's `approve` runs token code that could move
     * the pool price. After the read only the hook runs before the pool's `modifyLiquidity`; the owner chose that
     * pool, and the tight `amount_iMax` bounds it.
     */
    function _approveForIncrease(PoolKey memory key, uint256 max0, uint256 max1) internal {
        if (!key.currency0.isAddressZero()) _ensurePermit2(Currency.unwrap(key.currency0), max0);
        if (!key.currency1.isAddressZero()) _ensurePermit2(Currency.unwrap(key.currency1), max1);
    }

    /// @return foreignNative Native ETH brought in by SWEEP that is not ours (accounting only).
    function _increase(uint256 tokenId, PoolKey memory key, uint128 liq, uint256 max0, uint256 max1)
        internal
        returns (uint256 foreignNative)
    {
        bool native0 = key.currency0.isAddressZero();

        if (native0) {
            // Read right before the value-carrying call, so that no other code can change the PositionManager's
            // balance between this read and our SWEEP.
            foreignNative = address(positionManager).balance;
        }

        /**
         * CLOSE_CURRENCY rather than SETTLE_PAIR. INCREASE_LIQUIDITY credits the position's newly accrued fees into
         * the delta, including the LP fee that our own rebalancing swap paid to this position. Near a range edge or
         * in a high-fee pool that credit can exceed the principal needed in that currency, which makes the delta
         * positive, and SETTLE_PAIR rejects a positive delta. CLOSE_CURRENCY pays a negative delta and takes a
         * positive one to this contract; the amount taken becomes part of the `left_i` refund and does not affect
         * the fee base.
         */
        if (native0) {
            bytes memory actions = abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.CLOSE_CURRENCY),
                uint8(Actions.CLOSE_CURRENCY),
                uint8(Actions.SWEEP)
            );
            bytes[] memory params = new bytes[](4);
            params[0] = abi.encode(tokenId, uint256(liq), SafeCast.toUint128(max0), SafeCast.toUint128(max1), bytes(""));
            params[1] = abi.encode(key.currency0);
            params[2] = abi.encode(key.currency1);
            params[3] = abi.encode(key.currency0, address(this)); // sweep unspent native ETH back
            positionManager.modifyLiquidities{value: max0}(abi.encode(actions, params), block.timestamp);
        } else {
            bytes memory actions = abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
            );
            bytes[] memory params = new bytes[](3);
            params[0] = abi.encode(tokenId, uint256(liq), SafeCast.toUint128(max0), SafeCast.toUint128(max1), bytes(""));
            params[1] = abi.encode(key.currency0);
            params[2] = abi.encode(key.currency1);
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }
    }

    // Two approvals: ERC20 -> Permit2 (unlimited) and Permit2 -> PositionManager (exact amount, this block only).
    function _ensurePermit2(address token, uint256 amount) internal {
        if (amount == 0) return;
        if (IERC20(token).allowance(address(this), address(permit2)) < amount) {
            IERC20(token).forceApprove(address(permit2), type(uint256).max);
        }
        // The Permit2 approval is needed only in this transaction: expiration = block.timestamp.
        permit2.approve(token, address(positionManager), SafeCast.toUint160(amount), uint48(block.timestamp));
    }


    /**
     * @notice Disabled: without an owner, `feeRecipient` and the recovery functions would be frozen for good, and an
     * accidental call cannot be undone. Ownership moves with `transferOwnership` and `acceptOwnership`.
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
