// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PairConfig, NcPairConfig, PairEntry, NcSource} from "../lib/GoatPairTypes.sol";

/**
 * @notice MINIMAL interfaces of the external contracts (ours, MIT).
 * @dev The Uniswap v3 core is GPL and the Chainlink interface lives in a separate package, so neither is imported;
 *      only the signatures of the functions called are written here. The selectors match the deployed contracts
 *      (matching signatures, not copied code).
 */

/// @notice The two functions of a Chainlink AggregatorV3 proxy that are used.
interface IGoatChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice The read-only view of a Uniswap v3 pool used by the source checks.
interface IGoatV3PoolObserve {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
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
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice The extra read-only view of a v3 pool used by the VD4 depth walk.
interface IGoatV3PoolDepth {
    function liquidity() external view returns (uint128);
    function tickSpacing() external view returns (int24);
    function tickBitmap(int16 wordPosition) external view returns (uint256);
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}

/// @notice The one Uniswap v3 factory function used to confirm a pool's identity.
interface IGoatV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @notice ERC-20 decimals (read when a pair is listed).
interface IGoatErc20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice The one view read from the ERC-8056 (scaled UI multiplier) interface of Robinhood stock tokens.
/// @dev `effectiveAt()` is the time the latest (or pending) multiplier step takes effect. The Chainlink answer is the
///      price per RAW token (multiplier included); the feed reflects a step from its first round after the step takes
///      effect. Selector taken from the deployed implementation's bytecode: 0x97a4064f.
interface IGoatScaledUiToken {
    function effectiveAt() external view returns (uint256);
}

/// @notice ERC-721 + permit view of the v4 PositionManager (POSM uses solmate's ERC721).
interface IGoatPosmNft {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable;
    function permit2() external view returns (address);
}

/// @notice The `K.WETH` function used by the native payout fallback. `K.WETH` is NOT WETH9: it is an upgradeable
///         EIP-1967 proxy (its admin can change `deposit` / `transfer` / `balanceOf`). The native payout fallback and
///         the OriginPaid check rely on it (a trust assumption, like USDG and the stock tokens).
interface IGoatWeth {
    function deposit() external payable;
}

/// @notice View of an allowlisted dynamic-fee hook (kind 1 SIGNED_FEE, such as FablesRampETH).
/// @dev `maxFee` is the pool's CONFIGURED cap (the hook admin can change it); `ABSOLUTE_MAX_FEE` is compiled into the
///      bytecode. PoolId is bytes32 in the ABI.
///      `currentFee(poolId, zeroForOne)` (0x15452022): the direction's CURRENT fee. Read only in the same transaction,
///      right before `PoolManager.swap`, as a guard (`currentFee ≤ signed[dir]`, else `FeeAboveSigned`). It also feeds
///      the floor's fee term, but only to TIGHTEN it: the deducted fee is `min(φ, lp_live + tax)` with `lp_live` = this
///      read (Engine `_liveTotalFee`), so the live read can only raise the floor, never loosen it below φ.
interface IGoatFeeCapHook {
    function maxFee(bytes32 poolId) external view returns (uint24);
    function ABSOLUTE_MAX_FEE() external view returns (uint24);
    function currentFee(bytes32 poolId, bool zeroForOne) external view returns (uint24);
}

/// @notice `GoatV4PokeOracle.consult` window. Medians are taken over the existing buckets of the last 15 COMPLETE 60 s
///         slots (the current slot excluded); the `complete` / `registered` counters serve the consumer's 15/15 rule.
struct PokeWindow {
    uint16 complete; // number of buckets in slots k = 1..15 whose start is exactly that slot
    uint16 registered; // how many of them a registered poker touched
    int24 medLo; // lower median of the bucket lo values
    int24 medHi; // lower median of the bucket hi values
    int24 medMid; // lower median of floor((lo + hi) / 2)
    int24 spreadMax; // LOWER median of bucket hi − lo (name kept for compatibility; NOT the widest)
    int24 newLo; // smallest lo of the newest buckets (slot 1 and, if present, slot 0)
    int24 newHi; // largest hi of the newest buckets
    uint128 minL; // smallest in-range liquidity seen by REGISTERED pokes in the window (0 without a registered bucket)
    uint32 age; // now − start of the newest existing bucket
}

/// @notice The one view the registry reads from the poke oracle.
interface IGoatPokeOracle {
    function consult(bytes32 poolId) external view returns (PokeWindow memory w);
}

/// @notice The meter view the registry uses at listing (`GoatV4SourceMeter`, without importing its source).
interface IGoatSourceMeter {
    function POKE_ORACLE() external view returns (address);
    function validateCl(address c0, address c1, PairConfig calldata cfg) external view returns (PairEntry memory);
    function validateNc(address c0, address c1, NcPairConfig calldata cfg)
        external
        view
        returns (PairEntry memory, NcSource memory);
    /// @notice Depth rule: the pool's ±100-tick walk (raw token units: token0 in going down, token1 in going up).
    function v4Depth(bytes32 poolId, int24 ts) external view returns (uint256 down0, uint256 up1, uint128 lNow);
}

/// @notice The view `bindSteward` checks, and the pause mask the slow-reference freeze reads.
interface IGoatStewardRegistryRef {
    function REGISTRY() external view returns (address);
    function pausedModes() external view returns (uint8);
}
