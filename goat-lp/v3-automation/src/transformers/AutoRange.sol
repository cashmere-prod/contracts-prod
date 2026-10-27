// SPDX-License-Identifier: BUSL-1.1
// Modified by Goat for Robinhood Chain (chain 4663); Goat's changes are commented with "Goat:".
// Source: revert-finance/lend@7e85a81 src/transformers/AutoRange.sol.
// Main changes: the trigger and the new range use the anchor (the outside price from GoatPairTable) instead of the
// pool's spot price, and the new range is centred on it; listed pairs with a veto pool only; a 900 s TWAP veto, a gate
// between spot and anchor before the swap and at mint, and a minimum output from the anchor price net of the pool fee;
// the swap must be the one the new range needs (direction and amount within a band computed on chain); swaps go through
// the Universal Router only, with route, depth and swap-budget checks. Fixed 0.15% range fee that can only be lowered;
// the config is bound to the owner who wrote it; owed tokens are collected to the owner first; the new position is
// minted directly to the owner; vaults and the combined autoCompound are disabled; pause and nonReentrant.
// Goat: pragma pinned to the compiler of the deployed build (solc 0.8.24)
pragma solidity 0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../automators/Automator.sol";
import "../transformers/Transformer.sol";
// Goat: Robinhood Chain constants, anchor and route checks
import "../goat/GoatRobinhood.sol";

/// @title AutoRange
/// @notice Allows operator of AutoRange contract (Revert controlled bot) to change range for configured positions
/// And optionally to autocompound position (depending on configuration)
/// Positions need to be approved (setApprovalForAll) for the contract and configured with configToken method
/// When executed a new position is created and automatically configured the same way as the original position
/// When position is inside Vault - transform is called
// Goat: GoatRobinhood (anchor, constants)
// Goat: ReentrancyGuard now comes from Automator (Revert: "Transformer, Automator, ReentrancyGuard")
contract AutoRange is Transformer, Automator, GoatRobinhood {
    event RangeChanged(uint256 indexed oldTokenId, uint256 indexed newTokenId);
    // Goat: extra execution event (Revert's events are kept as is)
    event GoatRangeExecuted(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        int24 anchorTick,
        int24 spotTickBeforeSwap,
        int24 spotTickAtMint,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amountOutMin,
        uint256 reward0,
        uint256 reward1
    );
    // Goat: range fee changes
    event RangeFeeUpdated(address account, uint64 feeX64);
    // Goat: vaults are disabled
    error VaultsDisabled();
    event PositionConfigured(
        uint256 indexed tokenId,
        int32 lowerTickLimit,
        int32 upperTickLimit,
        int32 lowerTickDelta,
        int32 upperTickDelta,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        bool onlyFees,
        bool autoCompound,
        uint64 maxRewardX64
    );
    event AutoCompounded(
        uint256 indexed tokenId,
        uint256 amountAdded0,
        uint256 amountAdded1,
        uint256 reward0,
        uint256 reward1,
        address token0,
        address token1
    );

    // config changes
    event AutoCompoundRewardUpdated(address account, uint64 totalRewardX64);

    constructor(
        INonfungiblePositionManager _npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Automator(_npm, _operator, _withdrawer, _TWAPSeconds, _maxTWAPTickDifference, _universalRouter, _zeroxAllowanceHolder) {
        // Goat: Robinhood Chain (4663) only, read from the constructor arguments (not immutables); the factory lookup
        // is a cross-check independent of PoolAddress
        _checkRobinhoodDeployment(_npm.WETH9(), IUniswapV3Factory(_npm.factory()).getPool(WETH, USDG, 100));
        // Goat: veto TWAP bounds: TWAPSeconds in [900, 1080] and maxTWAPTickDifference = 150; deployed with (900, 150)
        _checkVetoConfig(_TWAPSeconds, _maxTWAPTickDifference);
        // Goat: fixed swap router (Universal Router 2.1.1, immutable); the 0x AllowanceHolder path is disabled
        // (address(0))
        _checkSwapVenue(_npm.factory(), _universalRouter, _zeroxAllowanceHolder);
    }

    // defines when and how a position can be changed by operator
    // when a position is adjusted config for the position is cleared and copied to the newly created position
    struct PositionConfig {
        // needs more than int24 because it can be [-type(uint24).max,type(uint24).max]
        int32 lowerTickLimit; // if negative also in-range positions may be adjusted / if 0 out of range positions may be adjusted
        int32 upperTickLimit; // if negative also in-range positions may be adjusted / if 0 out of range positions may be adjusted
        int32 lowerTickDelta; // this amount is added to current tick (floored to tickspacing) to define lowerTick of new position
        int32 upperTickDelta; // this amount is added to current tick (floored to tickspacing) to define upperTick of new position
        uint64 token0SlippageX64; // max price difference from current pool price for swap / Q64 for token0
        uint64 token1SlippageX64; // max price difference from current pool price for swap / Q64 for token1
        bool onlyFees; // if only fees maybe used for protocol reward
        bool autoCompound; // if this position can be autocompounded
        uint64 maxRewardX64; // max allowed reward percentage of fees or full position
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public positionConfigs;

    // Goat: the owner who wrote the config; the config stops applying when the NFT changes owner
    mapping(uint256 => address) public positionConfigOwners;

    /// @notice params for execute()
    struct ExecuteParams {
        uint256 tokenId;
        bool swap0To1;
        uint256 amountIn; // if this is set to 0 no swap happens
        bytes swapData;
        uint256 amountRemoveMin0; // min amount to be removed from liquidity
        uint256 amountRemoveMin1; // min amount to be removed from liquidity
        uint256 amountAddMin0; // min amount to be added to liquidity
        uint256 amountAddMin1; // min amount to be added to liquidity
        uint256 deadline; // for uniswap operations
        uint64 rewardX64; // which reward will be used for protocol, can be max configured amount (considering onlyFees)
    }

    struct ExecuteState {
        address owner;
        address realOwner;
        IUniswapV3Pool pool;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAmount0;
        uint256 feeAmount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint128 liquidity;
        uint256 protocolReward0;
        uint256 protocolReward1;
        uint256 amountOutMin;
        uint256 amountInDelta;
        uint256 amountOutDelta;
        uint256 newTokenId;
        // Goat: anchor, ticks for the event, new range and owed tokens
        int24 anchorTick;
        uint160 anchorSqrtPriceX96;
        int24 spotTickBeforeSwap;
        int24 spotTickAtMint;
        int24 newTickLower;
        int24 newTickUpper;
        uint128 owed0;
        uint128 owed1;
        // Goat: the pair's gate G and veto pool from the pair table (always set: _getAnchor rejects address(0)); the
        // swap floor
        uint16 anchorGate;
        IUniswapV3Pool vetoPool;
        uint64 floorX64;
    }

    // reward handling for autocompound
    uint64 public constant MAX_REWARD_X64 = uint64(Q64 / 50); // 2%
    uint64 public totalRewardX64 = MAX_REWARD_X64; // 2%

    // Goat: fixed range fee = 0.15% (floor(Q64 * 15 / 10000)) of the amounts added to the new position; the owner can
    // only lower it
    uint64 public constant MAX_RANGE_FEE_X64 = 27670116110564327;
    uint64 public rangeFeeX64 = MAX_RANGE_FEE_X64;

    // Goat: minimum width of an active config: W = ud - ld >= max(MIN_RANGE_WIDTH, 2 * (G + ts)). A constant: lowering
    // it needs a new deployment.
    int256 public constant MIN_RANGE_WIDTH = 400;

    /**
     * @notice Adjust token (which is in a Vault) - via transform method
     * Can only be called from configured operator account - vault must be configured as well
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    // Goat: the vault path is disabled: always Unauthorized (the ABI is kept)
    function executeWithVault(ExecuteParams calldata, address) external {
        revert Unauthorized();
    }

    /**
     * @notice Adjust token directly (must be in correct state)
     * Can only be called only from configured operator account, or vault via transform
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    // Goat: whenNotPaused and nonReentrant. executeWithVault does not need them: the vault path is disabled (vaults[]
    // is always empty, so it reverts with Unauthorized), and in Revert's design the vault calls back into execute.
    function execute(ExecuteParams calldata params) external whenNotPaused nonReentrant {
        _validateExecutionCaller(params.tokenId);

        PositionConfig memory config = positionConfigs[params.tokenId];

        if (config.lowerTickDelta == config.upperTickDelta) {
            revert NotConfigured();
        }

        // Goat: the reward is not the operator's choice; it must equal the fixed fee (Revert's maximum stays as the
        // owner's consent limit)
        if (params.rewardX64 != rangeFeeX64) {
            revert FeeMismatch();
        }

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        ExecuteState memory state;

        // Goat: is the owner who wrote the config still the owner? (a transfer invalidates the config)
        state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);
        if (state.owner != positionConfigOwners[params.tokenId]) {
            revert NotConfigured();
        }

        // get position info
        // Goat: tokensOwed is read as well
        (,, state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity,,, state.owed0, state.owed1) =
            nonfungiblePositionManager.positions(params.tokenId);
        // Goat: owed tokens are first collected DIRECTLY to the owner (they never enter this contract, and the fee is
        // based on the position alone), so dust added to the position by anyone cannot block the move
        if (state.owed0 != 0 || state.owed1 != 0) {
            nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams(params.tokenId, state.owner, type(uint128).max, type(uint128).max)
            );
        }

        (state.amount0, state.amount1, state.feeAmount0, state.feeAmount1) = _decreaseFullLiquidityAndCollect(
            params.tokenId, state.liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline
        );

        // if only fees reward is removed before adding
        if (config.onlyFees) {
            state.protocolReward0 = state.feeAmount0 * params.rewardX64 / Q64;
            state.protocolReward1 = state.feeAmount1 * params.rewardX64 / Q64;
            state.amount0 -= state.protocolReward0;
            state.amount1 -= state.protocolReward1;
        }

        if (params.amountIn > (params.swap0To1 ? state.amount0: state.amount1)) {
            revert SwapAmountTooLarge();
        }

        // get pool info
        state.pool = _getPool(state.token0, state.token1, state.fee);
        (state.sqrtPriceX96, state.currentTick,,,,,) = state.pool.slot0();

        // Goat: the anchor from the pair table (Chainlink, or the reference pool's TWAP for NC rows), with the pair's
        // own gate G and veto pool; any problem reverts (no fallback)
        (state.anchorTick, state.anchorSqrtPriceX96, state.anchorGate, state.vetoPool) =
            _getAnchor(state.token0, state.token1, state.fee);

        // Goat: readiness is judged from the anchor, not the spot (Revert's limit meaning is unchanged)
        if (
            state.anchorTick < state.tickLower - config.lowerTickLimit
                || state.anchorTick >= state.tickUpper + config.upperTickLimit
        ) {
            // Goat: gate before the swap: |spot - anchor| <= G (the pair's G)
            _checkAnchorGate(state.currentTick, state.anchorTick, state.anchorGate);
            state.spotTickBeforeSwap = state.currentTick;

            // check TWAP deviation (this is done for swap and non-swap operations)
            // operation is only allowed when price is close to TWAP price to prevent sandwich attacks
            // Goat: veto = |TWAP900 of the veto pool - anchor| <= K; the floor comes from the anchor with slippage net
            // of the pool fee (_floorX64 = _feeNetX64 plus a headroom h, h = 0 on v3). The veto pool is the pair's pool
            // from the table; there is no path without a veto (every listed pair has one).
            state.floorX64 = _floorX64(params.swap0To1 ? config.token0SlippageX64 : config.token1SlippageX64, state.fee);
            state.amountOutMin = _validateSwap(
                params.swap0To1,
                params.amountIn,
                state.vetoPool, // Goat: the pair's veto pool (Revert: state.pool)
                state.anchorTick, // Goat: anchor tick (Revert: state.currentTick)
                state.anchorSqrtPriceX96, // Goat: floor from the anchor (Revert: state.sqrtPriceX96)
                TWAPSeconds,
                maxTWAPTickDifference,
                // Goat: fee-net floor with headroom h (Revert: raw slippage). The swap floor uses the lower of the
                // route's fee and the pool's own fee (_phiStar), so a cheaper route cannot widen it; state.floorX64
                // (own pool fee only) is used just for the need band (the keeper's model).
                _floorX64(
                    params.swap0To1 ? config.token0SlippageX64 : config.token1SlippageX64,
                    _phiStar(state.fee, params.swapData, params.amountIn)
                )
            );
            // Goat: the source pool's (veto or reference) 60 s and 10 s TWAPs and its spot must be within G of the
            // anchor (with or without a swap)
            _checkSourceGate(state.vetoPool, state.anchorTick, state.anchorGate);

            // Goat: Universal Router only; hops only through the pair's tokens and WETH/USDG in canonical fee tiers,
            // with a shallow-pool check per hop (Swapper does not swap when swapData is empty, so there is nothing to
            // check then)
            if (params.amountIn != 0 && params.swapData.length != 0) {
                _checkRoute(
                    params.swapData,
                    params.swap0To1 ? state.token0 : state.token1,
                    params.swap0To1 ? state.token1 : state.token0,
                    params.amountIn,
                    state.anchorSqrtPriceX96,
                    false // Goat: no CONTRACT_BALANCE requirement (AutoRange's amountIn is chosen by the keeper)
                );
            }
            // Goat: only the needed swap: the operator's direction and effective amount (0 when swapData is empty, as
            // Swapper then does not swap) must lie in the need band computed on chain for the new anchor-centred range
            // (above it: Revert's SwapAmountTooLarge; below it, or no swap while one is needed: SwapAmountTooSmall)
            _checkSwapNeedForNewRange(params.swap0To1, params.swapData.length != 0 ? params.amountIn : 0, state, config);

            // Goat: the pair's swap budget (NC rows: leaky bucket; CL rows: unlimited). A move re-mints the WHOLE
            // principal around the anchor, so every move (with or without a swap) charges the principal of both legs
            // (token0 to the token0 bucket, token1 to the token1 bucket, each in its own raw units), before the swap
            // and before other external calls. A closed pair (budget 0) stops swap-less moves too (SwapsOff).
            _consumeSwap(state.token0, state.token1, true, state.amount0);
            _consumeSwap(state.token0, state.token1, false, state.amount1);
            // Goat: empty swapData means "no swap" here (as in _checkRoute and the need band above);
            // Swapper._routerSwap fails closed (MissingSwapData) on amountIn != 0 with empty swapData, so it is not
            // called
            if (params.amountIn != 0 && params.swapData.length != 0) {
                (state.amountInDelta, state.amountOutDelta) = _routerSwap(
                    Swapper.RouterSwapParams(
                        params.swap0To1 ? IERC20(state.token0) : IERC20(state.token1),
                        params.swap0To1 ? IERC20(state.token1) : IERC20(state.token0),
                        params.amountIn,
                        state.amountOutMin,
                        params.swapData
                    )
                );

                state.amount0 =
                    params.swap0To1 ? state.amount0 - state.amountInDelta : state.amount0 + state.amountOutDelta;
                state.amount1 =
                    params.swap0To1 ? state.amount1 + state.amountOutDelta : state.amount1 - state.amountInDelta;

                // update tick
                (state.sqrtPriceX96, state.currentTick,,,,,) = state.pool.slot0();
            }

            // Goat: gate after the swap (with or without a swap): the pool must be within G of the anchor at mint
            _checkAnchorGate(state.currentTick, state.anchorTick, state.anchorGate);
            state.spotTickAtMint = state.currentTick;

            // Goat: the new range is centred on the anchor, rounded to the nearest tick spacing (the spot is not used
            // for the centre)
            (int32 newLower, int32 newUpper) = _rangeFromAnchor(
                state.anchorTick, config.lowerTickDelta, config.upperTickDelta, _getTickSpacing(state.fee)
            );

            // Goat: SameRange compares with the new anchor-centred range (Revert: baseTick + delta)
            if (newLower == state.tickLower && newUpper == state.tickUpper) {
                revert SameRange();
            }
            // Goat: the anchor-centred range is stored in state
            state.newTickLower = SafeCast.toInt24(newLower); // reverts if out of valid range
            state.newTickUpper = SafeCast.toInt24(newUpper); // reverts if out of valid range

            // max amount to add - removing max potential fees (if config.onlyFees - the have been removed already)
            state.maxAddAmount0 = config.onlyFees ? state.amount0 : state.amount0 * Q64 / (params.rewardX64 + Q64);
            state.maxAddAmount1 = config.onlyFees ? state.amount1 : state.amount1 * Q64 / (params.rewardX64 + Q64);
            // Goat: zero liquidity -> NotReady (instead of the mint's data-less revert)
            _requireMintableLiquidity(state);

            INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams(
                address(state.token0),
                address(state.token1),
                state.fee,
                // Goat: anchor-centred range
                state.newTickLower,
                state.newTickUpper,
                state.maxAddAmount0,
                state.maxAddAmount1,
                params.amountAddMin0, 
                params.amountAddMin1, 
                // Goat: minted directly to the owner (no callback)
                state.owner,
                params.deadline
            );

            // approve npm
            SafeERC20.safeIncreaseAllowance(IERC20(state.token0), address(nonfungiblePositionManager), state.maxAddAmount0);
            SafeERC20.safeIncreaseAllowance(IERC20(state.token1), address(nonfungiblePositionManager), state.maxAddAmount1);

            // Goat: mint is done directly to the owner - it is not a safemint (no onERC721Received callback)
            (state.newTokenId,, state.amountAdded0, state.amountAdded1) = nonfungiblePositionManager.mint(mintParams);

            // remove remaining approval
            SafeERC20.safeApprove(IERC20(state.token0), address(nonfungiblePositionManager), 0);
            SafeERC20.safeApprove(IERC20(state.token1), address(nonfungiblePositionManager), 0);

            // Goat: the owner was read at entry (Revert read ownerOf here)

            // get the real owner - if owner is vault - for sending leftover tokens
            // Goat: vaults is always empty (setVault is disabled), so this is dead code kept to stay close to Revert's
            // structure
            state.realOwner = state.owner;
            if (vaults[state.owner]) {
                state.realOwner = IVault(state.owner).ownerOf(params.tokenId);
            }

            // Goat: Revert's "send the new nft to the owner / vault" safeTransferFrom is removed (minted directly to
            // the owner)

            // protocol reward is calculated based on added amount (to incentivize optimal swap done by operator)
            if (!config.onlyFees) {
                state.protocolReward0 = state.amountAdded0 * params.rewardX64 / Q64;
                state.protocolReward1 = state.amountAdded1 * params.rewardX64 / Q64;
                state.amount0 -= state.protocolReward0;
                state.amount1 -= state.protocolReward1;
            }

            // Goat: checks-effects-interactions: config writes, deletes and events happen BEFORE the payout to the
            // owner
            // copy token config for new token
            positionConfigs[state.newTokenId] = config;
            // Goat: config owner
            positionConfigOwners[state.newTokenId] = state.owner;
            emit PositionConfigured(
                state.newTokenId,
                config.lowerTickLimit,
                config.upperTickLimit,
                config.lowerTickDelta,
                config.upperTickDelta,
                config.token0SlippageX64,
                config.token1SlippageX64,
                config.onlyFees,
                config.autoCompound,
                config.maxRewardX64
            );

            // delete config for old position
            delete positionConfigs[params.tokenId];
            // Goat: config owner
            delete positionConfigOwners[params.tokenId];
            emit PositionConfigured(params.tokenId, 0, 0, 0, 0, 0, 0, false, false, 0);

            emit RangeChanged(params.tokenId, state.newTokenId);
            // Goat: execution details
            emit GoatRangeExecuted(
                params.tokenId,
                state.newTokenId,
                state.anchorTick,
                state.spotTickBeforeSwap,
                state.spotTickAtMint,
                state.newTickLower,
                state.newTickUpper,
                // Goat: the floor is reported only for a swap that actually ran (Swapper does not swap with empty
                // swapData)
                params.amountIn != 0 && params.swapData.length != 0 ? state.amountOutMin : 0,
                state.protocolReward0,
                state.protocolReward1
            );

            // send leftover to real owner
            if (state.amount0 - state.amountAdded0 != 0) {
                _transferToken(state.realOwner, IERC20(state.token0), state.amount0 - state.amountAdded0, true);
            }
            if (state.amount1 - state.amountAdded1 != 0) {
                _transferToken(state.realOwner, IERC20(state.token1), state.amount1 - state.amountAdded1, true);
            }
        } else {
            revert NotReady();
        }
    }

    /// @notice params for autoCompound()
    struct AutoCompoundParams {
        // tokenid to autocompound
        uint256 tokenId;
        // swap direction - calculated off-chain
        bool swap0To1;
        // swap amount - calculated off-chain - if this is set to 0 no swap happens
        uint256 amountIn;
        // for uniswap operations
        uint256 deadline;
    }

    // state used during autocompound execution
    struct AutoCompoundState {
        address owner;
        address realOwner;
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        uint256 priceX96;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 compounded0;
        uint256 compounded1;
        int24 tick;
        uint160 sqrtPriceX96;
        uint256 amountInDelta;
        uint256 amountOutDelta;
    }

    /**
     * @notice Autocompound position (which is in a Vault) - via transform method
     * Can only be called from configured operator account - vault must be configured as well
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    // Goat: the vault path is disabled: always Unauthorized (the ABI is kept)
    function autoCompoundWithVault(AutoCompoundParams calldata, address) external {
        revert Unauthorized();
    }

     /**
     * @notice Autocompound position directly (must be in correct state)
     * Can only be called only from configured operator account, or vault via transform
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    // Goat: the combined autoCompound is disabled (configToken rejects autoCompound), so its body is removed and every
    // call reverts: Pausable's error while paused, Unauthorized for other callers, NotConfigured for an operator. The
    // ABI is kept.
    function autoCompound(AutoCompoundParams calldata params) external nonReentrant whenNotPaused {
        _validateExecutionCaller(params.tokenId);
        revert NotConfigured();
    }

    // function to configure a token to be used with this runner
    // it needs to have approvals set for this contract beforehand
    // Goat: nonReentrant
    function configToken(uint256 tokenId, address vault, PositionConfig calldata config) external nonReentrant {
        _validateOwner(nonfungiblePositionManager, tokenId, vault);

        // lower tick must be always below or equal to upper tick - if they are equal - range adjustment is deactivated
        if (config.lowerTickDelta > config.upperTickDelta) {
            revert InvalidConfig();
        }

        // Goat: onlyFees disabled (one fee model)
        if (config.onlyFees) {
            revert InvalidConfig();
        }
        // Goat: the combined autoCompound is disabled (Revert's version swaps with minOut 0, checked only against the
        // pool's own TWAP)
        if (config.autoCompound) {
            revert InvalidConfig();
        }
        // Goat: slippage cap of 1%
        _checkSlippageCap(config.token0SlippageX64, config.token1SlippageX64);
        // Goat: an enabling config only on a listed pair (in the pair table, fee tier covered; every listed pair has a
        // veto pool, so AutoRange never runs on a pair without one)
        if (config.lowerTickDelta != config.upperTickDelta) {
            (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) =
                nonfungiblePositionManager.positions(tokenId);
            _requireAnchoredPair(token0, token1, fee);
            // Goat: the bounds of an active config are checked in one place (_checkRangeConfig). G comes from the
            // table's own choice at config time without reading feeds: GoatPairTable.gateFor uses the same rule as
            // anchor(), with no copy here.
            _checkRangeConfig(config, _getTickSpacing(fee), pairTable.gateFor(token0, token1, fee), liquidity);
        }

        positionConfigs[tokenId] = config;
        // Goat: ownership was checked by _validateOwner (the vault path is disabled, so the owner is msg.sender)
        positionConfigOwners[tokenId] = msg.sender;

        emit PositionConfigured(
            tokenId,
            config.lowerTickLimit,
            config.upperTickLimit,
            config.lowerTickDelta,
            config.upperTickDelta,
            config.token0SlippageX64,
            config.token1SlippageX64,
            config.onlyFees,
            config.autoCompound,
            config.maxRewardX64
        );
    }

    /**
     * @notice Management method to lower autocompound reward(onlyOwner)
     * @param _totalRewardX64 new total reward (can't be higher than current total reward)
     */
    // Goat: nonReentrant
    function setAutoCompoundReward(uint64 _totalRewardX64) external onlyOwner nonReentrant {
        if (_totalRewardX64 > totalRewardX64) {
            revert InvalidConfig();
        }
        totalRewardX64 = _totalRewardX64;
        emit AutoCompoundRewardUpdated(msg.sender, _totalRewardX64);
    }

    // Goat: management method to lower the fixed range fee (onlyOwner); it can't be raised. nonReentrant.
    function setRangeFee(uint64 feeX64) external onlyOwner nonReentrant {
        if (feeX64 > rangeFeeX64) {
            revert InvalidConfig();
        }
        rangeFeeX64 = feeX64;
        emit RangeFeeUpdated(msg.sender, feeX64);
    }

    // Goat: the vault path is disabled (a registered vault would act as an operator without a timelock); vaults[x] is
    // false for every x. Always reverts (nonReentrant kept for uniformity).
    function setVault(address) external override onlyOwner nonReentrant {
        revert VaultsDisabled();
    }

    // Goat: the TWAP setting is fixed (veto 900 s / 150 ticks, bounded in the constructor); always reverts
    // (nonReentrant kept for uniformity)
    function setTWAPConfig(uint16, uint32) public override onlyOwner nonReentrant {
        revert InvalidConfig();
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

    // Goat: separate from execute to keep its stack small: the new range (same computation as in execute), the same
    // floor and the pair's gate
    function _checkSwapNeedForNewRange(
        bool swap0To1,
        uint256 amountIn,
        ExecuteState memory state,
        PositionConfig memory config
    ) internal view {
        int24 ts = _getTickSpacing(state.fee);
        (int32 lo, int32 hi) = _rangeFromAnchor(state.anchorTick, config.lowerTickDelta, config.upperTickDelta, ts);
        // Goat: the minimum width is checked again with the CURRENT gate at execution: the config-time check
        // (_checkRangeConfig) cannot see a gate G raised later (queuePair/addPair, a CL to NC switch, gateHighFee), and
        // an old config, or the config execute copies to the new tokenId, must not run with a collapsed need band (the
        // new range keeps the config's width ud - ld, see _rangeFromAnchor). The new range must also lie within the
        // tick bounds (a clear error instead of the mint's TLM/TUM or a toInt24 overflow). A violation reverts with
        // InvalidConfig: the position is not moved until the owner writes a wider config.
        if (
            int256(hi) - int256(lo) < _minRangeWidth(state.anchorGate, ts) || lo < TickMath.MIN_TICK
                || hi > TickMath.MAX_TICK
        ) {
            revert InvalidConfig();
        }
        _checkSwapNeed(
            GoatNeed(
                swap0To1,
                amountIn,
                state.amount0,
                state.amount1,
                SafeCast.toInt24(lo),
                SafeCast.toInt24(hi),
                state.anchorTick,
                state.anchorSqrtPriceX96,
                state.anchorGate,
                state.floorX64
            )
        );
    }

    // Goat: bounds of an active config, in one place (InvalidConfig on any violation):
    //   0 <= lowerTickLimit, upperTickLimit <= type(uint24).max (the readiness arithmetic cannot overflow)
    //   |ld + ud| <= ts: with W >= 2 * ts this gives ld <= -ts/2 < 0 < ts/2 <= ud, so the new range contains the anchor
    //   W = ud - ld is a multiple of ts (otherwise the upper tick is misaligned and every mint reverts)
    //   W >= max(MIN_RANGE_WIDTH, 2 * (G + ts)), with G the pair's gate at config time (the need band cannot collapse);
    //     G can rise later, so execution checks the same minimum with the current G (_checkSwapNeedForNewRange);
    //     G = 0 (the table does not cover this fee tier) -> InvalidConfig
    //   W <= 2 * MAX_TICK (_rangeFromAnchor cannot overflow int32). This does not prove the range is mintable: when the
    //     anchor is far from tick 0, a very wide range can cross the tick bounds; execution then reverts with
    //     InvalidConfig (no value moves)
    //   maxRewardX64 >= rangeFeeX64 (the reward equals the fee, which can only go down, so the config stays usable)
    //   the position must have liquidity (an active config on an empty NFT could never run)
    function _checkRangeConfig(PositionConfig calldata c, int24 ts, uint16 gate, uint128 liquidity) internal view {
        int256 maxLimit = int256(uint256(type(uint24).max));
        int256 w = int256(c.upperTickDelta) - int256(c.lowerTickDelta);
        int256 s = int256(c.lowerTickDelta) + int256(c.upperTickDelta);
        if (
            c.lowerTickLimit < 0 || c.upperTickLimit < 0 || c.lowerTickLimit > maxLimit || c.upperTickLimit > maxLimit
                || s > ts || s < -ts || w % ts != 0 || gate == 0 || w < _minRangeWidth(gate, ts)
                || w > 2 * int256(TickMath.MAX_TICK) || c.maxRewardX64 < rangeFeeX64 || liquidity == 0
        ) {
            revert InvalidConfig();
        }
    }

    // Goat: the one minimum width (same expression at config time and at execution): max(MIN_RANGE_WIDTH, 2 * (G + ts))
    function _minRangeWidth(uint16 gate, int24 ts) internal pure returns (int256 m) {
        m = 2 * (int256(uint256(gate)) + ts);
        if (m < MIN_RANGE_WIDTH) m = MIN_RANGE_WIDTH;
    }

    // Goat: the same computation as NPM.mint (slot0 price, new range, maximum amounts to add): zero liquidity reverts
    // with NotReady instead of the pool's data-less revert (an emptied or dust position; no value moves)
    function _requireMintableLiquidity(ExecuteState memory state) internal pure {
        if (
            LiquidityAmounts.getLiquidityForAmounts(
                state.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(state.newTickLower),
                TickMath.getSqrtRatioAtTick(state.newTickUpper),
                state.maxAddAmount0,
                state.maxAddAmount1
            ) == 0
        ) {
            revert NotReady();
        }
    }

    // Goat: binds the pair table once (it cannot change later; the table's rows change under its own 24 h timelock);
    // onlyOwner, then nonReentrant
    function setPairTable(GoatPairTable table) external onlyOwner nonReentrant {
        _setPairTable(table);
    }

    // get tick spacing for fee tier (cached when possible)
    function _getTickSpacing(uint24 fee) internal view returns (int24) {
        if (fee == 10000) {
            return 200;
        } else if (fee == 3000) {
            return 60;
        } else if (fee == 500) {
            return 10;
        } else {
            int24 spacing = IUniswapV3Factory(factory).feeAmountTickSpacing(fee);
            if (spacing <= 0) {
                revert NotSupportedFeeTier();
            }
            return spacing;
        }
    }

    function _validateExecutionCaller(uint256 tokenId) internal view {
        if (vaults[msg.sender]) {
            _validateCaller(nonfungiblePositionManager, tokenId);
        } else if (operators[msg.sender]) {
            if (vaults[nonfungiblePositionManager.ownerOf(tokenId)]) {
                revert Unauthorized();
            }
        } else {
            revert Unauthorized();
        }
    }
}
