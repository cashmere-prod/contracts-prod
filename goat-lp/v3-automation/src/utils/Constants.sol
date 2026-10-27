// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

abstract contract Constants {
    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q128 = 2 ** 128;
    uint256 internal constant Q160 = 2 ** 160;

    error Unauthorized();
    error Reentrancy();
    error NotConfigured();
    error NotReady();
    error InvalidConfig();
    error TWAPCheckFailed();
    error WrongContract();
    error InvalidToken();

    error SwapFailed();
    error SlippageError();
    error MissingSwapData();
    error SwapAmountTooLarge();

    error ExceedsMaxReward();
    error InvalidPool();
    error ChainlinkPriceError();
    error PriceDifferenceExceeded();
    error SequencerDown();
    error SequencerGracePeriodNotOver();
    error SequencerUptimeFeedInvalid();

    error CollateralFail();
    error MinLoanSize();
    error GlobalDebtLimit();
    error GlobalLendLimit();
    error DailyDebtIncreaseLimit();
    error DailyLendIncreaseLimit();
    error InsufficientLiquidity();
    error NotLiquidatable();
    error InterestNotUpdated();
    error TransformNotAllowed();
    error TransformFailed();
    error CollateralFactorExceedsMax();
    error CollateralValueLimit();
    error NoLiquidity();
    error DebtChanged();
    error NeedsRepay();
    error NoSharesRepayed();

    error SelfSend();
    error NotSupportedWhatToDo();
    error SameToken();
    error AmountError();
    error CollectError();
    error TransferError();

    error TooMuchEtherSent();
    error NoEtherToken();
    error EtherSendFailed();
    error NotWETH();

    error NotEnoughReward();
    error SameRange();
    error NotSupportedFeeTier();
}
