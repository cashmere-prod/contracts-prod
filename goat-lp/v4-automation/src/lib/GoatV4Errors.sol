// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// GoatV4Errors: file-level errors, so the libraries and the contracts share the same selectors.

// --- price and gate
error NoAnchor();
error AnchorVetoed();
error GateExceeded();
/// @notice The source v3 pool's SPOT tick is more than G from the anchor.
error VetoSpotFar();
/// @notice One of the source's SHORT TWAPs (60 s / 10 s) is more than G from the anchor (NC: from the source's
///         TWAP900); on a POKE source, the newest buckets' lo/hi are outside the G band. Only a price held for the
///         whole window passes this check.
error VetoTwapFar();
/// @notice NC row: the source's TWAP900 (POKE: medMid) is more than G from the slow reference, i.e. the price moved
///         faster than the speed limit allows. Swap flows wait; withdraw-only continues.
error VetoSlowFar(int24 twap, int24 slow);
/// @notice The TWAP900 of an NC row's v3 source cannot be read (`observe` reverted, short ring): swap flows fail closed.
error NcTwapUnavailable();
/// @notice POKE source: not every one of the last 15 complete 60 s slots has a bucket with a registered poke.
error PokeHistoryGap(uint256 complete, uint256 registered);
/// @notice POKE NC anchor: the window's spread statistic (`spreadMax`, bucket hi − lo) exceeds G.
error PokeSpreadWide(int256 spread);

// --- pair table (`GoatV4PairRegistry`)
/// @notice The hard leg (`ncIs0`) of a listed NC row cannot be flipped by re-listing (the two budget buckets keep their
///         own raw units; flipping would swap the units). To change the hard leg: `removePair`, then `queueNcPair`
///         (a new row, buckets from the config).
error HardLegFixed();
/// @notice The pair entry breaks a rule (feeds, decimals, bounds, gate, source pool, allowed pools).
error BadPairEntry();
/// @notice The pair has no pool-based price source: only withdraw-only (swap-less) EXIT is open. RECENTER and swap
///         EXIT configs are refused.
error ExitOnlyPair();
/// @notice Listing: the source or a pool failed a usability rule (`GoatV4SourceMeter` reason codes).
error SourceUnusable(uint8 reason);
/// @notice The pair's swap budget is 0 (the guardian or the owner turned swaps off): no swap flows, withdraw-only continues.
error SwapsOff();
/// @notice No room in the pair's leaky swap budget (`value` = counted value, `room` = remaining; the bucket's raw units).
error SwapBudgetExceeded(uint256 value, uint256 room);
/// @notice The pair entry version a swap config is bound to has changed (the owner rewrote the entry); runs fail closed
///         until the position owner sets the config again. Withdraw-only runs are not affected.
error PairChanged();

// --- trigger and range
error NotTriggered();
error RangeUnchanged();
error RangeOutOfBounds();

// --- swap
error SwapFloor();
error PartialFill();

// --- hourly bucket (off by default)
error HourlyLimitHit();

// --- scope and position
error PoolNotAllowed();
error HasSubscriber();
error EmptyPosition();

// --- hook allowlist
/// @notice The hook's configured fee cap was raised above the value pinned in its entry.
error HookFeeCapRaised(uint24 live, uint24 pinned);
/// @notice The code at the hook address does not match the code hash pinned in its entry.
error HookCodeMismatch();
/// @notice The hook's address bits are refused: at entry listing the low 14 bits differ from the entry's `requiredBits`
///         or touch the kind's forbidden mask (return-delta / liquidity hooks; kind 1 / 4 / other); on the unlisted
///         withdraw-only path only the return-delta bits (0x0003) are forbidden.
error HookBitsForbidden();
/// @notice The value is on the registry red list (kind 1 HOOK, 2 CODEHASH, 3 TOKEN); 0x569eeecd.
error RedListedEntry(uint8 kind, bytes32 value);
/// @notice The entry pool's ±100-tick walk at the pair's anchor prices (whole USD) or its listed `fillUsd` is below
///         `ENTRY_MIN_WALK_USD` ($4,000). The argument is always the measured walk, also when the failing term is
///         `fillUsd`; 0x18e3c201.
error EntryTooThin(uint256 walkUsd);
/// @notice A swap flow whose exec pool needs a keeper-signed fee (kinds 1 and 4) came through plain `run` /
///         `runWithPermit` (no signature); `runSwap` is required. 0x2c7c1921.
error FeeNotSigned();
/// @notice The swap's fee term (static fee, pinned φ or the signed total) or the keeper's signed total exceeds the
///         bound `min(cfg.maxSwapFeePips, entry feeCeiling)` the owner signed. 0xe56976e9.
error SwapFeeAboveMax(uint24 feePips, uint24 maxPips);
/// @notice On a keeper-signed exec pool, the hook's live fee for the swap direction, read in the same transaction right
///         before `PoolManager.swap`, is above the signed value. 0x2cc6371c.
error FeeAboveSigned(uint24 live, uint24 signedMax);
/// @notice A run paid its transaction sender: on a run whose tx.origin is not the position owner, tx.origin's native,
///         (WETH | token0) or token1 balance INCREASED across `carryOut`. Only increases count; the single allowance is
///         the exact protocol fee when tx.origin is the fee recipient (on a native pool, native + WETH together). On a
///         pool with neither native nor WETH, WETH is measured too and its gain is reported in the `nativeGain` slot.
///         Raised by the Engine, bubbled up by the Steward. 0x6ba36699.
error OriginPaid(uint256 nativeGain, uint256 gain0, uint256 gain1);
/// @notice A swap flow would swap on the position's OWN pool while that pool has a kind-2 EXTERNAL_VENUE entry (plain
///         `run` / `runWithPermit`, or `runSwap` with `execTickSpacing == 0` or naming the own key). A kind-2 pool is a
///         mint / burn venue only; the swap must run on another listed pool of the pair. 0xeb114d95.
error OwnVenueSwapForbidden();
/// @notice A kind-3 CONST_TAX tax recipient has runtime code. Registry: at queue / apply (a bound recipient other than
///         the hook itself must have no code). Engine: in the same transaction right before `PoolManager.swap` on a
///         kind-3 exec pool; skipped only when the recipient is the exec hook itself. 0x92a9d4ce.
error TaxRecipientHasCode(address recipient);
/// @notice A kind-4 PONSV2_TERMS hook's `launches(poolId)` view (0xad091230, 40,000 gas) reverted or did not return
///         exactly 416 B (registry, at queue / apply), or, in the Engine right before `PoolManager.swap`, returned an
///         unregistered launch or a term above 2,000 bps. 0x3a0adfcf.
error HookFeeUnreadable();

// --- authorization and config
error NotTokenOwner();
error NotConfigOwnerOrTokenOwner();
error OwnerChanged();
error NotOperator();
error NotApprovedForRun();
error NoActiveConfig();
error BadConfig();
error ModePaused();
error IsRetired();
error RunExpired();
error TooSoon();
error BudgetExhausted();

// --- mint and closing invariants
error ZeroLiquidityMint();
error MintMismatch();
error BalanceInvariant();
error AllowanceInvariant();
error PosmNativeChanged();
/// @notice The new NFT of a RECENTER left the owner before the transaction ended.
error NftLeftMidFlight();
/// @notice The Engine received less than it was owed. Swap flows: less than `swapOut` of the swap's output token
///         (output leg), or, on the burn side, the TAKE delivered less than the PoolManager credit it moved (principal +
///         accrued LP fees), so the shortfall is the token's own transfer behaviour (fee-on-transfer, rebasing). Every
///         flow, withdraw-only included: a balance fell below its pre-burn snapshot. 0x82caf19d.
error TransferShort(address token);

// --- callback, engine and native
error NotPoolManager();
error NotInFlight();
error UnexpectedNative();
/// @notice The Engine's own lock (a second lock, independent of the Steward's).
error EngineBusy();

// --- administration
error RenounceDisabled();
error NotQueued();
error TimelockNotReady();
error TimelockExpired();
error NotOwnerOrGuardian();
error BadValue();
/// @notice Founding seeding is sealed. (Deploying a Steward against an unsealed registry gives `BadDeployment`, not this.)
error Sealed();

// --- deployment
error BadDeployment();

// --- poke oracle
/// @notice The poked v4 pool is not initialized (sqrtP == 0).
error PoolNotInitialized(bytes32 poolId);
