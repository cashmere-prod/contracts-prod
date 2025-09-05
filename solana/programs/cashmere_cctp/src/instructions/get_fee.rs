use anchor_lang::prelude::*;
use crate::{
    state::Config,
    utils::calculate_fee,
};


pub fn get_fee_ix(ctx: Context<GetFeeContext>, fee: u64, amount: u64) -> Result<u64> {
    Ok(calculate_fee(amount, ctx.accounts.config.fee_bp, fee))
}

#[derive(Accounts)]
#[instruction(destination_domain: u32)]
pub struct GetFeeContext<'info> {
    #[account(seeds=[b"config"], bump)]
    pub config: Account<'info, Config>,
}

