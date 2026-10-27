// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IVault is IERC4626 {
    function transformedTokenId() external view returns (uint256 tokenId);

    function loans(uint256 tokenId) external view returns (uint256 debtShares);

    function vaultInfo()
        external
        view
        returns (
            uint256 debt,
            uint256 lent,
            uint256 balance,
            uint256 reserves,
            uint256 debtExchangeRateX96,
            uint256 lendExchangeRateX96
        );
    function lendInfo(address account) external view returns (uint256 amount);
    function loanInfo(uint256 tokenId)
        external
        view
        returns (
            uint256 debt,
            uint256 fullValue,
            uint256 collateralValue,
            uint256 liquidationCost,
            uint256 liquidationValue
        );

    function ownerOf(uint256 tokenId) external returns (address);

    // functions for iterating over owners loans
    function loanCount(address owner) external view returns (uint256);
    function loanAtIndex(address owner, uint256 index) external view returns (uint256);

    function create(uint256 tokenId, address recipient) external;
    function createWithPermit(uint256 tokenId, address recipient, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;

    function approveTransform(uint256 tokenId, address target, bool active) external;
    function transform(uint256 tokenId, address transformer, bytes calldata data) external returns (uint256);

    // params for decreasing liquidity of collateralized position
    struct DecreaseLiquidityAndCollectParams {
        uint256 tokenId;
        uint128 liquidity;
        // min amount to accept from liquidity removal
        uint256 amount0Min;
        uint256 amount1Min;
        // amount to remove from fees additional to the liquidity amounts
        uint128 feeAmount0; // (if uint256(128).max - all fees)
        uint128 feeAmount1; // (if uint256(128).max - all fees)
        uint256 deadline;
        address recipient;
    }

    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function borrow(uint256 tokenId, uint256 amount) external;
    function repay(uint256 tokenId, uint256 amount, bool isShare) external returns (uint256 assets, uint256 shares);
    function repay(uint256 tokenId, uint256 amount, bool isShare, bytes calldata permitData)
        external
        returns (uint256 assets, uint256 shares);

    struct LiquidateParams {
        // token to liquidate
        uint256 tokenId;
        // min amount to recieve
        uint256 amount0Min;
        uint256 amount1Min;
        // recipient of rewarded tokens
        address recipient;
        // if permit2 signatures are used - set this
        bytes permitData;
        // for uniswap functions
        uint256 deadline;
    }

    function liquidate(LiquidateParams calldata params) external returns (uint256 amount0, uint256 amount1);

    // deposit functions with permit2
    function deposit(uint256 assets, address receiver, bytes calldata permitData) external returns (uint256);
    function mint(uint256 shares, address receiver, bytes calldata permitData) external returns (uint256);
}
