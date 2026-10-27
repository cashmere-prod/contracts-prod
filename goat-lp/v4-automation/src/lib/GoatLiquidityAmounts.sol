// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/**
 * @notice Conversions between liquidity and token amounts (MIT).
 *
 * @dev Why this library exists: Uniswap publishes this math under GPL-2.0-or-later (v3-periphery) or as an UNLICENSED
 *      v4-core test helper, and the MIT v4-periphery version only covers the `getLiquidityFor*` direction. The formulas
 *      are therefore rewritten here under MIT on top of the MIT `FullMath`. The math is the canonical Uniswap math and
 *      matches the MIT `SqrtPriceMath`.
 */
library GoatLiquidityAmounts {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    function _toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x, "OVERFLOW");
    }

    function getLiquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0)
        internal pure returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA));
    }

    function getLiquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1)
        internal pure returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _toUint128(FullMath.mulDiv(amount1, Q96, sqrtB - sqrtA));
    }

    function getLiquidityForAmounts(
        uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) {
            liquidity = getLiquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint128 l0 = getLiquidityForAmount0(sqrtP, sqrtB, amount0);
            uint128 l1 = getLiquidityForAmount1(sqrtA, sqrtP, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtA, sqrtB, amount1);
        }
    }
}
