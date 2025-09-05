use anchor_lang::prelude::*;
use bytemuck::{Pod, Zeroable};

#[derive(Debug, Copy, Clone, Pod, Zeroable)]
#[repr(C)]
pub struct Ed25519SignatureOffsets {
    pub signature_offset: u16,
    pub signature_instruction_index: u16,
    pub public_key_offset: u16,
    pub public_key_instruction_index: u16,
    pub message_data_offset: u16,
    pub message_data_size: u16,
    pub message_instruction_index: u16,
}

#[account]
#[derive(Debug, InitSpace)]
pub struct Config {
    pub owner: Pubkey,
    pub fee_collector_sol: Pubkey,
    pub fee_collector_usdc: Pubkey,
    pub gas_drop_collector_sol: Pubkey,
    pub gas_drop_collector_usdc: Pubkey,
    pub fee_bp: u64,
    pub nonce: u64,
    pub signer_key: [u8; 32],
    pub max_usdc_gas_drop: u64, // in micro-USDC (default 100m)
    pub max_native_gas_drop: u64,
    pub paused: bool,
}

#[account]
#[derive(Debug, InitSpace)]
pub struct Custodian {
    pub bump: u8,
}

impl Custodian {
    pub const SEED_PREFIX: &'static [u8] = b"emitter";
    pub const ATA_SEED_PREFIX: &'static [u8] = b"__custody";
}
