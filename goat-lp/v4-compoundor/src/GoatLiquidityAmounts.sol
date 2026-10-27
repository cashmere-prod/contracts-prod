// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/**
 * @notice GoatLiquidityAmounts: conversions between liquidity and token amounts, MIT licensed.
 *
 * @dev The standard Uniswap liquidity math, written on the MIT `FullMath`; it matches the MIT
 *      `SqrtPriceMath`. It is written here because the v3-periphery version is GPL-2.0-or-later, the
 *      v4-core test helper is UNLICENSED, and the MIT v4-periphery library has only the
 *      `getLiquidityFor*` direction, not `getAmount*For*`.
 *
 * @dev The results are identical to Uniswap's `LiquidityAmounts`.
 */
library GoatLiquidityAmounts {
    uint8 internal constant RESOLUTION = 96;
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

    function getAmount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal pure returns (uint256)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return FullMath.mulDiv(uint256(liquidity) << RESOLUTION, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    function getAmount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal pure returns (uint256)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return FullMath.mulDiv(liquidity, sqrtB - sqrtA, Q96);
    }

    function getAmountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal pure returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) {
            amount0 = getAmount0ForLiquidity(sqrtA, sqrtB, liquidity);
        } else if (sqrtP < sqrtB) {
            amount0 = getAmount0ForLiquidity(sqrtP, sqrtB, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtA, sqrtP, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtA, sqrtB, liquidity);
        }
    }
}
