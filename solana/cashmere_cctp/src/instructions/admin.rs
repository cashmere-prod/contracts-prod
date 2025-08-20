use anchor_lang::prelude::*;
use crate::state::Config;
use crate::errors::ParamError;

pub fn set_paused_ix(ctx: Context<ConfigContext>, paused: bool) -> Result<()> {
    require!(ctx.accounts.owner.key() == ctx.accounts.config.owner, ParamError::AdminUnauthorized);
    ctx.accounts.config.paused = paused;
    Ok(())
}

pub fn set_fee_bp_ix(ctx: Context<ConfigContext>, fee_bp: u64) -> Result<()> {
    require!(ctx.accounts.owner.key() == ctx.accounts.config.owner, ParamError::AdminUnauthorized);
    require!(fee_bp <= 100, ParamError::FeeTooHigh);
    ctx.accounts.config.fee_bp = fee_bp;
    Ok(())
}

pub fn set_signer_key_ix(ctx: Context<ConfigContext>, signer_key: [u8; 32]) -> Result<()> {
    require!(ctx.accounts.owner.key() == ctx.accounts.config.owner, ParamError::AdminUnauthorized);
    ctx.accounts.config.signer_key = signer_key;
    Ok(())
}

pub fn set_fee_collector_ix(ctx: Context<ConfigContext>, fee_collector_sol: Pubkey, fee_collector_usdc: Pubkey) -> Result<()> {
    require!(ctx.accounts.owner.key() == ctx.accounts.config.owner, ParamError::AdminUnauthorized);
    ctx.accounts.config.fee_collector_sol = fee_collector_sol;
    ctx.accounts.config.fee_collector_usdc = fee_collector_usdc;
    Ok(())
}

pub fn set_gas_drop_collector_ix(ctx: Context<ConfigContext>, gas_drop_collector_sol: Pubkey, gas_drop_collector_usdc: Pubkey) -> Result<()> {
    require!(ctx.accounts.owner.key() == ctx.accounts.config.owner, ParamError::AdminUnauthorized);
    ctx.accounts.config.gas_drop_collector_sol = gas_drop_collector_sol;
    ctx.accounts.config.gas_drop_collector_usdc = gas_drop_collector_usdc;
    Ok(())
}

pub fn set_max_usdc_gas_drop_ix(ctx: Context<ConfigContext>, max_gas: u64) -> Result<()> {
    require!(ctx.accounts.owner.key() == ctx.accounts.config.owner, ParamError::AdminUnauthorized);
    ctx.accounts.config.max_usdc_gas_drop = max_gas;
    Ok(())
}

pub fn set_max_native_gas_drop_ix(ctx: Context<ConfigContext>, destination_domain: u32, max_gas: u64) -> Result<()> {
    require!(destination_domain < 32, ParamError::InvalidDomain);
    require!(ctx.accounts.owner.key() == ctx.accounts.config.owner, ParamError::AdminUnauthorized);
    ctx.accounts.config.max_native_gas_drop[destination_domain as usize] = max_gas;
    Ok(())
}

pub fn transfer_ownership_ix(ctx: Context<TransferOwnershipContext>, new_owner: Pubkey) -> Result<()> {
    require!(ctx.accounts.owner.key() == ctx.accounts.config.owner, ParamError::AdminUnauthorized);
    ctx.accounts.config.owner = new_owner;
    Ok(())
}

#[derive(Accounts)]
pub struct ConfigContext<'info> {
    #[account(mut, seeds=[b"config"], bump)]
    pub config: Account<'info, Config>,

    #[account(mut)]
    pub owner: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct TransferOwnershipContext<'info> {
    #[account(mut, seeds=[b"config"], bump)]
    pub config: Account<'info, Config>,

    #[account(mut)]
    pub owner: Signer<'info>,
}
