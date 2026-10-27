// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CurrencySettler} from "./lib/GoatCurrencySettler.sol";
import {GoatLiquidityAmounts} from "./lib/GoatLiquidityAmounts.sol";
import {GoatPoolSlots} from "./lib/GoatPoolSlots.sol";
import {GoatSwapSizer} from "./lib/GoatSwapSizer.sol";
import {GoatV4Constants as K} from "./lib/GoatV4Constants.sol";
import {GoatPonsV2Terms} from "./lib/GoatPonsV2Terms.sol";
import {IGoatPosmNft, IGoatWeth, IGoatFeeCapHook} from "./interfaces/GoatV4External.sol";
import "./lib/GoatV4Errors.sol";

/**
 * @notice The EXECUTOR of `GoatV4Steward` and the only holder of the NFT approval (spender). Only the Steward calls it.
 *         It makes no decisions (trigger, centre and scope are in the Steward); it executes the given plan and applies
 *         the execution-time protections: the gate after burn / swap / mint, the price limit, the fee-net floor, partial
 *         fill, the hook cap, exact mint caps, CLOSE_CURRENCY, native without SWEEP, gas-limited payouts and the closing
 *         invariants.
 *
 * @dev ONE UNLOCK: burn → swap → mint run inside ONE `PoolManager.unlock` (`modifyLiquiditiesWithoutUnlock`). Payouts
 *      happen AFTER the mint, OUTSIDE the unlock (PoolManager locked). Right after BURN, TAKE_PAIR closes POSM's credit,
 *      so during the swap (while a hook's `beforeSwap` runs) nobody has an open delta that could be taken.
 *
 * @dev WHY A SEPARATE CONTRACT: a single contract would exceed the EIP-170 code size limit. The model is the same: one
 *      config slot (Steward), one spender (Engine); the Engine is created only in the Steward's constructor and obeys
 *      only it, and it has no owner and no rescue function of its own. Its only setter is `setFeeRecipient`, callable
 *      only by the Steward's CURRENT owner (`STEWARD.owner()`, the owner multisig) and never during a run
 *      (`EngineBusy`); it changes nothing but the fee recipient and moves no funds. The setter lives here because of
 *      the Steward's code size limit.
 *
 * @dev The contract holds no NFT and carries no balance between calls; every `carryOut` ends with its starting balances.
 *
 * @dev tx.origin check: when tx.origin is not the owner, `carryOut` reverts `OriginPaid` if tx.origin's native,
 *      (WETH | token0) or token1 balance rose across the call (and its WETH on a pool with neither native nor WETH).
 *      The one allowance is the exact protocol fee when tx.origin is the CURRENT `feeRecipient` (read a single time per
 *      `carryOut`, so it cannot change inside a run). Other assets (unrelated ERC20s, ERC-6909 claims) and payments to a
 *      second address are outside the on-chain scope.
 */
/// @dev The one Steward view the Engine reads (OZ `Ownable.owner()`).
interface IGoatStewardOwner {
    function owner() external view returns (address);
}

contract GoatV4StewardEngine is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IPositionManager internal constant POSM = IPositionManager(K.POSM);
    IPoolManager internal constant POOL_MANAGER = IPoolManager(K.POOL_MANAGER);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(K.PERMIT2);
    uint256 internal constant NATIVE_SEND_GAS = 100_000;
    uint256 internal constant Q96 = 1 << 96;
    /// @dev Entry kind (the registry's / Steward's `KIND_CONST_TAX`), carried in `Plan.hookKind`.
    uint8 internal constant KIND_CONST_TAX = 3;
    /// @dev Kind 1 SIGNED_FEE (the registry's `KIND_SIGNED_FEE`): `maxFee` / `currentFee` are read again before PM.swap.
    uint8 internal constant KIND_SIGNED_FEE = 1;
    /// @dev Kind 4 PONSV2_TERMS (the registry's `KIND_PONSV2_TERMS`): the launch terms are read again before PM.swap.
    uint8 internal constant KIND_PONSV2_TERMS = 4;

    // transient in-flight slot: keccak256("goat.v4.steward.inflight") − 1
    bytes32 private constant IN_FLIGHT_SLOT = 0xc4cf03fee0c4ec7d7d0285ffe24c27a7995d8ad208373fc00785ce95bf1c97ff;

    /// @dev A second lock, INDEPENDENT of the Steward's `nonReentrant` (1 idle, 2 in flight). Kept in persistent
    ///      storage (slot 0).
    uint256 private _lock = 1;

    /// @notice The only caller: the `GoatV4Steward` that created this Engine in its constructor.
    address public immutable STEWARD;
    /// @notice Fee recipient (treasury). Only the Steward's owner can change it, with `setFeeRecipient` (never zero,
    ///         never during a run). Storage slot 1 (`_lock` is slot 0).
    address public feeRecipient;

    event NativePaidAsWeth(address indexed to, uint256 amount);
    /// @notice The fee recipient changed (`oldRecipient` 0 = the constructor's first value).
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);

    error NotSteward();
    /// @notice `setFeeRecipient` from anyone but the Steward's current owner.
    error NotStewardOwner();

    /// @notice The Steward's decision. The Engine chooses none of these.
    struct Plan {
        bool recenter; // true RECENTER, false EXIT
        uint256 tokenId;
        PoolKey key;
        address owner; // ownerOf(tokenId), read BEFORE the burn
        bool upperSide; // false: lower side (100% token0), true: upper side (100% token1)
        bool swapExit; // EXIT: all of the sold side into the other token
        uint256 p0; // one-sided principal (from protocol state)
        uint256 p1;
        int24 anchorTick;
        uint160 anchorSqrtPriceX96; // 0 = withdraw-only EXIT without an anchor (the Steward read the trigger from spot)
        int24 newLower; // RECENTER
        int24 newUpper; // RECENTER
        uint16 feeBps;
        uint16 slippageBps; // effective s (capped by the entry's upper bound on a hooked pool)
        uint24 floorFeePips; // the plan φ (static fee, signed[dir], pinned φ); the floor uses min(φ, lp_live + tax_live)
        uint24 sizeFeePips; // the exec rule's φ, never key.fee; withdraw-only 0. Not read: sizing uses the live total
        uint24 pinnedHookFee; // 0 = no hook; right before the swap, k1: maxFee(poolId) <= this; k4: key.fee + 100(h + c) == this
        int24 gate; // the pair's gate G (registry): the gates and the price limit are anchor ∓ G
        bool feeSigned; // a keeper signature applies (`runSwap`, any exec kind); feeCheck = signed[dir]
        uint24 execFee; // cross-pool leg: the exec pool (same currencies); execTickSpacing == 0 -> the own pool
        int24 execTickSpacing;
        address execHooks;
        uint8 hookKind; // the exec pool's entry kind (0 hookless, 1 SIGNED_FEE, 3 CONST_TAX, 4 PONSV2); 2 never swaps
        uint24 feeCheck; // cap on the exec pool's live TOTAL fee (pf ⊕ lp + tax), checked right before PM.swap
        address taxRecipient; // kind 3: the bound tax recipient; must have no code at swap time unless it is the hook
    }

    struct Result {
        uint256 lpFees0;
        uint256 lpFees1;
        uint256 protocolFee0;
        uint256 protocolFee1;
        bool zeroForOne;
        uint256 swapIn;
        uint256 swapOut;
        uint256 swapFloor;
        uint256 newTokenId;
        uint128 newLiquidity;
        uint160 sqrtPriceAtMint;
        uint256 minted0;
        uint256 minted1;
        uint256 paid0; // RECENTER: refund to the owner; EXIT: payout to the owner
        uint256 paid1;
        uint24 totalFeePips; // the live total the Engine checked against feeCheck (0 = no swap)
    }

    struct Snapshot {
        uint256 pre0;
        uint256 pre1;
        uint256 preWeth;
        uint256 prePosmNative;
    }

    constructor(address feeRecipient_) {
        if (feeRecipient_ == address(0) || _protocolAddress(feeRecipient_)) revert BadDeployment();
        // The deployed POSM's PoolManager and Permit2 must match our constants.
        if (address(POSM.poolManager()) != address(POOL_MANAGER)) revert BadDeployment();
        if (IGoatPosmNft(address(POSM)).permit2() != address(PERMIT2)) revert BadDeployment();
        STEWARD = msg.sender;
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(address(0), feeRecipient_);
    }

    /// @notice The Steward's CURRENT owner (the owner multisig; it follows `transferOwnership` / `acceptOwnership`) sets
    ///         the fee recipient, immediately. Anyone else gets `NotStewardOwner`; never during a run (`EngineBusy`).
    ///         Refused (`BadValue`): zero, this Engine (its own fee would break the closing balance check), the Steward
    ///         (a WETH-fallback fee would have no way out) and the four protocol contracts the Engine pays through:
    ///         WETH, POSM, PoolManager and Permit2 (a fee sent there would break runs or be stuck). Moves no funds: fees
    ///         already paid stay with the old recipient; the next `carryOut` pays the new one, and the OriginPaid
    ///         allowance follows it. A recipient with code is allowed (a multisig): a native fee gets 100k gas and falls
    ///         back to WETH; an ERC20 fee leg the token refuses goes to the position owner.
    function setFeeRecipient(address r) external {
        if (msg.sender != IGoatStewardOwner(STEWARD).owner()) revert NotStewardOwner();
        if (_lock == 2) revert EngineBusy();
        if (r == address(0) || r == address(this) || r == STEWARD || _protocolAddress(r)) revert BadValue();
        emit FeeRecipientSet(feeRecipient, r);
        feeRecipient = r;
    }

    /// @dev WETH, POSM, PoolManager, Permit2 (compile-time constants).
    function _protocolAddress(address r) internal pure returns (bool) {
        return r == K.WETH || r == address(POSM) || r == address(POOL_MANAGER) || r == address(PERMIT2);
    }

    /// @notice TAKE_PAIR, CLOSE_CURRENCY and the swap `take` send native from the PoolManager. POSM sends no native in
    ///         any of these flows (all go through `poolManager.take`), so native from POSM is refused too, as is ETH from
    ///         anyone else.
    receive() external payable {
        if (msg.sender != address(POOL_MANAGER)) revert UnexpectedNative();
    }

    // ================================================================== EXECUTION

    /// @notice Executes the Steward's plan. At the end every Engine balance is back to its starting value.
    function carryOut(Plan calldata p) external returns (Result memory r) {
        if (msg.sender != STEWARD) revert NotSteward();
        if (_lock == 2) revert EngineBusy();
        _lock = 2;
        PoolKey memory key = p.key;
        Snapshot memory s = _snapshot(key);
        bytes32 poolId = PoolId.unwrap(key.toId());
        // tx.origin check: wraps the whole approved window, payouts included. Skipped only for the owner's own run
        // (tx.origin == owner is paid by design). Measured: tx.origin's native, (WETH | token0), token1 and, on a pool
        // with neither native nor WETH, WETH.
        bool belt = tx.origin != p.owner;
        address bx = key.currency0.isAddressZero() ? K.WETH : Currency.unwrap(key.currency0);
        // On a pool with neither native nor WETH, WETH is measured too (`xw`).
        bool xw = bx != K.WETH && Currency.unwrap(key.currency1) != K.WETH;
        uint256[4] memory ob;
        if (belt) ob = _originBal(bx, Currency.unwrap(key.currency1), xw);
        // A single read of the recipient; the fee legs and the check's allowance use the same value.
        address rcpt = feeRecipient;

        // Burn → swap → mint: ONE unlock.
        assembly ("memory-safe") {
            tstore(IN_FLIGHT_SLOT, poolId)
        }
        r = abi.decode(POOL_MANAGER.unlock(abi.encode(p, s)), (Result));
        assembly ("memory-safe") {
            tstore(IN_FLIGHT_SLOT, 0)
        }

        // Payouts: AFTER the mint, PoolManager locked. The fee first, then the owner (token1, token0 last).
        r.paid0 = _balance(key.currency0) - s.pre0 - r.protocolFee0;
        r.paid1 = _balance(key.currency1) - s.pre1 - r.protocolFee1;
        // A fee leg the token refuses (e.g. an issuer freeze of the `feeRecipient`) is paid to the owner instead, so no
        // fee leg can block a run (withdraw-only and the owner's own run included); the reported fee is then 0, and so
        // is the check's fee allowance below.
        if (!_payFee(key.currency0, rcpt, r.protocolFee0)) (r.paid0, r.protocolFee0) = (r.paid0 + r.protocolFee0, 0);
        if (!_payFee(key.currency1, rcpt, r.protocolFee1)) (r.paid1, r.protocolFee1) = (r.paid1 + r.protocolFee1, 0);
        _pay(key.currency1, p.owner, r.paid1);
        _pay(key.currency0, p.owner, r.paid0);

        if (belt) {
            uint256[4] memory oa = _originBal(bx, Currency.unwrap(key.currency1), xw);
            // Increases only (a decrease needs the origin's own approval). The exact protocol fee is ours, not a payment
            // to the sender, but only when tx.origin IS the fee recipient; on a native pool it may arrive as native or as
            // WETH (`_pay` fallback), so the allowance covers their sum. A WETH gain on an `xw` pool is wrapped native and
            // is reported in the native slot (no allowance: such a pool pays no fee in native or WETH).
            uint256 gn = (oa[0] > ob[0] ? oa[0] - ob[0] : 0) + (oa[3] > ob[3] ? oa[3] - ob[3] : 0);
            uint256 g0 = oa[1] > ob[1] ? oa[1] - ob[1] : 0;
            uint256 g1 = oa[2] > ob[2] ? oa[2] - ob[2] : 0;
            bool fr = tx.origin == rcpt;
            uint256 a0 = fr ? r.protocolFee0 : 0;
            uint256 a1 = fr ? r.protocolFee1 : 0;
            // On a native/WETH pool `bx` and currency1 are both WETH: count WETH a single time (g1) and check the
            // origin's native + WETH gain against the sum of both fee legs (a native fee may arrive as WETH, `_pay`).
            if (key.currency0.isAddressZero() && Currency.unwrap(key.currency1) == K.WETH) {
                (gn, g0, g1, a0, a1) = (0, 0, gn + g1, 0, a0 + a1);
            }
            if ((key.currency0.isAddressZero() ? gn + g0 > a0 : (gn > 0 || g0 > a0)) || g1 > a1) {
                revert OriginPaid(gn, g0, g1);
            }
        }

        _checkClosing(key, s);
        _lock = 1;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (Plan memory p, Snapshot memory s) = abi.decode(data, (Plan, Snapshot));
        bytes32 poolId = PoolId.unwrap(p.key.toId());
        bytes32 expected;
        assembly ("memory-safe") {
            expected := tload(IN_FLIGHT_SLOT)
        }
        if (expected == bytes32(0) || expected != poolId) revert NotInFlight();
        return abi.encode(_flow(p, s, poolId));
    }

    /// @dev The flow inside the unlock. No owner code runs here (no payouts).
    function _flow(Plan memory p, Snapshot memory s, bytes32 poolId) internal returns (Result memory r) {
        PoolKey memory key = p.key;
        bool anchored = p.anchorSqrtPriceX96 != 0;
        // A plan without an anchor can only be withdraw-only: the swap / mint price limit and floor come from the anchor.
        if (!anchored && (p.recenter || p.swapExit)) revert NoAnchor();
        // Burn: BURN_POSITION (min = principal − 1), read POSM's credit, TAKE_PAIR(this): POSM's credit closes right away.
        (uint256 cr0, uint256 cr1) = _burn(p.tokenId, key, p.p0, p.p1);
        {
            // A balance BELOW its pre-burn snapshot (a rebasing or seizing token) reverts the named `TransferShort(token)`
            // in every flow, never panic 0x11.
            uint256 got0 = _got(key.currency0, s.pre0);
            uint256 got1 = _got(key.currency1, s.pre1);
            // Refund accounting only; NOT the fee base.
            r.lpFees0 = got0 > p.p0 ? got0 - p.p0 : 0;
            r.lpFees1 = got1 > p.p1 ? got1 - p.p1 : 0;
            // Burn side, swap flows only: the TAKE must deliver EXACTLY the PoolManager credit it moved (principal +
            // accrued LP fees, read between BURN_POSITION and TAKE_PAIR), so a shortfall is the token's own transfer
            // behaviour (fee-on-transfer / rebasing). Withdraw-only keeps paying the balance difference. Native never
            // trips it.
            if (p.recenter || p.swapExit) {
                if (got0 < cr0) revert TransferShort(Currency.unwrap(key.currency0));
                if (got1 < cr1) revert TransferShort(Currency.unwrap(key.currency1));
            }
            // The fee comes from the principal's token and from protocol state; donations or injections cannot change it.
            // Never more than the TAKE delivered (a seizing or heavily taxing token on withdraw-only), so no payout underflows.
            r.protocolFee0 = p.p0 * p.feeBps / 10_000;
            r.protocolFee1 = p.p1 * p.feeBps / 10_000;
            if (r.protocolFee0 > got0) r.protocolFee0 = got0;
            if (r.protocolFee1 > got1) r.protocolFee1 = got1;
        }
        // Token code (for example the USDG / WETH proxies) ran during TAKE: gate again if there is an anchor. A
        // withdraw-only plan without an anchor has no price-dependent step after this (payouts use the balance difference).
        if (anchored) _gate(poolId, p.anchorTick, p.gate);

        r.zeroForOne = !p.upperSide;

        if (!p.recenter && !p.swapExit) return r;
        // The swap leg's venue, built FRESH from the plan (the own pool when execTickSpacing == 0). Burn, TAKE_PAIR,
        // mint and payouts stay on the own key / poolId.
        PoolKey memory xk = _exec(p);
        bytes32 xid = PoolId.unwrap(xk.toId());
        // The exec pool's spot must be within G of the anchor BEFORE the swap (the own pool was gated after the burn). The
        // price limit is the pair's anchor ∓ G on whichever pool runs the swap; the floor uses the exec φ (Steward plan).
        if (xid != poolId) _gate(xid, p.anchorTick, p.gate);
        uint160 lim = _limit(r.zeroForOne, p.anchorTick, p.gate);
        if (p.recenter) {
            // A single slot0 read of the exec pool gives the sizing price, the PartialFill pre-check price and the
            // direction's protocol fee pf. Only STATICCALLs / EXTCODESIZE and pure math run from here to PM.swap.
            (uint160 s0, uint24 pf) = GoatPoolSlots.slot0Pf(POOL_MANAGER, xid, r.zeroForOne);
            // `sMint`: the mint lands in the OWN pool at its price, which a swap on another pool does not move (0 = same).
            uint160 sm;
            if (xid != poolId) (sm,,) = GoatPoolSlots.slot0(POOL_MANAGER, poolId);
            GoatSwapSizer.Input memory si = GoatSwapSizer.Input({
                zeroForOne: r.zeroForOne,
                s0: s0,
                sLimit: lim,
                poolLiquidity: GoatPoolSlots.liquidity(POOL_MANAGER, xid),
                fee: 0,
                sa: TickMath.getSqrtPriceAtTick(p.newLower),
                sb: TickMath.getSqrtPriceAtTick(p.newUpper),
                x0: _balance(key.currency0) - s.pre0 - r.protocolFee0,
                x1: _balance(key.currency1) - s.pre1 - r.protocolFee1,
                sMint: sm,
                outTax: 0
            });
            uint256 amountIn;
            uint160 tgt; // the sizer's target price, in [lim, s0] (zeroForOne) / [s0, lim]
            uint256 lpTax; // the same read's live LP fee + tax (no pf); tightens the floor in `_swap`
            // Sizing uses the exec pool's LIVE fee (checked against feeCheck first, so <= the signed φ), never the plan
            // φ, and only its INPUT-side part (pf ⊕ lp; kind 3 composite(pf, φ) − 1 pip; an output tax, kind 4, is not
            // grossed up). Whether a swap is needed does not depend on the fee, so a swapless RECENTER reads no fee or
            // hook state.
            if (GoatSwapSizer.needed(si)) {
                (si.fee, lpTax) = _feeGate(r, xk, xid, pf, p);
                // The kind-4 launch tax (lpTax − key.fee) is taken from the OUTPUT: it is modelled on the mint side.
                if (p.hookKind == KIND_PONSV2_TERMS) si.outTax = uint24(lpTax - xk.fee);
                (amountIn, tgt) = GoatSwapSizer.solve(si);
            }
            if (amountIn > 0) {
                // RECENTER is price-targeted: exact-in with the price limit at the target (inside anchor ∓ G); a partial
                // fill is accepted and the unconsumed rest is refunded; the floor applies to the actual swapIn. Kind 3:
                // the tax side (input or output) is not known on chain, so the limit stays anchor ∓ G (partial still accepted).
                _swap(r, xk, amountIn, p.hookKind == KIND_CONST_TAX ? lim : tgt, s0, p, lpTax);
                _gate(xid, p.anchorTick, p.gate); // post-swap, on the pool that moved; `_mint` gates the own pool again
                // A cross-pool run also gates the OWN pool right after the swap, as a same-pool run does.
                if (xid != poolId) _gate(poolId, p.anchorTick, p.gate);
            }
            _mint(r, key, poolId, p, s);
        } else {
            // ALL of the sold token (principal + LP fees in that token − protocol fee).
            uint256 amountIn = r.zeroForOne
                ? _balance(key.currency0) - s.pre0 - r.protocolFee0
                : _balance(key.currency1) - s.pre1 - r.protocolFee1;
            if (amountIn > 0) {
                (uint160 sp, uint24 pf) = GoatPoolSlots.slot0Pf(POOL_MANAGER, xid, r.zeroForOne);
                (, uint256 lpTax) = _feeGate(r, xk, xid, pf, p);
                _swap(r, xk, amountIn, lim, sp, p, lpTax);
            }
        }
    }

    /// @dev The swap venue: the same currencies as the position; the own key when `execTickSpacing == 0`. A FRESH key is
    ///      built, because `x = p.key; x.fee = …` would alias memory and retarget the own-pool mint.
    function _exec(Plan memory p) internal pure returns (PoolKey memory x) {
        x = p.execTickSpacing == 0
            ? p.key
            : PoolKey(p.key.currency0, p.key.currency1, p.execFee, p.execTickSpacing, IHooks(p.execHooks));
    }

    // ================================================================== HELPERS

    function _balance(Currency c) internal view returns (uint256) {
        return c.isAddressZero() ? address(this).balance : IERC20(Currency.unwrap(c)).balanceOf(address(this));
    }

    /// @dev The balance gained since `pre`; below `pre` -> `TransferShort(c)`.
    function _got(Currency c, uint256 pre) internal view returns (uint256) {
        uint256 b = _balance(c);
        if (b < pre) revert TransferShort(Currency.unwrap(c));
        return b - pre;
    }

    /// @dev tx.origin check reads: tx.origin's native, `a0` (WETH on a native pool, else token0) and `a1` (token1)
    ///      balances, and its WETH balance when `xw` (a pool with neither native nor WETH), else 0.
    function _originBal(address a0, address a1, bool xw) internal view returns (uint256[4] memory b) {
        b[0] = tx.origin.balance;
        b[1] = IERC20(a0).balanceOf(tx.origin);
        b[2] = IERC20(a1).balanceOf(tx.origin);
        if (xw) b[3] = IERC20(K.WETH).balanceOf(tx.origin);
    }

    function _snapshot(PoolKey memory key) internal view returns (Snapshot memory s) {
        s.pre0 = _balance(key.currency0);
        s.pre1 = _balance(key.currency1);
        if (key.currency0.isAddressZero()) s.preWeth = IERC20(K.WETH).balanceOf(address(this));
        s.prePosmNative = address(POSM).balance;
    }

    /// @dev Closing invariants. ETH sent by force is included in `pre`; the check is not against an absolute zero.
    function _checkClosing(PoolKey memory key, Snapshot memory s) internal view {
        if (_balance(key.currency0) != s.pre0 || _balance(key.currency1) != s.pre1) revert BalanceInvariant();
        if (key.currency0.isAddressZero() && IERC20(K.WETH).balanceOf(address(this)) != s.preWeth) {
            revert BalanceInvariant();
        }
        if (address(POSM).balance != s.prePosmNative) revert PosmNativeChanged();
    }

    /// @dev |spot − anchor| <= G (inclusive). G is per pair (Steward plan).
    function _gate(bytes32 poolId, int24 anchorTick, int24 g) internal view returns (uint160 sqrtP, int24 spot) {
        (sqrtP, spot,) = GoatPoolSlots.slot0(POOL_MANAGER, poolId);
        int256 d = int256(spot) - int256(anchorTick);
        if (d > g || d < -g) revert GateExceeded();
    }

    function _limit(bool zeroForOne, int24 anchorTick, int24 g) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(zeroForOne ? anchorTick - g : anchorTick + g);
    }

    // ================================================================== BURN

    /// @dev Two POSM calls. Between BURN_POSITION and TAKE_PAIR only this contract runs (two EXTTLOADs; no foreign code
    ///      sees POSM's open credit, and POSM's own lock blocks re-entry), and the credit read is exactly what TAKE_PAIR
    ///      moves. A negative delta never reaches the check: TAKE_PAIR reverts on it first.
    function _burn(uint256 tokenId, PoolKey memory key, uint256 p0, uint256 p1)
        internal
        returns (uint256 cr0, uint256 cr1)
    {
        uint128 min0 = p0 > 0 ? uint128(p0 - 1) : 0;
        uint128 min1 = p1 > 0 ? uint128(p1 - 1) : 0;
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, min0, min1, bytes(""));
        POSM.modifyLiquiditiesWithoutUnlock(abi.encodePacked(uint8(Actions.BURN_POSITION)), params);
        cr0 = _posmCredit(key.currency0);
        cr1 = _posmCredit(key.currency1);
        params[0] = abi.encode(key.currency0, key.currency1, address(this));
        POSM.modifyLiquiditiesWithoutUnlock(abi.encodePacked(uint8(Actions.TAKE_PAIR)), params);
    }

    /// @dev POSM's open PoolManager delta in `c`: the PoolManager's transient slot keccak256(target, currency), read
    ///      through its public `exttload` (written here; the v4-core helper library is not imported).
    function _posmCredit(Currency c) internal view returns (uint256) {
        return uint256(POOL_MANAGER.exttload(keccak256(abi.encode(address(POSM), c))));
    }

    // ================================================================== SWAP

    /**
     * @notice Fee-net floor (rounded up, in the user's favour). The floor deducts the pool's LP fee AND the PoolManager
     *         protocol fee share (1000 pips):
     *         floor = fair · (1e6 − φ_f)(1e6 − 1000)(1e4 − s) / 1e16
     *         `φ_f = min(φ, lp_live + tax_live)`; φ is the plan term (static `key.fee`, `signed[dir]` for kinds 1 / 4,
     *         pinned φ for kind 3) and `lp_live + tax_live` is `_liveTotalFee`'s read in the same transaction right
     *         before PM.swap. The live read can only TIGHTEN the floor (a raise above the signature reverts
     *         `FeeAboveSigned` first); pf is covered by the 1000-pip headroom, as on hookless pools.
     */
    function _swapFloor(uint256 amountIn, bool zeroForOne, uint160 anchorSqrtPriceX96, uint24 feePips, uint16 slippageBps)
        internal
        pure
        returns (uint256)
    {
        // Two rounded-up steps through the sqrt price keep full precision, also at the deep negative ticks the registry
        // admits.
        uint256 a = anchorSqrtPriceX96;
        uint256 fair = zeroForOne
            ? FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(amountIn, a, Q96), a, Q96)
            : FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(amountIn, Q96, a), Q96, a);
        uint256 keep = (1e6 - uint256(feePips)) * (1e6 - uint256(K.PROTOCOL_FEE_HEADROOM_PIPS))
            * (1e4 - uint256(slippageBps));
        return FullMath.mulDivRoundingUp(fair, keep, 1e16);
    }

    /// @dev The exec pool's live TOTAL fee for the swap direction must not exceed `feeCheck` (signed[dir] on `runSwap`,
    ///      min(user max, ceiling) on a plain run), for every exec kind, read in the same transaction after the last
    ///      non-static call. Signed -> `FeeAboveSigned(total, signed)`, else `SwapFeeAboveMax(total, bound)`. Records
    ///      `Result.totalFeePips` (reported by `SwapLeg`). Also returns the same read's `lpTax` (live LP fee + tax, no
    ///      pf), which can only TIGHTEN the floor (`φ_f = min(φ, lpTax)` in `_swap`), and the INPUT-side sizing fee
    ///      `inFee` <= total (see `_liveTotalFee`).
    function _feeGate(Result memory r, PoolKey memory key, bytes32 poolId, uint24 pf, Plan memory p)
        internal
        view
        returns (uint24 inFee, uint256 lpTax)
    {
        // total < 2^24 for every kind (kind 1: lp <= 2^24 − 1 and pf ⊕ lp <= max(lp, 1e6 + pf); kinds 3 / 4 are bounded by
        // the registry), so the casts below never truncate; inFee <= total <= feeCheck.
        uint256 t;
        uint256 f;
        (t, lpTax, f) = _liveTotalFee(key, poolId, r.zeroForOne, pf, p);
        if (t > p.feeCheck) {
            if (p.feeSigned) revert FeeAboveSigned(uint24(t), p.feeCheck);
            revert SwapFeeAboveMax(uint24(t), p.feeCheck);
        }
        r.totalFeePips = uint24(t);
        inFee = uint24(f);
    }

    /// @dev `total = pf ⊕ lp + tax`, `pf ⊕ lp = pf + lp − ⌊pf·lp / 1e6⌋` (the v4 swap fee).
    ///      kind 0 (hookless static): lp = key.fee. kind 1 SIGNED_FEE: `maxFee(poolId) <= pinned` (`HookFeeCapRaised`),
    ///      lp = `currentFee(poolId, dir)`. kind 3 CONST_TAX: the bound recipient has no code unless it is the hook itself
    ///      (`TaxRecipientHasCode`), lp = 0, tax = the pinned φ. kind 4 PONSV2_TERMS: lp = key.fee, tax = 100·(h + c)
    ///      from `launches` (`HookFeeUnreadable`), lp + tax == pin (`HookFeeCapRaised`). Only STATICCALLs / EXTCODESIZE.
    ///      Any other kind on a HOOKED key (0, or 2, which never swaps) -> `PoolNotAllowed()`: a hooked exec key is never
    ///      priced as hookless. Returns `lpTax = lp + tax` (the floor term) next to the total, and the sizer's input-side
    ///      fee `inFee`: the v4 swap fee `pf ⊕ lp` (a kind-4 tax is taken from the OUTPUT in afterSwap and is not grossed
    ///      up); kind 3 `composite(pf, φ) − 1` (`pf + φ − ⌈pf·φ / 1e6⌉`, one pip under the exact composite;
    ///      `total = pf + φ` stays its upper bound for the gate).
    function _liveTotalFee(PoolKey memory key, bytes32 poolId, bool zeroForOne, uint24 pf, Plan memory p)
        internal
        view
        returns (uint256 total, uint256 lpTax, uint256 inFee)
    {
        uint256 lp = key.fee;
        uint256 tax;
        uint8 kd = p.hookKind;
        if (kd == KIND_SIGNED_FEE) {
            IGoatFeeCapHook h = IGoatFeeCapHook(address(key.hooks));
            uint24 cap = h.maxFee(poolId);
            if (cap > p.pinnedHookFee) revert HookFeeCapRaised(cap, p.pinnedHookFee);
            lp = h.currentFee(poolId, zeroForOne);
        } else if (kd == KIND_CONST_TAX) {
            address t = p.taxRecipient;
            // A kind-3 rule never has recipient 0 (the registry refuses it with `BadValue`); fail closed rather than
            // price the tax as paid to nobody.
            if (t == address(0)) revert PoolNotAllowed();
            if (t != address(key.hooks) && t.code.length != 0) revert TaxRecipientHasCode(t);
            (lp, tax) = (0, p.floorFeePips);
        } else if (kd == KIND_PONSV2_TERMS) {
            tax = _ponsV2LpTax(key, poolId, p.pinnedHookFee) - lp;
        } else if (address(key.hooks) != address(0)) {
            revert PoolNotAllowed(); // a hooked exec pool needs kind 1, 3 or 4
        }
        lpTax = lp + tax;
        inFee = pf + lp - (uint256(pf) * lp) / 1e6;
        total = inFee + tax;
        if (kd == KIND_CONST_TAX) {
            uint256 c = pf + tax - (uint256(pf) * tax + 1e6 - 1) / 1e6;
            inFee = c > 0 ? c - 1 : 0;
        }
    }

    /// @dev Exact-in swap inside our own unlock, on the EXEC pool (`key` = the exec pool, or the position's own pool when
    ///      there is no separate one); the delta is settled right away. When `amountIn > 0` the caller has passed
    ///      `_feeGate` and gives `sp` from the same slot0 read (everything in between is read-only). `lpTax` = that read's
    ///      live LP fee + tax (it can only TIGHTEN the floor). An output token arriving below `swapOut` -> `TransferShort`.
    function _swap(
        Result memory r,
        PoolKey memory key,
        uint256 amountIn,
        uint160 lim,
        uint160 sp,
        Plan memory p,
        uint256 lpTax
    ) internal {
        // If the limit is already crossed the pool would revert `PriceLimitAlreadyExceeded`; use an explicit error: partial fill.
        if (r.zeroForOne ? lim >= sp : lim <= sp) revert PartialFill();

        BalanceDelta d = POOL_MANAGER.swap(
            key, SwapParams({zeroForOne: r.zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: lim}), ""
        );
        int128 dIn = r.zeroForOne ? d.amount0() : d.amount1();
        int128 dOut = r.zeroForOne ? d.amount1() : d.amount0();
        if (dIn > 0 || dOut < 0) revert PartialFill();
        r.swapIn = uint256(uint128(-dIn));
        r.swapOut = uint256(uint128(dOut));
        // EXIT: hitting the limit without consuming the whole amount reverts the whole transaction. A RECENTER stops at
        // its target price `lim` and keeps the rest (refunded with the leftover); a swap that fills nothing reverts.
        if (p.recenter ? r.swapIn == 0 : r.swapIn < amountIn) revert PartialFill();
        r.swapFloor = _swapFloor(
            r.swapIn,
            r.zeroForOne,
            p.anchorSqrtPriceX96,
            lpTax < p.floorFeePips ? uint24(lpTax) : p.floorFeePips, // the live read can only tighten
            p.slippageBps
        );
        if (r.swapOut < r.swapFloor) revert SwapFloor();

        (Currency cin, Currency cout) = r.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        cin.settle(POOL_MANAGER, address(this), r.swapIn, false);
        uint256 b0 = _balance(cout);
        cout.take(POOL_MANAGER, address(this), r.swapOut, false);
        if (_balance(cout) < b0 + r.swapOut) revert TransferShort(Currency.unwrap(cout)); // output leg (no underflow)
    }

    /// @dev The live LP fee + tax of a kind-4 exec pool, `key.fee + 100 · (h + c)`, read from `launches(poolId)` (40,000
    ///      gas, exactly 416 B) in the same transaction before PM.swap. Unreadable, unregistered or a term above 2,000 bps
    ///      -> `HookFeeUnreadable()`; != the registry pin -> `HookFeeCapRaised(live, pinned)` (the terms are immutable in
    ///      practice; any divergence fails closed). `_liveTotalFee` uses it for its kind-4 branch.
    function _ponsV2LpTax(PoolKey memory key, bytes32 poolId, uint24 pinned) internal view returns (uint256 lpTax) {
        (uint256 reg,, uint256 c, uint256 h) = GoatPonsV2Terms.read(address(key.hooks), poolId);
        if (reg != 1 || h > 2000 || c > 2000) revert HookFeeUnreadable();
        lpTax = uint256(key.fee) + 100 * (h + c);
        if (lpTax != pinned) revert HookFeeCapRaised(uint24(lpTax), pinned);
    }

    // ================================================================== MINT

    /// @dev The ERC20 → Permit2 leg only (token code runs here, before the gate): the exact amount. On a token whose
    ///      Permit2 allowance is FIXED at infinity (`allowance(·, Permit2)` always max, `approve(Permit2, x)` reverts with
    ///      `Permit2AllowanceIsFixedAtInfinity()` 0x3f68539a) the ERC20 approval is skipped. Permit2 → POSM, the approval
    ///      POSM actually uses, is set to exactly `need` by `_permitPosm` once `need` is known (Permit2 code only, after
    ///      the gate) and expires the same second.
    function _approveExact(Currency c, uint256 amount) internal {
        if (c.isAddressZero()) return;
        address token = Currency.unwrap(c);
        if (IERC20(token).allowance(address(this), address(PERMIT2)) != type(uint256).max) {
            IERC20(token).forceApprove(address(PERMIT2), amount);
        }
    }

    /// @dev Permit2 → POSM = exactly what the mint owes (`need`), expiring this second. CLOSE_CURRENCY closes POSM's
    ///      WHOLE delta, so a Permit2 pull above `need` reverts: the mint can only pay its own debt, never one opened by
    ///      other code during the unlock.
    function _permitPosm(Currency c, uint256 need) internal {
        if (c.isAddressZero()) return;
        PERMIT2.approve(Currency.unwrap(c), address(POSM), uint160(need), uint48(block.timestamp));
    }

    /// @dev Resets the approvals and checks the closing invariant: Permit2 → POSM is 0; ERC20 → Permit2 is 0, or max
    ///      (only on a fixed-infinity token, which is never sent `approve`).
    function _resetApproval(Currency c) internal {
        if (c.isAddressZero()) return;
        address token = Currency.unwrap(c);
        uint256 a = IERC20(token).allowance(address(this), address(PERMIT2));
        if (a != type(uint256).max) IERC20(token).forceApprove(address(PERMIT2), 0);
        PERMIT2.approve(token, address(POSM), 0, 0);
        (uint160 amt,,) = PERMIT2.allowance(address(this), token, address(POSM));
        a = IERC20(token).allowance(address(this), address(PERMIT2));
        if ((a != 0 && a != type(uint256).max) || amt != 0) revert AllowanceInvariant();
    }

    /// @dev The amounts the pool will ask for on the add (rounded up; the same branch as the pool's: the current tick).
    function _amountsUp(int24 tick, uint160 sqrtP, int24 lo, int24 hi, uint128 liq)
        internal
        pure
        returns (uint256 need0, uint256 need1)
    {
        uint160 sa = TickMath.getSqrtPriceAtTick(lo);
        uint160 sb = TickMath.getSqrtPriceAtTick(hi);
        if (tick < lo) {
            need0 = SqrtPriceMath.getAmount0Delta(sa, sb, liq, true);
        } else if (tick < hi) {
            need0 = SqrtPriceMath.getAmount0Delta(sqrtP, sb, liq, true);
            need1 = SqrtPriceMath.getAmount1Delta(sa, sqrtP, liq, true);
        } else {
            need1 = SqrtPriceMath.getAmount1Delta(sa, sb, liq, true);
        }
    }

    /**
     * @dev Mints the new position directly to `owner`: exact caps (+0), CLOSE_CURRENCY ×2, native with exactly
     *      `msg.value = need0` (no SWEEP). `nextTokenId` is read BEFORE the call; then the owner, the liquidity and the
     *      pool identity are checked.
     */
    function _mint(Result memory r, PoolKey memory key, bytes32 id, Plan memory p, Snapshot memory s) internal {
        uint256 x0 = _balance(key.currency0) - s.pre0 - r.protocolFee0;
        uint256 x1 = _balance(key.currency1) - s.pre1 - r.protocolFee1;
        // 1) Approvals BEFORE the price read (token code runs here).
        _approveExact(key.currency0, x0);
        _approveExact(key.currency1, x1);

        // 2) Price right before the mint, plus the gate.
        (uint160 sqrtP, int24 tick) = _gate(id, p.anchorTick, p.gate);
        r.sqrtPriceAtMint = sqrtP;

        // 3-4) Liquidity (rounded down) and the exact amounts the pool will ask for.
        uint128 liq = GoatLiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(p.newLower), TickMath.getSqrtPriceAtTick(p.newUpper), x0, x1
        );
        (uint256 need0, uint256 need1) = _amountsUp(tick, sqrtP, p.newLower, p.newUpper, liq);
        if ((need0 > x0 || need1 > x1) && liq > 0) {
            liq -= 1;
            (need0, need1) = _amountsUp(tick, sqrtP, p.newLower, p.newUpper, liq);
        }
        if (liq == 0) revert ZeroLiquidityMint();
        if (need0 > x0 || need1 > x1) revert MintMismatch();
        r.newLiquidity = liq;
        _permitPosm(key.currency0, need0);
        _permitPosm(key.currency1, need1);

        // 5-7) MINT_POSITION + CLOSE_CURRENCY ×2, empty hookData.
        r.newTokenId = POSM.nextTokenId();
        uint256 b0 = _balance(key.currency0);
        uint256 b1 = _balance(key.currency1);
        {
            bytes memory actions = abi.encodePacked(
                uint8(Actions.MINT_POSITION), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
            );
            bytes[] memory params = new bytes[](3);
            params[0] = abi.encode(
                key, p.newLower, p.newUpper, uint256(liq), uint128(need0), uint128(need1), p.owner, bytes("")
            );
            params[1] = abi.encode(key.currency0);
            params[2] = abi.encode(key.currency1);
            POSM.modifyLiquiditiesWithoutUnlock{value: key.currency0.isAddressZero() ? need0 : 0}(actions, params);
        }
        r.minted0 = b0 - _balance(key.currency0);
        r.minted1 = b1 - _balance(key.currency1);
        // The mint never takes more than it owes (a native leg pays need0 as msg.value; ERC20 is capped by the Permit2
        // allowance above): anything more would be a debt opened by someone else.
        if (r.minted0 > need0 || r.minted1 > need1) revert MintMismatch();

        // 9) Reset the approvals.
        _resetApproval(key.currency0);
        _resetApproval(key.currency1);

        // Checks: the new NFT is the owner's, the liquidity is exact, the pool is the same.
        if (IGoatPosmNft(address(POSM)).ownerOf(r.newTokenId) != p.owner) revert MintMismatch();
        if (POSM.getPositionLiquidity(r.newTokenId) != liq) revert MintMismatch();
        (PoolKey memory k2,) = POSM.getPoolAndPositionInfo(r.newTokenId);
        if (PoolId.unwrap(k2.toId()) != id) revert MintMismatch();
    }

    // ================================================================== PAYOUT

    /**
     * @dev ERC20: safeTransfer. Native: sent with 100k gas; if that fails, wrapped into WETH and sent. Return data is not
     *      copied (assembly call), so a recipient cannot make the run pay for a large returndata. The fee takes the same
     *      bounded path.
     */
    function _pay(Currency c, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!c.isAddressZero()) {
            IERC20(Currency.unwrap(c)).safeTransfer(to, amount);
            return;
        }
        bool ok;
        uint256 g = NATIVE_SEND_GAS;
        assembly ("memory-safe") {
            ok := call(g, to, amount, 0, 0, 0, 0)
        }
        if (ok) return;
        IGoatWeth(K.WETH).deposit{value: amount}();
        IERC20(K.WETH).safeTransfer(to, amount);
        emit NativePaidAsWeth(to, amount);
    }

    /// @dev The protocol-fee leg. Native keeps `_pay` (100k gas, WETH fallback; a native fee always lands). ERC20: a plain
    ///      `transfer` to `to` (the run's `feeRecipient`) whose failure (revert, `false`, or a code-less token) returns
    ///      false instead of reverting; at most 32 bytes of returndata are copied.
    function _payFee(Currency c, address to, uint256 amount) internal returns (bool ok) {
        if (amount == 0 || c.isAddressZero()) {
            _pay(c, to, amount);
            return true;
        }
        address t = Currency.unwrap(c);
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 4), to)
            mstore(add(m, 36), amount)
            mstore(0, 0)
            ok := call(gas(), t, 0, m, 68, 0, 32)
            ok :=
                and(
                    ok,
                    or(
                        and(iszero(returndatasize()), gt(extcodesize(t), 0)),
                        and(gt(returndatasize(), 31), eq(mload(0), 1))
                    )
                )
        }
    }
}
