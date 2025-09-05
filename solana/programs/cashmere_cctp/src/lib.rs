pub mod cctp;
pub mod state;
pub mod errors;
pub mod events;
pub mod instructions;
pub mod utils;

use anchor_lang::prelude::*;
use instructions::*;

declare_id!("5RsvKL6LFq6yEFiAXEwgYHAN3aLFypeB4AaafdeDnHqM");

#[program]
pub mod cashmere_cctp {
    use super::*;

    // initialize ix

    pub fn initialize(
        ctx: Context<InitializeContext>,
        fee_collector_sol: Pubkey,
        fee_collector_usdc: Pubkey,
        gas_drop_collector_sol: Pubkey,
        gas_drop_collector_usdc: Pubkey,
    ) -> Result<()> {
        initialize_ix(ctx, fee_collector_sol, fee_collector_usdc, gas_drop_collector_sol, gas_drop_collector_usdc)
    }

    // admin ixs

    pub fn set_paused(ctx: Context<ConfigContext>, paused: bool) -> Result<()> {
        set_paused_ix(ctx, paused)
    }

    pub fn set_fee_bp(ctx: Context<ConfigContext>, fee_bp: u64) -> Result<()> {
        set_fee_bp_ix(ctx, fee_bp)
    }

    pub fn set_signer_key(ctx: Context<ConfigContext>, signer_key: [u8; 32]) -> Result<()> {
        set_signer_key_ix(ctx, signer_key)
    }

    pub fn set_fee_collector(ctx: Context<ConfigContext>, fee_collector_sol: Pubkey, fee_collector_usdc: Pubkey) -> Result<()> {
        set_fee_collector_ix(ctx, fee_collector_sol, fee_collector_usdc)
    }

    pub fn set_gas_drop_collector(ctx: Context<ConfigContext>, gas_drop_collector_sol: Pubkey, gas_drop_collector_usdc: Pubkey) -> Result<()> {
        set_gas_drop_collector_ix(ctx, gas_drop_collector_sol, gas_drop_collector_usdc)
    }

    pub fn set_max_usdc_gas_drop(ctx: Context<ConfigContext>, max_gas: u64) -> Result<()> {
        set_max_usdc_gas_drop_ix(ctx, max_gas)
    }

    pub fn set_max_native_gas_drop(ctx: Context<ConfigContext>, max_gas: u64) -> Result<()> {
        set_max_native_gas_drop_ix(ctx, max_gas)
    }

    pub fn transfer_ownership(ctx: Context<TransferOwnershipContext>, new_owner: Pubkey) -> Result<()> {
        transfer_ownership_ix(ctx, new_owner)
    }

    // get fee ix

    pub fn get_fee(ctx: Context<GetFeeContext>, fee: u64, amount: u64) -> Result<u64> {
        get_fee_ix(ctx, fee, amount)
    }

    // transfer

    pub fn transfer(
        ctx: Context<TransferContext>,
        usdc_amount: u64,
        destination_domain: u32,
        recipient: [u8; 32],
        solana_owner: [u8; 32],
        fee: u64,
        deadline: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
    ) -> Result<()> {
        transfer_ix(
            ctx,
            usdc_amount,
            destination_domain,
            recipient,
            solana_owner,
            fee,
            deadline,
            gas_drop_amount,
            fee_is_native,
        )
    }

    pub fn transfer_v2(
        ctx: Context<TransferV2Context>,
        usdc_amount: u64,
        destination_domain: u32,
        recipient: [u8; 32],
        solana_owner: [u8; 32],
        fee: u64,
        deadline: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
        max_fee: u64,
        min_finality_threshold: u32,
    ) -> Result<()> {
        transfer_v2_ix(
            ctx,
            usdc_amount,
            destination_domain,
            recipient,
            solana_owner,
            fee,
            deadline,
            gas_drop_amount,
            fee_is_native,
            max_fee,
            min_finality_threshold,
        )
    }
}









