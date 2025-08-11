use anchor_lang::prelude::*;

#[event]
pub struct TransferEvent {
    pub destination_domain: u32,
    pub nonce: u64,
    pub recipient: [u8; 32],
    pub solana_owner: [u8; 32],
    pub user: Pubkey,
    pub amount: u64,
    pub gas_drop_amount: u64,
    pub fee_is_native: bool,
    pub cctp_nonce: i64,
    pub cctp_message: Pubkey,
}
