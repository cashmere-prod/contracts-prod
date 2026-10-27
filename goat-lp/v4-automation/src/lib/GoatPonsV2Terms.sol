// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GoatV4Constants as K} from "./GoatV4Constants.sol";
import "./GoatV4Errors.sol";

/**
 * @notice Reads the launch terms of a kind-4 (PONSV2_TERMS) hook pool. No hook code or interface is imported; only the
 *         ABI layout of one view is used.
 * @dev `launches(poolId)` (0xad091230) is called with STATICCALL, a fixed 40,000 gas stipend and a fixed 416-byte
 *      buffer. A failed call or `returndatasize() != 416` reverts `HookFeeUnreadable()`; the caller decides how to treat
 *      the words. Only the 416 bytes are copied, so a large returndata costs the caller nothing extra. Words are returned
 *      raw (uint256), so a dirty or out-of-range word fails the caller's range checks instead of being truncated.
 *      Layout: word 0 registered (1), word 2 memecoin, word 7 creatorTaxBps (c), word 10 hookFeeBps (h). The tax of a
 *      launch is `100 · (h + c)` pips, fixed at `registerPool`.
 */
library GoatPonsV2Terms {
    function read(address hook, bytes32 poolId)
        internal
        view
        returns (uint256 registered, uint256 memecoin, uint256 creatorTax, uint256 hookFee)
    {
        bytes4 sel = K.KIND4_LAUNCHES_SELECTOR;
        uint256 g = K.KIND4_LAUNCHES_GAS;
        uint256 n = K.KIND4_LAUNCHES_SIZE;
        bool ok;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            mstore(add(p, 4), poolId)
            ok := staticcall(g, hook, p, 36, p, n)
            // separate statement: Yul evaluates arguments right to left, so `returndatasize()` must follow the call
            ok := and(ok, eq(returndatasize(), n))
            registered := mload(p)
            memecoin := mload(add(p, 64))
            creatorTax := mload(add(p, 224))
            hookFee := mload(add(p, 320))
        }
        if (!ok) revert HookFeeUnreadable();
    }
}
