// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0;
pragma abicoder v2;

/**
 * Minimal Uniswap v3 interfaces, written from scratch under MIT. The upstream Uniswap v3 interfaces
 * are GPL-2.0-or-later, and a contract importing them becomes a derivative work.
 *
 * An interface definition only states facts about a deployed contract's ABI (selectors and types);
 * it contains no algorithm. The scope is still kept to the members the compound contracts need:
 * the members below are called by `GoatSelfCompoundor` or `GoatAutoCompoundV3`, with these exceptions.
 * `IUniV3Pool.token0()`, `token1()` and `liquidity()` are not called by either contract (they only
 * describe the ABI and have no runtime effect). `IV3RouterMinimal` only types the router address:
 * both contracts swap with `exactInputSingle` through their own file-local router interfaces, so
 * `exactInput` is not called. `INpmMinimal.WETH9()` is read only by the `GoatAutoCompoundV3` constructor.
 */

interface IUniV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface INpmMinimal {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function WETH9() external view returns (address);
    function factory() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @dev The swap router on Robinhood Chain is SwapRouter02 (`IV3SwapRouter`): its params structs have
/// no `deadline` field.
interface IV3RouterMinimal {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
