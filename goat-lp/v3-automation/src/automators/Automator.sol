// SPDX-License-Identifier: BUSL-1.1
// Modified by Goat for Robinhood Chain; Goat's changes are commented with "Goat:".
// Source: revert-finance/lend@7e85a81 src/automators/Automator.sol.
// Main changes: Pausable with a guardian; a 24 h timelock for adding operators, unpausing and replacing the guardian
// (a queued entry lapses 7 days after its eta); ReentrancyGuard on every state-changing external entry point, with the
// authorization check first; setTWAPConfig split into a virtual wrapper and an internal function; collects go through
// _collectExact (the reported amount must match the balance change, up to 2 wei of share rounding); fee withdrawals
// emit events; ETH payouts use bounded gas and fall back to WETH.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
// Goat: OpenZeppelin 4.9 Pausable (MIT)
import "@openzeppelin/contracts/security/Pausable.sol";
// Goat: OpenZeppelin 4.9 ReentrancyGuard (MIT), inherited here instead of in AutoRange's own inheritance list
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Goat: unused imports IUniswapV3Factory and TickMath removed (SafeCast kept)
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../lib/IWETH9.sol";
import "../utils/Swapper.sol";
import "../interfaces/IVault.sol";

// Goat: Pausable and ReentrancyGuard added (one _status per contract: execute, configToken, admin and recovery
// functions share the same lock)
abstract contract Automator is Ownable2Step, Swapper, Pausable, ReentrancyGuard {

    uint32 public constant MIN_TWAP_SECONDS = 60; // 1 minute
    uint32 public constant MAX_TWAP_TICK_DIFFERENCE = 200; // 2%

    // admin events
    event OperatorChanged(address newOperator, bool active);
    event WithdrawerChanged(address newWithdrawer);
    event TWAPConfigChanged(uint32 TWAPSeconds, uint16 maxTWAPTickDifference);
    // Goat: role and timelock events
    event OperatorQueued(address indexed operator, uint256 eta);
    event GuardianChanged(address newGuardian);
    event UnpauseQueued(uint256 eta);
    // Goat: an owner replacement of the guardian is queued (24 h, owner-only queue); eta 0 = queue cleared (cancelled,
    // consumed or overridden). Same signature and indexing as GoatPairTable.GuardianQueued (one ABI decodes both)
    event GuardianQueued(address newGuardian, uint256 eta);
    // Goat: fee withdrawals emit an event (token address(0) = native ETH)
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    // configurable by owner
    mapping(address => bool) public operators;

    address public withdrawer;
    uint32 public TWAPSeconds;
    uint16 public maxTWAPTickDifference;

    // Goat: adding an operator and unpausing wait TIMELOCK; pausing (owner or guardian) and removing an operator are
    // instant
    uint256 public constant TIMELOCK = 24 hours;
    // Goat: a queued entry can be applied until eta + QUEUE_GRACE (inclusive); later it reverts with NotQueued
    uint256 public constant QUEUE_GRACE = 7 days;
    // Goat: the amount collect delivers may be at most this much below the amount it reports (share rounding of
    // stETH-like tokens); a larger shortfall (such as a transfer tax) or an over-delivery reverts with CollectError
    uint256 internal constant COLLECT_ROUNDING_WEI = 2;
    address public guardian;
    uint256 public unpauseEta;
    mapping(address => uint256) public operatorEta;
    // Goat: guardian replacement queued by the owner
    address public pendingGuardian;
    uint256 public guardianEta;
    // Goat: gas forwarded with a native ETH payout; no returndata is copied. If the recipient reverts or needs more
    // gas, the amount is re-wrapped and paid as WETH (the payout never blocks the caller)
    uint256 internal constant ETH_PAYOUT_GAS = 30_000;

    error ZeroAddress();
    // Goat: a timelocked action that was not queued, is not due yet or has lapsed
    error NotQueued();
    // Goat: ownership changes only through the two-step transfer
    error RenounceOwnershipDisabled();

    // Goat: authorization is checked before nonReentrant (an unauthorized caller gets Unauthorized even during another
    // call)
    modifier onlyWithdrawer() {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }
        _;
    }

    // Goat: acceptOwnership authorization (same message as OpenZeppelin 4.9 Ownable2Step.acceptOwnership), checked
    // before nonReentrant
    modifier onlyPendingOwner() {
        require(pendingOwner() == msg.sender, "Ownable2Step: caller is not the new owner");
        _;
    }

    // Goat: pause authorization (owner or guardian), checked before nonReentrant
    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) {
            revert Unauthorized();
        }
        _;
    }

    constructor(
        INonfungiblePositionManager npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _universalRouter,
        address _zeroxAllowanceHolder
    ) Swapper(npm, _universalRouter, _zeroxAllowanceHolder) {
        // Goat: the constructor's operator is active immediately (the deployment itself is public on chain)
        _setOperator(_operator, true);
        setWithdrawer(_withdrawer);
        // Goat: internal function, so a derived contract can disable setTWAPConfig
        _setTWAPConfig(_maxTWAPTickDifference, _TWAPSeconds);
    }

    /**
     * @notice Owner controlled function to set withdrawer address
     * @param _withdrawer withdrawer
     */
    // Goat: nonReentrant
    function setWithdrawer(address _withdrawer) public onlyOwner nonReentrant {
        // Goat: a zero withdrawer would disable fee withdrawal
        if (_withdrawer == address(0)) {
            revert ZeroAddress();
        }
        emit WithdrawerChanged(_withdrawer);
        withdrawer = _withdrawer;
    }

    /**
     * @notice Owner controlled function to activate/deactivate operator address
     * @param _operator operator
     * @param _active active or not
     */
    // Goat: nonReentrant
    function setOperator(address _operator, bool _active) public onlyOwner nonReentrant {
        // Goat: adding works only TIMELOCK after queueOperator; removing is instant and also clears the queue
        if (_active) {
            uint256 eta = operatorEta[_operator];
            if (eta == 0 || block.timestamp < eta) {
                revert NotQueued();
            }
            // Goat: a stale entry (after eta + QUEUE_GRACE) needs a new queueOperator
            if (block.timestamp > eta + QUEUE_GRACE) {
                revert NotQueued();
            }
        }
        delete operatorEta[_operator];
        _setOperator(_operator, _active);
    }

    // Goat: Revert's original setOperator body
    function _setOperator(address _operator, bool _active) internal {
        emit OperatorChanged(_operator, _active);
        operators[_operator] = _active;
    }

    // Goat: queues adding an operator (eta = now + TIMELOCK; emits OperatorQueued); nonReentrant
    function queueOperator(address _operator) external onlyOwner nonReentrant {
        uint256 eta = block.timestamp + TIMELOCK;
        operatorEta[_operator] = eta;
        emit OperatorQueued(_operator, eta);
    }

    // Goat: the guardian can only narrow (pause, revokeOperator) and hand over its own role; nonReentrant. The current
    // guardian hands over (or removes itself) instantly; the owner sets a guardian instantly only while there is none
    // (or re-sets the same one), otherwise only the queued address after TIMELOCK and before eta + QUEUE_GRACE
    // (queueGuardian). The queue is owner-only: the sitting guardian can neither cancel nor clear its own replacement
    // (a guardian handover leaves the owner's queue intact). Replacing a sitting guardian therefore takes TIMELOCK,
    // during which the guardian can still pause or revoke operators.
    function setGuardian(address _guardian) external onlyOwnerOrGuardian nonReentrant {
        address current = guardian;
        if (msg.sender != current || current == address(0)) {
            // owner path (onlyOwnerOrGuardian: a caller that is not the sitting guardian is the owner)
            if (current != address(0) && _guardian != current) {
                uint256 eta = guardianEta;
                if (
                    eta == 0 || pendingGuardian != _guardian || block.timestamp < eta
                        || block.timestamp > eta + QUEUE_GRACE
                ) {
                    revert NotQueued();
                }
            }
            _clearGuardianQueue();
        }
        guardian = _guardian;
        emit GuardianChanged(_guardian);
    }

    // Goat: the owner queues a guardian replacement (eta = now + TIMELOCK; emits GuardianQueued)
    function queueGuardian(address _guardian) external onlyOwner nonReentrant {
        uint256 eta = block.timestamp + TIMELOCK;
        pendingGuardian = _guardian;
        guardianEta = eta;
        emit GuardianQueued(_guardian, eta);
    }

    // Goat: only the owner cancels a queued guardian replacement (as in GoatPairTable.cancelGuardian)
    function cancelGuardian() external onlyOwner nonReentrant {
        _clearGuardianQueue();
    }

    // Goat: clearing a non-empty queue emits GuardianQueued(0, 0); an empty queue emits nothing
    function _clearGuardianQueue() internal {
        if (guardianEta != 0) {
            delete pendingGuardian;
            delete guardianEta;
            emit GuardianQueued(address(0), 0);
        }
    }

    // Goat: narrowing action, instant for owner or guardian: deactivate an operator and drop its queue (removes a
    // keeper key without pausing the swap-less exits of every position)
    function revokeOperator(address _operator) external onlyOwnerOrGuardian nonReentrant {
        delete operatorEta[_operator];
        _setOperator(_operator, false);
    }

    // Goat: owner or guardian, instant. If already paused, only the pending unpause queue is cleared. Authorization is
    // checked in the onlyOwnerOrGuardian modifier, before nonReentrant.
    function pause() external onlyOwnerOrGuardian nonReentrant {
        if (!paused()) {
            _pause();
        }
        if (unpauseEta != 0) {
            delete unpauseEta;
            emit UnpauseQueued(0);
        }
    }

    // Goat: queues an unpause (only while paused); nonReentrant
    function queueUnpause() external onlyOwner whenPaused nonReentrant {
        uint256 eta = block.timestamp + TIMELOCK;
        unpauseEta = eta;
        emit UnpauseQueued(eta);
    }

    // Goat: unpauses once the queued unpause is due; nonReentrant
    function unpause() external onlyOwner nonReentrant {
        uint256 eta = unpauseEta;
        if (eta == 0 || block.timestamp < eta) {
            revert NotQueued();
        }
        // Goat: the unpause queue lapses after eta + QUEUE_GRACE (inclusive) and then needs a fresh queueUnpause
        if (block.timestamp > eta + QUEUE_GRACE) revert NotQueued();
        delete unpauseEta;
        _unpause();
    }

    /**
     * @notice Owner controlled function to increase TWAPSeconds / decrease maxTWAPTickDifference
     */
    // Goat: body moved to _setTWAPConfig; virtual (AutoRange and AutoExit disable it); nonReentrant
    function setTWAPConfig(uint16 _maxTWAPTickDifference, uint32 _TWAPSeconds) public virtual onlyOwner nonReentrant {
        _setTWAPConfig(_maxTWAPTickDifference, _TWAPSeconds);
    }

    // Goat: Revert's original setTWAPConfig body (same limits: at least 60 s, at most 200 ticks)
    function _setTWAPConfig(uint16 _maxTWAPTickDifference, uint32 _TWAPSeconds) internal {
        if (_TWAPSeconds < MIN_TWAP_SECONDS) {
            revert InvalidConfig();
        }
        if (_maxTWAPTickDifference > MAX_TWAP_TICK_DIFFERENCE) {
            revert InvalidConfig();
        }
        emit TWAPConfigChanged(_TWAPSeconds, _maxTWAPTickDifference);
        TWAPSeconds = _TWAPSeconds;
        maxTWAPTickDifference = _maxTWAPTickDifference;
    }

    /**
     * @notice Withdraws token balance (accumulated protocol fee)
     * @param tokens Addresses of tokens to withdraw
     * @param to Address to send to
     */
    // Goat: onlyWithdrawer, then nonReentrant (Revert's check in the body is kept as is)
    function withdrawBalances(address[] calldata tokens, address to) external virtual onlyWithdrawer nonReentrant {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }
        // Goat: no withdrawal to address(0)
        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 i;
        uint256 count = tokens.length;
        address token;
        uint256 balance;
        for (; i < count; ++i) {
            token = tokens[i];
            balance = IERC20(token).balanceOf(address(this));
            if (balance != 0) {
                _transferToken(to, IERC20(token), balance, true);
                // Goat: withdrawal event
                emit Withdrawn(token, to, balance);
            }
        }
    }

    /**
     * @notice Withdraws ETH balance
     * @param to Address to send to
     */
    // Goat: onlyWithdrawer, then nonReentrant (Revert's check in the body is kept as is)
    function withdrawETH(address to) external onlyWithdrawer nonReentrant {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }
        // Goat: no withdrawal to address(0)
        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 balance = address(this).balance;
        if (balance != 0) {
            (bool sent,) = to.call{value: balance}("");
            if (!sent) {
                revert EtherSendFailed();
            }
            // Goat: withdrawal event
            emit Withdrawn(address(0), to, balance);
        }
    }

    // validate if swap can be done with specified oracle parameters - if not possible reverts
    // if possible returns minAmountOut
    function _validateSwap(
        bool swap0For1,
        uint256 amountIn,
        IUniswapV3Pool pool,
        int24 currentTick,
        uint160 sqrtPriceX96,
        uint32 twapPeriod,
        uint16 maxTickDifference,
        uint64 maxPriceDifferenceX64
    ) internal view returns (uint256 amountOutMin) {
        // check if current tick not too far from TWAP
        if (!_hasMaxTWAPTickDifference(pool, twapPeriod, currentTick, maxTickDifference)) {
            revert TWAPCheckFailed();
        }

        // calculate min output price price and percentage
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (swap0For1) {
            amountOutMin = FullMath.mulDiv(amountIn * (Q64 - maxPriceDifferenceX64), priceX96, Q160); // Q160 = Q96 * Q64
        } else {
            amountOutMin = FullMath.mulDiv(amountIn * (Q64 - maxPriceDifferenceX64), Q32, priceX96);
        }
    }

    // Checks if there was not more tick difference
    // returns false if not enough data available or tick difference >= maxDifference
    function _hasMaxTWAPTickDifference(IUniswapV3Pool pool, uint32 twapPeriod, int24 currentTick, uint16 maxDifference)
        internal
        view
        returns (bool)
    {
        (int24 twapTick, bool twapOk) = _getTWAPTick(pool, twapPeriod);
        if (twapOk) {
            int256 res = twapTick - currentTick;
            return res >= -int16(maxDifference) && res <= int16(maxDifference);
        } else {
            return false;
        }
    }

    // gets twap tick from pool history if enough history available
    function _getTWAPTick(IUniswapV3Pool pool, uint32 twapSeconds) internal view returns (int24, bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0; // from (before)
        secondsAgos[1] = twapSeconds; // from (before)

        // pool observe may fail when there is not enough history available
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int24 tick = int24((tickCumulatives[0] - tickCumulatives[1]) / int56(uint56(twapSeconds)));
            if (
                tickCumulatives[0] - tickCumulatives[1] < 0
                    && (tickCumulatives[0] - tickCumulatives[1]) % int32(twapSeconds) != 0
            ) tick--;
            return (tick, true);
        } catch {
            return (0, false);
        }
    }

    function _decreaseFullLiquidityAndCollect(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amountRemoveMin0,
        uint256 amountRemoveMin1,
        uint256 deadline
    ) internal returns (uint256 amount0, uint256 amount1, uint256 feeAmount0, uint256 feeAmount1) {
        if (liquidity != 0) {
            // store in temporarely "misnamed" variables - see comment below
            (feeAmount0, feeAmount1) = nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(
                    tokenId, liquidity, amountRemoveMin0, amountRemoveMin1, deadline
                )
            );
        }
        // Goat: the amount collect reports must match the balance change (_collectExact, otherwise CollectError)
        (amount0, amount1) = _collectExact(tokenId);

        // fee amount is what was collected additionally to liquidity amount
        // Goat: saturating: the measured amount (up to 2 wei of rounding) can be below the principal removed
        feeAmount0 = amount0 > feeAmount0 ? amount0 - feeAmount0 : 0;
        feeAmount1 = amount1 > feeAmount1 ? amount1 - feeAmount1 : 0;
    }

    // Goat: the same check Revert's V3Utils makes: if the amount collect() reports does not match this contract's
    // balance change, revert with CollectError (fail closed). This way a token that charges a tax on transfers out of
    // the pool is never topped up from the protocol fees this contract holds. Share-based (stETH-like) tokens can
    // deliver 1 to 2 wei less than reported; to keep swap-less exits working for them, a delivery at most
    // COLLECT_ROUNDING_WEI below the reported amount is accepted and the measured amount is used (no top-up from the
    // contract's balance). A larger shortfall (a tax) or an over-delivery reverts with CollectError.
    function _collectExact(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (,, address t0, address t1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
        uint256 b0 = IERC20(t0).balanceOf(address(this));
        uint256 b1 = IERC20(t1).balanceOf(address(this));
        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)
        );
        // Goat: reported must equal measured (up to 2 wei of rounding; the measured amount is returned), otherwise
        // CollectError; a balance that drops during collect also reverts with CollectError (not Panic 0x11)
        uint256 a0 = IERC20(t0).balanceOf(address(this));
        uint256 a1 = IERC20(t1).balanceOf(address(this));
        if (a0 < b0 || a1 < b1) {
            revert CollectError();
        }
        amount0 = _collected(a0 - b0, amount0);
        amount1 = _collected(a1 - b1, amount1);
    }

    // Goat: measured delivery `got`, reported `reported`: returns got if got <= reported <= got + COLLECT_ROUNDING_WEI,
    // otherwise reverts with CollectError
    function _collected(uint256 got, uint256 reported) internal pure returns (uint256) {
        if (got > reported || reported - got > COLLECT_ROUNDING_WEI) revert CollectError();
        return got;
    }

    // transfers token (or unwraps WETH and sends ETH)
    function _transferToken(address to, IERC20 token, uint256 amount, bool unwrap) internal {
        if (unwrap && address(weth) == address(token)) {
            weth.withdraw(amount);
            // Goat: bounded gas, no returndata copy; a recipient that cannot take ETH gets WETH instead
            bool sent;
            assembly {
                sent := call(ETH_PAYOUT_GAS, to, amount, 0, 0, 0, 0)
            }
            if (!sent) {
                weth.deposit{value: amount}();
                SafeERC20.safeTransfer(token, to, amount);
            }
        } else {
            SafeERC20.safeTransfer(token, to, amount);
        }
    }

    // needed for WETH unwrapping
    receive() external payable {
        if (msg.sender != address(weth)) {
            revert NotWETH();
        }
    }
}
