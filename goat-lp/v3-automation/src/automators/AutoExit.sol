// SPDX-License-Identifier: BUSL-1.1
// Modified by Goat for Robinhood Chain (chain 4663); Goat's changes are commented with "Goat:".
// Source: revert-finance/lend@7e85a81 src/automators/AutoExit.sol.
// Main changes: an exit with a swap is triggered by the anchor (the outside price from GoatPairTable) and runs only on
// listed pairs with a veto pool; a swap-less exit is triggered by the pool's spot tick on every pair. Swaps go through
// the Universal Router only, with route, depth and swap-budget checks, a 900 s TWAP veto, a gate between spot and
// anchor, a minimum output from the anchor price net of the pool fee, and a last swap command that spends the full
// input. Fixed 0.15% exit fee that can only be lowered; the config is bound to the owner who wrote it; owed tokens are
// collected to the owner first; pause and nonReentrant.
// Goat: pragma pinned to the compiler of the deployed build (solc 0.8.24)
pragma solidity 0.8.24;

import "./Automator.sol";
// Goat: Robinhood Chain constants, anchor and route checks
import "../goat/GoatRobinhood.sol";

/// @title AutoExit
/// @notice Lets a v3 position to be automatically removed (limit order) or swapped to the opposite token (stop loss order) when it reaches a certain tick.
/// A revert controlled bot (operator) is responsable for the execution of optimized swaps (using external swap router)
/// Positions need to be approved (approve or setApprovalForAll) for the contract and configured with configToken method
// Goat: GoatRobinhood (anchor, constants)
contract AutoExit is Automator, GoatRobinhood {
    // Goat: extra execution event (Revert's Executed event is kept as is)
    event GoatExitExecuted(
        uint256 indexed tokenId,
        bool anchored,
        int24 triggerTick,
        int24 spotTick,
        uint256 amountOutMin,
        uint256 reward0,
        uint256 reward1
    );
    // Goat: exit fee changes
    event ExitFeeUpdated(address account, uint64 feeX64);

    event Executed(
        uint256 indexed tokenId,
        address account,
        bool isSwap,
        uint256 amountReturned0,
        uint256 amountReturned1,
        address token0,
        address token1
    );
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        bool onlyFees,
        uint64 maxRewardX64
    );

    constructor(
        INonfungiblePositionManager _npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Automator(_npm, _operator, _withdrawer, _TWAPSeconds, _maxTWAPTickDifference, _universalRouter, _zeroxAllowanceHolder) {
        // Goat: Robinhood Chain (4663) only (same check as AutoRange)
        _checkRobinhoodDeployment(_npm.WETH9(), IUniswapV3Factory(_npm.factory()).getPool(WETH, USDG, 100));
        // Goat: veto TWAP bounds; deployed with (900, 150)
        _checkVetoConfig(_TWAPSeconds, _maxTWAPTickDifference);
        // Goat: fixed swap router (Universal Router 2.1.1, immutable); the 0x AllowanceHolder path is disabled
        // (address(0))
        _checkSwapVenue(_npm.factory(), _universalRouter, _zeroxAllowanceHolder);
    }

    // Goat: fixed exit fee = 0.15% (floor(Q64 * 15 / 10000), same as the range fee); the owner can only lower it
    uint64 public constant MAX_EXIT_FEE_X64 = 27670116110564327;
    uint64 public exitFeeX64 = MAX_EXIT_FEE_X64;

    // define how stoploss / limit should be handled
    struct PositionConfig {
        bool isActive; // if position is active
        // should swap token to other token when triggered
        bool token0Swap;
        bool token1Swap;
        // when should action be triggered (when this tick is reached - allow execute)
        int24 token0TriggerTick; // when tick is below this one
        int24 token1TriggerTick; // when tick is equal or above this one
        // max price difference from current pool price for swap / Q64
        uint64 token0SlippageX64; // when token 0 is swapped to token 1
        uint64 token1SlippageX64; // when token 1 is swapped to token 0
        bool onlyFees; // if only fees maybe used for protocol reward
        uint64 maxRewardX64; // max allowed reward percentage of fees or full position
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public positionConfigs;

    // Goat: the owner who wrote the config; the config stops applying when the NFT changes owner
    mapping(uint256 => address) public positionConfigOwners;

    /// @notice params for execute()
    struct ExecuteParams {
        uint256 tokenId; // tokenid to process
        bytes swapData; // if its a swap order - must include swap data
        uint256 amountRemoveMin0; // min amount to be removed from liquidity
        uint256 amountRemoveMin1; // min amount to be removed from liquidity
        uint256 deadline; // for uniswap operations
        uint64 rewardX64; // which reward will be used for protocol, can be max configured amount (considering onlyFees)
    }

    struct ExecuteState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAmount0;
        uint256 feeAmount1;
        uint256 amountOutMin;
        uint256 amountInDelta;
        uint256 amountOutDelta;
        IUniswapV3Pool pool;
        uint256 swapAmount;
        int24 tick;
        bool isSwap;
        bool isAbove;
        address owner;
        // Goat: owed tokens, anchor and event fields
        uint128 owed0;
        uint128 owed1;
        bool anchored;
        int24 anchorTick;
        uint160 anchorSqrtPriceX96;
        int24 triggerTick;
        uint256 reward0;
        uint256 reward1;
        // Goat: the pair's gate G and veto pool from the pair table (always set: _getAnchor rejects address(0)); the
        // swap floor
        uint16 anchorGate;
        IUniswapV3Pool vetoPool;
        uint64 floorX64;
    }

    /**
     * @notice Handle token (must be in correct state)
     * Can only be called only from configured operator account
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    // Goat: whenNotPaused and nonReentrant
    function execute(ExecuteParams calldata params) external whenNotPaused nonReentrant {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }

        PositionConfig memory config = positionConfigs[params.tokenId];

        if (!config.isActive) {
            revert NotConfigured();
        }

        // Goat: the reward must equal the fixed exit fee (Revert's maximum stays as the owner's consent limit)
        if (params.rewardX64 != exitFeeX64) {
            revert FeeMismatch();
        }

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        ExecuteState memory state;

        // Goat: is the owner who wrote the config still the owner?
        state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);
        if (state.owner != positionConfigOwners[params.tokenId]) {
            revert NotConfigured();
        }

        // get position info
        // Goat: tokensOwed is read as well
        (,, state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity,,, state.owed0, state.owed1) =
            nonfungiblePositionManager.positions(params.tokenId);
        // Goat: owed tokens are first collected DIRECTLY to the owner (they never enter this contract, and the swap and
        // the fee are based on the position alone), so dust added to the position by anyone cannot block the exit
        if (state.owed0 != 0 || state.owed1 != 0) {
            nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams(params.tokenId, state.owner, type(uint128).max, type(uint128).max)
            );
        }

        // so can be executed only once
        if (state.liquidity == 0) {
            revert NoLiquidity();
        }

        state.pool = _getPool(state.token0, state.token1, state.fee);
        (, state.tick,,,,,) = state.pool.slot0();

        // Goat: the swap-less side first, triggered by the pool's spot tick (as in Revert). It reads no veto or gate,
        // so it runs on every pair, even when a feed is stale, the market is closed or the pair is not listed. The
        // anchor is read on a best-effort basis only: if it reads and has triggered a swap side, the swap-less exit
        // yields to that (anchored path); if it cannot be read, the spot exit runs as is. Withdrawing at a moved spot
        // price is, valued at the fair price, no worse for the owner than withdrawing at the fair price, so a spot
        // trigger needs no outside price.
        state.triggerTick = state.tick;
        state.isAbove = state.tick >= config.token1TriggerTick;
        state.isSwap = !state.isAbove && config.token0Swap || state.isAbove && config.token1Swap;
        // Goat: a spot-triggered swap-less exit yields to a stop-loss the anchor has already triggered on the swap side
        // (best-effort read: an unreadable anchor keeps the spot exit)
        if (
            state.isSwap || config.token0TriggerTick <= state.tick && state.tick < config.token1TriggerTick
                || _anchorTriggersSwap(state.token0, state.token1, state.fee, config)
        ) {
            // not triggered by spot on a swap-less side; with no swap side configured this is Revert's NotReady
            if (!config.token0Swap && !config.token1Swap) {
                revert NotReady();
            }
            // Goat: the swap side is triggered by the ANCHOR (from the pair table; only pairs with a veto pool)
            state.anchored = true;
            (state.anchorTick, state.anchorSqrtPriceX96, state.anchorGate, state.vetoPool) =
                _getAnchor(state.token0, state.token1, state.fee);
            state.triggerTick = state.anchorTick;
            state.isAbove = state.triggerTick >= config.token1TriggerTick;
            state.isSwap = !state.isAbove && config.token0Swap || state.isAbove && config.token1Swap;
            // the anchor did not trigger, or it triggered a swap-less side (spot-triggered only) -> NotReady
            if (!state.isSwap || config.token0TriggerTick <= state.triggerTick && state.triggerTick < config.token1TriggerTick) {
                revert NotReady();
            }
            // Goat: on the swap side the spot gate |spot - anchor| <= G applies whatever the swapAmount, so a deviating
            // anchor (such as a per-share price around a stock split) cannot close a position that already holds only
            // the target token
            _checkAnchorGate(state.tick, state.anchorTick, state.anchorGate);
        }

        // decrease full liquidity for given position - and return fees as well
        (state.amount0, state.amount1, state.feeAmount0, state.feeAmount1) = _decreaseFullLiquidityAndCollect(
            params.tokenId, state.liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline
        );

        // swap to other token
        if (state.isSwap) {
            // Goat: onlyFees branches removed: configToken rejects onlyFees and is the only writer of positionConfigs,
            // so the fee is always the fixed exit fee on the position
            state.swapAmount = state.isAbove ? state.amount1 : state.amount0;
            if (state.swapAmount != 0) {
                // Goat: swapData is required (and route-checked) only when a swap runs
                if (params.swapData.length == 0) {
                    revert MissingSwapData();
                }

                (state.sqrtPriceX96, state.currentTick,,,,,) = state.pool.slot0();

                // Goat: gate before the swap: |spot - anchor| <= G (the pair's G)
                _checkAnchorGate(state.currentTick, state.anchorTick, state.anchorGate);

                // checks if price in valid oracle range and calculates amountOutMin
                // Goat: veto = 900 s TWAP of the pair's veto pool against the anchor tick; the floor comes from the
                // anchor price with slippage net of the pool fee (_floorX64, h = 0 on v3). There is no path without a
                // veto: an exit with a swap runs only on pairs with a veto pool. The floor uses the lower of the
                // route's fee and the pool's own fee (_phiStar), so a cheaper route cannot widen the allowed slippage.
                state.floorX64 = _floorX64(
                    state.isAbove ? config.token1SlippageX64 : config.token0SlippageX64,
                    _phiStar(state.fee, params.swapData, state.swapAmount)
                );
                state.amountOutMin = _validateSwap(
                    !state.isAbove,
                    state.swapAmount,
                    state.vetoPool, // Goat: the pair's veto pool (Revert: state.pool)
                    state.anchorTick, // Goat: anchor tick (Revert: state.currentTick)
                    state.anchorSqrtPriceX96, // Goat: floor from the anchor (Revert: state.sqrtPriceX96)
                    TWAPSeconds,
                    maxTWAPTickDifference,
                    state.floorX64 // Goat: fee-net floor (Revert: raw slippage)
                );
                // Goat: the source pool's (veto or reference) 60 s and 10 s TWAPs and its spot must be within G of the
                // anchor (swap side only)
                _checkSourceGate(state.vetoPool, state.anchorTick, state.anchorGate);

                // Goat: Universal Router only; hops only through the pair's tokens and WETH/USDG, in canonical fee
                // tiers, with a depth check per hop. Always checked here (a swap runs whenever swapAmount != 0).
                _checkRoute(
                    params.swapData,
                    state.isAbove ? state.token1 : state.token0,
                    state.isAbove ? state.token0 : state.token1,
                    state.swapAmount,
                    state.anchorSqrtPriceX96,
                    true // Goat: the last swap command must be CONTRACT_BALANCE (swapAmount is computed on chain)
                );

                // Goat: the pair's swap budget (NC rows: leaky bucket; CL rows: unlimited) is charged with swapAmount
                // BEFORE the swap (in the input token's own bucket and raw units)
                _consumeSwap(state.token0, state.token1, !state.isAbove, state.swapAmount);

                (state.amountInDelta, state.amountOutDelta) = _routerSwap(
                    Swapper.RouterSwapParams(
                        state.isAbove ? IERC20(state.token1) : IERC20(state.token0),
                        state.isAbove ? IERC20(state.token0) : IERC20(state.token1),
                        state.swapAmount,
                        state.amountOutMin,
                        params.swapData
                    )
                );

                state.amount0 =
                    state.isAbove ? state.amount0 + state.amountOutDelta : state.amount0 - state.amountInDelta;
                state.amount1 =
                    state.isAbove ? state.amount1 - state.amountInDelta : state.amount1 + state.amountOutDelta;
            } else {
                // Goat: an anchored exit with nothing to swap passes the same gates as a swap: the 900 s TWAP veto, the
                // source gate and the pair's swap budget (SwapsOff when closed; 0 consumes nothing)
                if (!_hasMaxTWAPTickDifference(state.vetoPool, TWAPSeconds, state.anchorTick, maxTWAPTickDifference)) {
                    revert TWAPCheckFailed();
                }
                _checkSourceGate(state.vetoPool, state.anchorTick, state.anchorGate);
                _consumeSwap(state.token0, state.token1, !state.isAbove, 0);
            }

            // when swap - protocol reward is removed only from target token (to incentivize optimal swap done by operator)
            // Goat: reward amounts are stored in state.reward0/1 (for the event; same formula)
            if (state.isAbove) {
                state.reward0 = state.amount0 * params.rewardX64 / Q64;
                state.amount0 -= state.reward0;
            } else {
                // Goat: reward stored in state.reward1 (same formula)
                state.reward1 = state.amount1 * params.rewardX64 / Q64;
                state.amount1 -= state.reward1;
            }
        } else {
            // reward is taken as configured
            // Goat: reward amounts stored in state.reward0/1 (same formula); the swap-less branch reads no price
            state.reward0 = state.amount0 * params.rewardX64 / Q64;
            state.reward1 = state.amount1 * params.rewardX64 / Q64;
            state.amount0 -= state.reward0;
            state.amount1 -= state.reward1;
        }

        state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);

        // Goat: effects before interactions: config deleted and events emitted before the owner payout

        // delete config for position
        delete positionConfigs[params.tokenId];
        // Goat: config owner
        delete positionConfigOwners[params.tokenId];
        emit PositionConfigured(params.tokenId, false, false, false, 0, 0, 0, 0, false, 0);

        // log event
        // Goat: isSwap = a swap ran (swapAmount is set only on the swap side; 0 = nothing swapped)
        emit Executed(
            params.tokenId, msg.sender, state.swapAmount != 0, state.amount0, state.amount1, state.token0, state.token1
        );
        // Goat: execution details
        emit GoatExitExecuted(
            params.tokenId,
            state.anchored,
            state.triggerTick,
            state.tick,
            state.amountOutMin,
            state.reward0,
            state.reward1
        );

        if (state.amount0 != 0) {
            _transferToken(state.owner, IERC20(state.token0), state.amount0, true);
        }
        if (state.amount1 != 0) {
            _transferToken(state.owner, IERC20(state.token1), state.amount1, true);
        }
    }

    // Goat: best-effort: true only when the table's anchor reads and lies on a configured swap side. A failed read (no
    // table, swaps paused, stale feed, unlisted pair, no veto pool) returns false, so the swap-less side keeps its spot
    // trigger. Running out of gas inside the read cannot fake `false`: the 1/64 of gas left after it cannot pay for the
    // decrease, collect and payout that follow.
    function _anchorTriggersSwap(address token0, address token1, uint24 fee, PositionConfig memory config)
        internal
        view
        returns (bool)
    {
        if (!config.token0Swap && !config.token1Swap) return false;
        GoatPairTable t = pairTable;
        if (address(t) == address(0)) return false;
        try t.anchor(token0, token1, fee) returns (int24 a, uint160, uint16, address v) {
            return v != address(0)
                && (a < config.token0TriggerTick ? config.token0Swap : a >= config.token1TriggerTick && config.token1Swap);
        } catch {
            return false;
        }
    }

    // function to configure a token to be used with this runner
    // it needs to have approvals set for this contract beforehand
    // Goat: nonReentrant
    function configToken(uint256 tokenId, PositionConfig calldata config) external nonReentrant {
        if (config.isActive) {
            if (config.token0TriggerTick >= config.token1TriggerTick) {
                revert InvalidConfig();
            }
        }

        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        // Goat: onlyFees disabled
        if (config.onlyFees) {
            revert InvalidConfig();
        }
        // Goat: an active config must be executable: execute needs rewardX64 == exitFeeX64 <= maxRewardX64 (the fee can
        // only go down, so a config that passes here stays executable)
        if (config.isActive && config.maxRewardX64 < exitFeeX64) {
            revert InvalidConfig();
        }
        // Goat: slippage cap of 1%
        _checkSlippageCap(config.token0SlippageX64, config.token1SlippageX64);
        // Goat: an active config with a swap only on a listed pair (in the pair table, fee tier covered; every listed
        // pair has a veto pool); a swap-less exit works on every pair (it reads no table)
        if (config.isActive && (config.token0Swap || config.token1Swap)) {
            (,, address token0, address token1, uint24 fee,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
            // Goat: only the legs of the enabled swap sides are checked: token0Swap -> token0 input (zeroForOne),
            // token1Swap -> token1 input; a closed budget on an unused leg does not reject the config
            _requireAnchoredPair(token0, token1, fee, config.token0Swap, config.token1Swap);
        }

        positionConfigs[tokenId] = config;
        // Goat: config owner
        positionConfigOwners[tokenId] = msg.sender;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.token0Swap,
            config.token1Swap,
            config.token0TriggerTick,
            config.token1TriggerTick,
            config.token0SlippageX64,
            config.token1SlippageX64,
            config.onlyFees,
            config.maxRewardX64
        );
    }

    // Goat: management method to lower the fixed exit fee (onlyOwner); it can't be raised. nonReentrant.
    function setExitFee(uint64 feeX64) external onlyOwner nonReentrant {
        if (feeX64 > exitFeeX64) {
            revert InvalidConfig();
        }
        exitFeeX64 = feeX64;
        emit ExitFeeUpdated(msg.sender, feeX64);
    }

    // Goat: the TWAP setting is fixed (veto 900 s / 150 ticks, bounded in the constructor); always reverts
    // (nonReentrant kept for uniformity)
    function setTWAPConfig(uint16, uint32) public override onlyOwner nonReentrant {
        revert InvalidConfig();
    }

    // Goat: binds the pair table once (it cannot change later; the table's rows change under its own 24 h timelock);
    // onlyOwner, then nonReentrant
    function setPairTable(GoatPairTable table) external onlyOwner nonReentrant {
        _setPairTable(table);
    }

    // Goat: the two-step ownership transfer is nonReentrant too (onlyOwner first). The override is in AutoRange and
    // AutoExit rather than in Automator, because AutoRange inherits Ownable2Step through two paths (Transformer and
    // Automator) and needs its own override anyway.
    function transferOwnership(address newOwner) public override onlyOwner nonReentrant {
        super.transferOwnership(newOwner);
    }

    // Goat: the pending-owner check (same message as OpenZeppelin Ownable2Step) runs before nonReentrant
    function acceptOwnership() public override onlyPendingOwner nonReentrant {
        super.acceptOwnership();
    }

    // Goat: renounceOwnership disabled (without an owner, unpausing and adding operators would become impossible)
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }
}
