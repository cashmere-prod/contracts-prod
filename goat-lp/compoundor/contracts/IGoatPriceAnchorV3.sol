// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

/**
 * @notice The part of `GoatPriceAnchor` (Solidity 0.8.26) that the 0.7.6 compound contracts call. It
 *         provides the outside price used to check compounds.
 *
 * @dev The anchor code is not duplicated here: calls work across compiler versions, so the v3
 * contracts only take the anchor's address.
 */
interface IGoatPriceAnchorV3 {
    /// @return ok whether the outside price is usable right now
    /// @return sqrtPriceX96 outside price as a Uniswap sqrt price (Q64.96)
    /// @return tick outside price as a tick (the floor tick of sqrtPriceX96)
    function anchor(address tokenA, address tokenB)
        external
        view
        returns (bool ok, uint160 sqrtPriceX96, int24 tick);

    /// @return whether a price source is configured for this pair, usable right now or not.
    /// The v3 compound contracts do not call it; it is meant for tests and diagnostics. A false result
    /// does not by itself prove that the pair has no source (see `GoatPriceAnchor.hasSource`).
    function hasSource(address tokenA, address tokenB) external view returns (bool);
}
