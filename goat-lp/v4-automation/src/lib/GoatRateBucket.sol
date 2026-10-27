// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HourlyLimitHit} from "./GoatV4Errors.sol";

/**
 * @notice Token bucket for the global hourly USD limit.
 *
 * @dev The limit is off by default: `capacity == 0` means no limit and `consume` does nothing. The owner can turn it
 *      on later. Turning it on or lowering it is a tightening and applies immediately; raising it or turning it off
 *      waits for the 24-hour timelock (`GoatV4StewardCore`).
 * @dev When on: capacity C, refilled at C per 3600 s. A single spend is at most C, and the total spent in any one-hour
 *      window is at most 2C (the full bucket at the start of the window plus the refill during it).
 */
library GoatRateBucket {
    uint256 internal constant REFILL_PERIOD = 3600;

    struct Bucket {
        uint128 capacity; // USD with 8 decimals; 0 = limit off
        uint128 level; // level at the last write
        uint40 updatedAt;
    }

    /// @notice Current level (refill applied, capped at the capacity). Meaningless (0) while the limit is off.
    function current(Bucket memory b) internal view returns (uint256 lvl) {
        uint256 elapsed = block.timestamp - b.updatedAt;
        lvl = uint256(b.level) + (elapsed * b.capacity) / REFILL_PERIOD;
        if (lvl > b.capacity) lvl = b.capacity;
    }

    /// @notice Spends `amount`; reverts `HourlyLimitHit` if the level is too low (no partial spend). No-op while off.
    function consume(Bucket storage b, uint256 amount) internal {
        if (b.capacity == 0) return;
        uint256 lvl = current(b);
        if (amount > lvl) revert HourlyLimitHit();
        b.level = uint128(lvl - amount);
        b.updatedAt = uint40(block.timestamp);
    }

    /// @notice Sets the capacity. Turning the limit on starts with a full bucket (there was no limit before); while on,
    ///         the level is capped at the new capacity and is not topped up on a raise. `capacity == 0` turns it off.
    function setCapacity(Bucket storage b, uint128 capacity) internal {
        uint256 lvl = b.capacity == 0 ? capacity : current(b);
        if (lvl > capacity) lvl = capacity;
        b.capacity = capacity;
        b.level = uint128(lvl);
        b.updatedAt = uint40(block.timestamp);
    }
}
