use std::mem;
use anchor_lang::prelude::*;
use mem::size_of;
use crate::{
    state::{
        Custodian,
        Config,
    },
};

pub fn initialize_ix(
    ctx: Context<InitializeContext>,
    fee_collector_sol: Pubkey,
    fee_collector_usdc: Pubkey,
    gas_drop_collector_sol: Pubkey,
    gas_drop_collector_usdc: Pubkey,
) -> Result<()> {
    ctx.accounts.config.paused = false;
    ctx.accounts.config.owner = ctx.accounts.owner.key();
    ctx.accounts.config.fee_collector_sol = fee_collector_sol;
    ctx.accounts.config.fee_collector_usdc = fee_collector_usdc;
    ctx.accounts.config.gas_drop_collector_sol = gas_drop_collector_sol;
    ctx.accounts.config.gas_drop_collector_usdc = gas_drop_collector_usdc;
    ctx.accounts.config.fee_bp = 0;
    ctx.accounts.config.nonce = 0;
    ctx.accounts.config.max_usdc_gas_drop = 100_000_000;
    ctx.accounts.config.max_native_gas_drop = 0;
    ctx.accounts.custodian.set_inner(Custodian {
        bump: ctx.bumps.custodian,
    });
    ctx.accounts.config.signer_key = [0; 32];
    Ok(())
}

#[derive(Accounts)]
pub struct InitializeContext<'info> {
    #[account(init,
              payer = owner,
              space = size_of::<Config>() + 8,
              seeds = [b"config"],
              bump)]
    pub config: Account<'info, Config>,

    #[account(
        init,
        payer = owner,
        space = size_of::<Custodian>() + 8,
        seeds = [Custodian::SEED_PREFIX],
        bump,
    )]
    custodian: Account<'info, Custodian>,

    #[account(mut)]
    pub owner: Signer<'info>,

    pub system_program: Program<'info, System>,
}
