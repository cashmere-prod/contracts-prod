use anchor_lang::{
    prelude::*,
    system_program,
};
use borsh::{BorshSerialize, to_vec};
use crate::{
    state::{Config, Custodian},
    errors::{
        TransferError,
        ParamError,
    },
    utils::{
        verify_ed25519_ix,
        calculate_fee,
    },
};
use anchor_spl::token::{
    self,
    Transfer as SplTransfer
};

#[derive(BorshSerialize)]
pub struct TransferParams {
    cctp_version: u8,
    local_domain: u32,
    destination_domain: u32,
    fee: u64,
    deadline: u64,
    fee_is_native: bool,
}

pub fn pre_transfer<'info>(
    config: &Config,
    signature: &AccountInfo<'info>,
    owner_token_account: &AccountInfo<'info>,
    burn_token_account: &AccountInfo<'info>,
    fee_collector_sol_account: &AccountInfo<'info>,
    fee_collector_usdc_account: &AccountInfo<'info>,
    gas_drop_collector_sol_account: &AccountInfo<'info>,
    gas_drop_collector_usdc_account: &AccountInfo<'info>,
    owner: &AccountInfo<'info>,
    custodian: &Account<'info, Custodian>,
    token_program: &AccountInfo<'info>,
    system_program: &AccountInfo<'info>,
    usdc_amount: u64,
    destination_domain: u32,
    fee: u64,
    deadline: u64,
    gas_drop_amount: u64,
    fee_is_native: bool,
    cctp_version: u8,
) -> Result<u64> {
    require!(destination_domain < 32, ParamError::InvalidDomain);
    require!(!config.paused, TransferError::Paused);

    let msg = TransferParams {
        cctp_version,
        local_domain: 5,
        destination_domain,
        fee,
        deadline,
        fee_is_native,
    };
    let msg_bytes = to_vec(&msg)?;
    let ed25519_ix = &signature.to_account_info();
    match verify_ed25519_ix(ed25519_ix, &msg_bytes, &config.signer_key) {
        Err(e) => return Err(e),
        _ => {},
    };

    let clock = Clock::get()?;
    if clock.unix_timestamp as u64 > deadline {
        return Err(TransferError::DeadlineExpired.into());
    }

    let usdc_fee_amount = calculate_fee(usdc_amount, config.fee_bp, if fee_is_native { 0 } else { fee });
    require!(usdc_amount >= usdc_fee_amount, TransferError::FeeExceedsAmount);
    if fee_is_native {
        let native_gas_drop_limit = config.max_native_gas_drop;
        require!(native_gas_drop_limit == 0 || gas_drop_amount <= native_gas_drop_limit, TransferError::GasDropLimitExceeded);
    } else {
        let usdc_gas_drop_limit = config.max_usdc_gas_drop;
        require!(usdc_gas_drop_limit == 0 || gas_drop_amount <= usdc_gas_drop_limit, TransferError::GasDropLimitExceeded);
    }

    // collect fee in USDC
    token::transfer(CpiContext::new(
        token_program.to_account_info(),
        SplTransfer {
            from: owner_token_account.to_account_info(),
            to: fee_collector_usdc_account.to_account_info(),
            authority: owner.to_account_info(),
        },
    ), usdc_fee_amount)?;

    if fee_is_native {
        // collect fee in SOL
        system_program::transfer(CpiContext::new(
            system_program.to_account_info(),
            system_program::Transfer {
                from: owner.to_account_info(),
                to: fee_collector_sol_account.to_account_info(),
            },
        ), fee)?;
        // collect gas drop in SOL
        if gas_drop_amount > 0 {
            system_program::transfer(CpiContext::new(
                system_program.to_account_info(),
                system_program::Transfer {
                    from: owner.to_account_info(),
                    to: gas_drop_collector_sol_account.to_account_info(),
                },
            ), gas_drop_amount)?;
        }
    } else {
        // collect gas drop in USDC
        if gas_drop_amount > 0 {
            token::transfer(CpiContext::new(
                token_program.to_account_info(),
                SplTransfer {
                    from: owner_token_account.to_account_info(),
                    to: gas_drop_collector_usdc_account.to_account_info(),
                    authority: owner.to_account_info(),
                },
            ), gas_drop_amount)?;
        }
    }

    let amount = usdc_amount - usdc_fee_amount;

    let custodian_seeds: &[&[&[u8]]] = &[&[Custodian::SEED_PREFIX, &[custodian.bump]]];

    // transfer the rest
    token::transfer(CpiContext::new_with_signer(
        token_program.to_account_info(),
        SplTransfer {
            from: owner_token_account.to_account_info(),
            to: burn_token_account.to_account_info(),
            authority: owner.to_account_info(),
        },
        custodian_seeds,
    ), amount)?;

    Ok(amount)
}
