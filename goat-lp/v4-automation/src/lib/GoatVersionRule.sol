// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GoatV4Constants as K} from "./GoatV4Constants.sol";
import {PairEntry, NcSource} from "./GoatPairTypes.sol";

/**
 * @notice Pair version rule of `GoatV4PairRegistry`. When a LISTED row is written again, its version (`epoch`) is
 *         KEPT if the new row reads the same price source and no limit is looser than in the stored row; otherwise the
 *         version is bumped and every swap config of the pair stops (`PairChanged`) until its owner sets it again. A
 *         rule a user signed therefore never runs under a new price source or a looser limit without a new signature,
 *         and a tightening does not stop anyone's rule.
 *
 * @dev Field by field (stored `o`, new `e`; NC source `on` / `n`; poke pool `op` / `p`):
 *      - identity, must be equal: feed0, feed1, dec0, dec1, every flag bit other than the session bit (the multiplier
 *        flag is detected from the token), srcKind, vetoPool, vetoFlip, vetoPool2, vetoFlip2, the poke pool; NC:
 *        srcFeed, srcDec, the source flag bits other than the session bit, ncIs0;
 *      - smaller or equal keeps: maxAge0, maxAge1, gate, vetoTicks, max0, max1; NC srcMaxAge, srcMax;
 *      - larger or equal keeps: min0, min1; NC srcMin;
 *      - session rules: the session bit (FLAG_MARKET_HOURS) of each leg and of the NC source, and NC xMarketHours,
 *        keep the version when unchanged or switched on (more closed hours), and bump it when switched off.
 *      The version field itself (`epoch`) is not compared. A smaller G keeps every stored config valid: T >= G + 1,
 *      exit levels at least G + 1 outside the range and the minimum width 2(G + ts) only become easier to meet.
 */
library GoatVersionRule {
    function keepsVersion(
        PairEntry memory o,
        NcSource memory on,
        bytes32 op,
        PairEntry memory e,
        NcSource memory n,
        bytes32 p
    ) internal pure returns (bool) {
        return _sameSource(o, on, op, e, n, p) && _legsNotLooser(o, e) && _ncNotLooser(on, n) && e.gate <= o.gate
            && e.vetoTicks <= o.vetoTicks;
    }

    /// @dev The identity fields: the same feeds, decimals, multiplier rules, source kind, source pools and poke pool.
    function _sameSource(
        PairEntry memory o,
        NcSource memory on,
        bytes32 op,
        PairEntry memory e,
        NcSource memory n,
        bytes32 p
    ) private pure returns (bool) {
        return o.feed0 == e.feed0 && o.feed1 == e.feed1 && o.dec0 == e.dec0 && o.dec1 == e.dec1
            && _sameBits(o.flags0, e.flags0) && _sameBits(o.flags1, e.flags1) && o.srcKind == e.srcKind
            && o.vetoPool == e.vetoPool && o.vetoFlip == e.vetoFlip && o.vetoPool2 == e.vetoPool2
            && o.vetoFlip2 == e.vetoFlip2 && op == p && on.srcFeed == n.srcFeed && on.srcDec == n.srcDec
            && _sameBits(on.srcFlags, n.srcFlags) && on.ncIs0 == n.ncIs0;
    }

    /// @dev Both feed rules: age, bounds and session no looser.
    function _legsNotLooser(PairEntry memory o, PairEntry memory e) private pure returns (bool) {
        return e.maxAge0 <= o.maxAge0 && e.maxAge1 <= o.maxAge1 && e.min0 >= o.min0 && e.max0 <= o.max0
            && e.min1 >= o.min1 && e.max1 <= o.max1 && _sessionKept(o.flags0, e.flags0) && _sessionKept(o.flags1, e.flags1);
    }

    /// @dev The NC source rule (V3DERIVED; all zero on other kinds) and the X session calendar: no looser.
    function _ncNotLooser(NcSource memory on, NcSource memory n) private pure returns (bool) {
        return n.srcMaxAge <= on.srcMaxAge && n.srcMin >= on.srcMin && n.srcMax <= on.srcMax
            && _sessionKept(on.srcFlags, n.srcFlags) && (!on.xMarketHours || n.xMarketHours);
    }

    /// @dev Every flag bit except the session bit is equal.
    function _sameBits(uint8 a, uint8 b) private pure returns (bool) {
        return (a | K.FLAG_MARKET_HOURS) == (b | K.FLAG_MARKET_HOURS);
    }

    /// @dev The session bit was off, or it stays on.
    function _sessionKept(uint8 a, uint8 b) private pure returns (bool) {
        return (a & K.FLAG_MARKET_HOURS) == 0 || (b & K.FLAG_MARKET_HOURS) != 0;
    }
}
