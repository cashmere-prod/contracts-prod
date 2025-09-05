use anchor_lang::prelude::*;

#[error_code]
#[derive(Eq, PartialEq)]
pub enum SignatureVerificationError {
    #[msg("Signature not verified")]
    NotSigVerified,
    #[msg("Invalid signature data")]
    InvalidSignatureData,
    #[msg("Invalid Data format")]
    InvalidDataFormat,
    #[msg("Less data than expected")]
    LessDataThanExpected,
    #[msg("Epoch too large")]
    EpochTooLarge,
    #[msg("Invalid message data")]
    InvalidMessageData,
    #[msg("Invalid signer")]
    InvalidSignature,
}

#[error_code]
#[derive(Eq, PartialEq)]
pub enum TransferError {
    #[msg("Deadline expired")]
    DeadlineExpired,
    #[msg("Invalid token program")]
    InvalidTokenProgram,
    #[msg("Gas drop limit exceeded")]
    GasDropLimitExceeded,
    #[msg("Insufficient USDC amount")]
    FeeExceedsAmount,
    #[msg("Insufficient SOL amount")]
    NativeAmountTooLow,
    #[msg("Contract is paused")]
    Paused,
}

#[error_code]
pub enum ParamError {
    #[msg("Fee basis points too high")]
    FeeTooHigh,
    #[msg("Only admin can update parameters")]
    AdminUnauthorized,
    #[msg("Invalid domain")]
    InvalidDomain,
}
