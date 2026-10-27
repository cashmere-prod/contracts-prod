// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PartialFill} from "./GoatV4Errors.sol";

/**
 * @notice Swap amount Δ for a RECENTER, derived from first principles.
 *
 * @dev Model (single segment): active pool liquidity `Lp`, static fee φ (pips), start price s0.
 *      zeroForOne:  Δnet(s1) = amount0(s1→s0, Lp),  out(s1) = amount1(s1→s0, Lp),  Δ = Δnet / (1−φ)
 *      Goal: at the post-swap price s1, fill the new range in exact proportion:
 *          L0(X0 − Δ, [s1, sb]) == L1(X1 + out, [sa, s1])
 *      f(s1) = L0 − L1 decreases monotonically as s1 falls; bisection over s1 ∈ [sLimit, s0].
 *      The other direction (oneForZero) is symmetric: f = L1(X1 − Δ) − L0(X0 + out), decreasing as s1 rises.
 *
 * @dev Δ is an efficiency choice; the loss bound does not depend on it (the floor and the gate bound the loss). If the
 *      model is wrong across tick crossings, the result is only a leftover (refunded to the owner) or `PartialFill`
 *      (revert). A solution beyond the limit is clamped to the limit; the clamped Δ is rounded down, so a pool with the
 *      modelled liquidity fills it completely without touching the limit.
 * @dev When the liquidity along the path is lower than the model assumes (a liquidity band at the spot, a cliff), the
 *      single-segment model overestimates Δ. The Engine therefore limits the RECENTER swap at the target price `s1`
 *      returned by `solve` (exact-in, sqrtPriceLimit = s1, always inside anchor ∓ G) and refunds the unused rest to the
 *      owner; the floor applies to the actual swapIn.
 */
library GoatSwapSizer {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant MAX_STEPS = 96;

    struct Input {
        bool zeroForOne;
        uint160 s0; // price before the swap
        uint160 sLimit; // price limit (anchor ∓ G)
        uint128 poolLiquidity; // active pool liquidity
        uint24 fee; // fee the pool takes from the INPUT (pips); Engine: live pf ⊕ lp (kind 3: composite(pf, φ) − 1), output tax excluded
        uint160 sa; // lower sqrt price of the new range
        uint160 sb; // upper sqrt price of the new range
        uint256 x0; // token0 on hand (after the protocol fee)
        uint256 x1; // token1 on hand (after the protocol fee)
        uint160 sMint; // 0 = same pool (mint at the post-swap s1); else the own pool's price (swap on another exec pool)
        uint24 outTax; // pips a hook takes from the swap OUTPUT (kind-4 launch tax); the mint model gets out·(1 − outTax)
    }

    /// @notice Is a swap needed at all? Independent of the fee (`_tooMuch(s0)` has gross 0), so the Engine reads the
    ///         live fee only when this returns true; `p.fee` may still be 0 here.
    function needed(Input memory p) internal pure returns (bool) {
        // The mint price is fixed at the own pool's price; outside the new range there is no ratio to aim at.
        if (p.sMint != 0 && (p.sMint <= p.sa || p.sMint >= p.sb)) return false;
        if (p.sMint == 0 && (p.zeroForOne ? (p.sLimit <= p.sa || p.s0 >= p.sb) : (p.s0 <= p.sa || p.sLimit >= p.sb))) {
            return false;
        }
        return _tooMuch(p, p.s0);
    }

    /// @notice Δ when `needed(p)` holds (the caller checked it); `p.fee` is the fee the pool charges on the INPUT (never
    ///         an output-side tax). Also returns the model's target price `s1` (in [sLimit, s0] for zeroForOne,
    ///         [s0, sLimit] otherwise), which the Engine uses as the RECENTER swap's price limit.
    ///         When a swap is needed and the limit is already reached, or the active liquidity is 0: `PartialFill`.
    function solve(Input memory p) internal pure returns (uint256 amountIn, uint160 s1) {
        if (p.zeroForOne) {
            if (p.poolLiquidity == 0 || p.sLimit >= p.s0) revert PartialFill();
            if (_tooMuch(p, p.sLimit)) return (_gross(p, p.sLimit), p.sLimit);
            uint160 lo = p.sLimit; // f < 0 (swapped too much)
            uint160 hi = p.s0; // f >= 0 (still a token0 surplus)
            for (uint256 i; i < MAX_STEPS; ++i) {
                if (hi - lo <= 1 || hi - lo <= (hi >> 48)) break;
                uint160 mid = lo + (hi - lo) / 2;
                if (_tooMuch(p, mid)) hi = mid;
                else lo = mid;
            }
            return (_gross(p, hi), hi);
        } else {
            if (p.poolLiquidity == 0 || p.sLimit <= p.s0) revert PartialFill();
            if (_tooMuch(p, p.sLimit)) return (_gross(p, p.sLimit), p.sLimit);
            uint160 lo = p.s0; // f >= 0 (still a token1 surplus)
            uint160 hi = p.sLimit; // f < 0
            for (uint256 i; i < MAX_STEPS; ++i) {
                if (hi - lo <= 1 || hi - lo <= (hi >> 48)) break;
                uint160 mid = lo + (hi - lo) / 2;
                if (_tooMuch(p, mid)) lo = mid;
                else hi = mid;
            }
            return (_gross(p, lo), lo);
        }
    }

    /// @dev Gross input needed to reach s1 (fee included, rounded down).
    function _gross(Input memory p, uint160 s1) private pure returns (uint256) {
        uint256 net = p.zeroForOne
            ? SqrtPriceMath.getAmount0Delta(s1, p.s0, p.poolLiquidity, false)
            : SqrtPriceMath.getAmount1Delta(p.s0, s1, p.poolLiquidity, false);
        return FullMath.mulDiv(net, PIPS, PIPS - p.fee);
    }

    /// @dev After swapping to s1, is there still a surplus of the SOLD token (f(s1) >= 0)?
    function _tooMuch(Input memory p, uint160 s1) private pure returns (bool) {
        uint256 gross = _gross(p, s1);
        uint256 sold = p.zeroForOne ? p.x0 : p.x1;
        if (gross >= sold) return false;
        uint256 out = p.zeroForOne
            ? SqrtPriceMath.getAmount1Delta(s1, p.s0, p.poolLiquidity, false)
            : SqrtPriceMath.getAmount0Delta(p.s0, s1, p.poolLiquidity, false);
        if (p.outTax != 0) out = FullMath.mulDiv(out, PIPS - p.outTax, PIPS);
        uint256 a0 = p.zeroForOne ? p.x0 - gross : p.x0 + out;
        uint256 a1 = p.zeroForOne ? p.x1 + out : p.x1 - gross;
        // L0 = a0 · (sm·sb/Q96) / (sb − sm) ;  L1 = a1 · Q96 / (sm − sa); sm = the mint price (s1 on the same pool).
        // With sMint fixed, a0 falls and a1 rises as the exec pool's s1 moves with the swap, so f stays monotone.
        uint160 sm = p.sMint == 0 ? s1 : p.sMint;
        uint256 l0 = FullMath.mulDiv(a0, FullMath.mulDiv(sm, p.sb, Q96), p.sb - sm);
        uint256 l1 = FullMath.mulDiv(a1, Q96, sm - p.sa);
        return p.zeroForOne ? l0 >= l1 : l1 >= l0;
    }
}
