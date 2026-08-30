use anchor_lang::prelude::*;
use crate::state::Config;
use crate::errors::ParamError;
use crate::events::{
    CollectorSet,
    FeeBpSet,
    MaxGasDropSet,
    OwnershipTransferred,
    PausedSet,
    SignerKeySet,
};

/// Upper bound on the percentage fee, in basis points (1%).
const MAX_FEE_BP: u64 = 100;

/// Rejects the all-zero pubkey.
///
/// The default pubkey is not a usable account: routing fees to it would burn them, and
/// handing ownership to it would leave the config permanently unadministrable. Every
/// admin setter that accepts an address funnels through this check.
fn require_non_default(key: &Pubkey) -> Result<()> {
    require_keys_neq!(*key, Pubkey::default(), ParamError::ZeroAddress);
    Ok(())
}

pub fn set_paused_ix(ctx: Context<ConfigContext>, paused: bool) -> Result<()> {
    ctx.accounts.config.paused = paused;
    emit!(PausedSet { paused });
    Ok(())
}

pub fn set_fee_bp_ix(ctx: Context<ConfigContext>, fee_bp: u64) -> Result<()> {
    require!(fee_bp <= MAX_FEE_BP, ParamError::FeeTooHigh);
    let old_fee_bp = ctx.accounts.config.fee_bp;
    ctx.accounts.config.fee_bp = fee_bp;
    emit!(FeeBpSet { old_fee_bp, new_fee_bp: fee_bp });
    Ok(())
}

pub fn set_signer_key_ix(ctx: Context<ConfigContext>, signer_key: [u8; 32]) -> Result<()> {
    // An all-zero signer key cannot correspond to a usable ed25519 keypair, so accepting it
    // would silently brick every transfer instruction.
    require!(signer_key != [0u8; 32], ParamError::ZeroAddress);
    let old_signer_key = ctx.accounts.config.signer_key;
    ctx.accounts.config.signer_key = signer_key;
    emit!(SignerKeySet { old_signer_key, new_signer_key: signer_key });
    Ok(())
}

pub fn set_fee_collector_ix(ctx: Context<ConfigContext>, fee_collector_sol: Pubkey, fee_collector_usdc: Pubkey) -> Result<()> {
    require_non_default(&fee_collector_sol)?;
    require_non_default(&fee_collector_usdc)?;
    ctx.accounts.config.fee_collector_sol = fee_collector_sol;
    ctx.accounts.config.fee_collector_usdc = fee_collector_usdc;
    emit!(CollectorSet {
        is_gas_drop: false,
        sol_account: fee_collector_sol,
        usdc_account: fee_collector_usdc,
    });
    Ok(())
}

pub fn set_gas_drop_collector_ix(ctx: Context<ConfigContext>, gas_drop_collector_sol: Pubkey, gas_drop_collector_usdc: Pubkey) -> Result<()> {
    require_non_default(&gas_drop_collector_sol)?;
    require_non_default(&gas_drop_collector_usdc)?;
    ctx.accounts.config.gas_drop_collector_sol = gas_drop_collector_sol;
    ctx.accounts.config.gas_drop_collector_usdc = gas_drop_collector_usdc;
    emit!(CollectorSet {
        is_gas_drop: true,
        sol_account: gas_drop_collector_sol,
        usdc_account: gas_drop_collector_usdc,
    });
    Ok(())
}

pub fn set_max_usdc_gas_drop_ix(ctx: Context<ConfigContext>, max_gas: u64) -> Result<()> {
    let old_max = ctx.accounts.config.max_usdc_gas_drop;
    ctx.accounts.config.max_usdc_gas_drop = max_gas;
    emit!(MaxGasDropSet { is_native: false, old_max, new_max: max_gas });
    Ok(())
}

pub fn set_max_native_gas_drop_ix(ctx: Context<ConfigContext>, max_gas: u64) -> Result<()> {
    let old_max = ctx.accounts.config.max_native_gas_drop;
    ctx.accounts.config.max_native_gas_drop = max_gas;
    emit!(MaxGasDropSet { is_native: true, old_max, new_max: max_gas });
    Ok(())
}

/// Single-step ownership handover.
///
/// A two-step (propose/accept) handover would be safer, because a typo here permanently
/// locks out administration. That change requires a `pending_owner` field in `Config`,
/// which does not fit in the space already allocated to the live config account, so it is
/// documented as a follow-up rather than applied here. The zero-address guard below blocks
/// the one unrecoverable input that can be checked on-chain today.
pub fn transfer_ownership_ix(ctx: Context<TransferOwnershipContext>, new_owner: Pubkey) -> Result<()> {
    require_non_default(&new_owner)?;
    let old_owner = ctx.accounts.config.owner;
    ctx.accounts.config.owner = new_owner;
    emit!(OwnershipTransferred { old_owner, new_owner });
    Ok(())
}

#[derive(Accounts)]
pub struct ConfigContext<'info> {
    /// Authorization is enforced declaratively via `has_one`, so it cannot be forgotten in
    /// a handler. Previously each handler repeated the owner check by hand and a new
    /// handler that omitted it would have been silently permissionless.
    #[account(mut, seeds=[b"config"], bump, has_one = owner @ ParamError::AdminUnauthorized)]
    pub config: Account<'info, Config>,

    pub owner: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct TransferOwnershipContext<'info> {
    #[account(mut, seeds=[b"config"], bump, has_one = owner @ ParamError::AdminUnauthorized)]
    pub config: Account<'info, Config>,

    pub owner: Signer<'info>,
}
