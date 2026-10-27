// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/**
 * @notice Reads v4 PoolManager pool state with `extsload` (our MIT helper).
 *
 * @dev License: v4-core `StateLibrary` is MIT but imports `libraries/Position.sol` (BUSL-1.1), so it is not imported
 *      here. Only the storage layout is used: the `_pools` mapping at slot 6, and inside `Pool.State` slot0 at +0 and
 *      liquidity at +3. Slot numbers are a layout fact, not code.
 *
 * @dev slot0 word: [0..159] sqrtPriceX96 | [160..183] tick | [184..207] protocolFee | [208..231] lpFee
 */
library GoatPoolSlots {
    /// @dev Slot of PoolManager's `mapping(PoolId => Pool.State) internal _pools`.
    uint256 internal constant POOLS_SLOT = 6;
    /// @dev Offset of the active liquidity inside `Pool.State`.
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    function _stateSlot(bytes32 poolId) private pure returns (bytes32 s) {
        assembly ("memory-safe") {
            mstore(0x00, poolId)
            mstore(0x20, POOLS_SLOT)
            s := keccak256(0x00, 0x40)
        }
    }

    /// @notice The pool's current price, tick and LP fee.
    function slot0(IPoolManager pm, bytes32 poolId) internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 lpFee) {
        uint256 w = uint256(pm.extsload(_stateSlot(poolId)));
        sqrtPriceX96 = uint160(w);
        tick = int24(uint24(w >> 160));
        lpFee = uint24(w >> 208);
    }

    /// @notice The price and the swap direction's protocol fee from a single slot0 read. `pf` is the 12-bit half of the
    ///         24-bit protocolFee field (bits 184-207): the low 12 bits for zeroForOne, the high 12 bits for oneForZero
    ///         (the layout of v4-core `ProtocolFeeLibrary.getZeroForOneFee` / `getOneForZeroFee`).
    function slot0Pf(IPoolManager pm, bytes32 poolId, bool zeroForOne)
        internal
        view
        returns (uint160 sqrtPriceX96, uint24 pf)
    {
        uint256 w = uint256(pm.extsload(_stateSlot(poolId)));
        sqrtPriceX96 = uint160(w);
        uint256 f = (w >> 184) & 0xFFFFFF;
        pf = uint24(zeroForOne ? f & 0xFFF : f >> 12);
    }

    /// @notice The pool's active liquidity (at the current tick).
    function liquidity(IPoolManager pm, bytes32 poolId) internal view returns (uint128) {
        return uint128(uint256(pm.extsload(bytes32(uint256(_stateSlot(poolId)) + LIQUIDITY_OFFSET))));
    }
}
