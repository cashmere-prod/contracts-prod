use anchor_lang::{prelude::*, solana_program::{
    self,
    sysvar::instructions as sysvar,
}};
use anchor_spl::token::{
    self,
    Token,
    TokenAccount,
};
use crate::{
    state::{
        Custodian,
        Config,
    },
    events::TransferEvent,
    cctp::{
        TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
        MESSAGE_TRANSMITTER_V2_PROGRAM_ID,
        USDC_MINT,
        token_messenger_minter_program_v2::{
            cpi::{
                DepositForBurn,
                DepositForBurnParams,
            },
        },
    },
};
use super::pre_transfer;



/*
fee structure:
- percentage fee is always taken in USDC
- server-side fee is taken either in USDC or SOL, depending on `fee_is_native`
- gas drop is taken either in USDC or SOL, depending on `fee_is_native`
*/

pub fn transfer_v2_ix(
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
    let amount = pre_transfer(
        &ctx.accounts.config,
        &ctx.accounts.signature.to_account_info(),
        &ctx.accounts.owner_token_account.to_account_info(),
        &ctx.accounts.burn_token_account.to_account_info(),
        &ctx.accounts.fee_collector_sol_account.to_account_info(),
        &ctx.accounts.fee_collector_usdc_account.to_account_info(),
        &ctx.accounts.gas_drop_collector_sol_account.to_account_info(),
        &ctx.accounts.gas_drop_collector_usdc_account.to_account_info(),
        &ctx.accounts.owner.to_account_info(),
        &ctx.accounts.custodian,
        &ctx.accounts.token_program.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        usdc_amount,
        destination_domain,
        fee,
        deadline,
        gas_drop_amount,
        fee_is_native,
        2,
    )?;
    let custodian_seeds: &[&[&[u8]]] = &[&[Custodian::SEED_PREFIX, &[ctx.accounts.custodian.bump]]];

    let cpi_ctx = CpiContext::new_with_signer(
        ctx.accounts.token_messenger_minter_program.to_account_info(),
        DepositForBurn {
            owner: ctx.accounts.custodian.to_account_info(),
            event_rent_payer: ctx.accounts.owner.to_account_info(),
            sender_authority_pda: ctx.accounts.token_messenger_minter_sender_authority.to_account_info(),
            burn_token_account: ctx.accounts.burn_token_account.to_account_info(),
            denylist_account: ctx.accounts.denylist_account.to_account_info(),
            message_transmitter: ctx.accounts.message_transmitter.to_account_info(),
            token_messenger: ctx.accounts.token_messenger.to_account_info(),
            remote_token_messenger: ctx.accounts.remote_token_messenger.to_account_info(),
            token_minter: ctx.accounts.token_minter.to_account_info(),
            local_token: ctx.accounts.local_token.to_account_info(),
            burn_token_mint: ctx.accounts.burn_token_mint.to_account_info(),
            message_sent_event_data: ctx.accounts.message_sent_event_data.to_account_info(),
            message_transmitter_program: ctx.accounts.message_transmitter_program.to_account_info(),
            token_messenger_minter_program: ctx.accounts.token_messenger_minter_program.to_account_info(),
            token_program: ctx.accounts.token_program.to_account_info(),
            system_program: ctx.accounts.system_program.to_account_info(),
            event_authority: ctx.accounts.token_messenger_minter_event_authority.to_account_info(),
        },
        custodian_seeds,
    );

    let args = DepositForBurnParams {
        amount,
        destination_domain,
        mint_recipient: recipient,
        destination_caller: [0; 32],
        max_fee,
        min_finality_threshold,
    };

    const ANCHOR_IX_SELECTOR: [u8; 8] = [215, 60, 61, 46, 114, 55, 128, 176];

    solana_program::program::invoke_signed(
        &solana_program::instruction::Instruction {
            program_id: TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
            accounts: cpi_ctx.to_account_metas(None),
            data: (ANCHOR_IX_SELECTOR, args).try_to_vec()?,
        },
        &cpi_ctx.to_account_infos(),
        cpi_ctx.signer_seeds,
    )?;

    ctx.accounts.config.nonce += 1;

    emit!(TransferEvent {
        destination_domain,
        nonce: ctx.accounts.config.nonce,
        recipient,
        solana_owner,
        user: ctx.accounts.owner.key(),
        amount,
        gas_drop_amount,
        cctp_nonce: -2,
        fee_is_native,
        cctp_message: ctx.accounts.message_sent_event_data.key(),
    });

    token::close_account(CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        token::CloseAccount {
            account: ctx.accounts.burn_token_account.to_account_info(),
            destination: ctx.accounts.owner.to_account_info(),
            authority: ctx.accounts.custodian.to_account_info(),
        },
        custodian_seeds,
    ))
}

#[derive(Accounts)]
#[instruction(usdc_amount: u64, destination_domain: u32)]
pub struct TransferV2Context<'info> {
    // Cashmere CCTP config
    #[account(mut, seeds=[b"config"], bump)]
    pub config: Box<Account<'info, Config>>,

    // Sender ATA
    #[account(mut, token::mint = burn_token_mint)]
    pub owner_token_account: Box<Account<'info, TokenAccount>>,

    // CCTP Message account
    #[account(mut)]
    message_sent_event_data: Signer<'info>,

    // Sender
    #[account(mut)]
    pub owner: Signer<'info>,

    #[account(
        mut,
        address = config.fee_collector_sol,
    )]
    pub fee_collector_sol_account: SystemAccount<'info>,

    #[account(
        mut,
        address = config.fee_collector_usdc,
    )]
    pub fee_collector_usdc_account: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        address = config.gas_drop_collector_sol,
    )]
    pub gas_drop_collector_sol_account: SystemAccount<'info>,

    #[account(
        mut,
        address = config.gas_drop_collector_usdc,
    )]
    pub gas_drop_collector_usdc_account: Box<Account<'info, TokenAccount>>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,

    /// This program's emitter authority.
    ///
    /// Seeds must be \["emitter"\].
    #[account(
        seeds = [Custodian::SEED_PREFIX],
        bump = custodian.bump,
    )]
    custodian: Box<Account<'info, Custodian>>,

    /// Circle-supported mint.
    ///
    /// CHECK: Mutable. This token account's mint must be the same as the one found in the CCTP
    /// Token Messenger Minter program's local token account.
    #[account(
        mut,
        address = USDC_MINT,
    )]
    burn_token_mint: AccountInfo<'info>,

    /// Temporary custody token account. This account will be closed at the end of this instruction.
    /// It just acts as a conduit to allow this program to be the transfer initiator in the CCTP
    /// message.
    ///
    /// Seeds must be \["__custody"\].
    #[account(
        init,
        payer = owner,
        token::mint = burn_token_mint,
        token::authority = custodian,
        seeds = [Custodian::ATA_SEED_PREFIX],
        bump,
    )]
    burn_token_account: Box<Account<'info, token::TokenAccount>>,
    
    /// CHECK: denylist PDA
    /// Account is denylisted if the account exists at the expected PDA.
    #[account(
        mut,
        seeds = [b"denylist_account", custodian.to_account_info().key().as_ref()],
        seeds::program = TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
        bump,
    )]
    denylist_account: UncheckedAccount<'info>,

    /// CHECK: Local token account, which this program uses to validate the `mint` used to burn.
    ///
    /// Mutable. Seeds must be \["local_token", mint\] (CCTP Token Messenger Minter program).
    #[account(
        mut,
        seeds = [b"local_token", USDC_MINT.as_ref()],
        seeds::program = TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
        bump,
    )]
    local_token: AccountInfo<'info>,

    /// CHECK: Must equal CCTP Token Messenger Minter program ID.
    #[account(address = TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID)]
    token_messenger_minter_program: UncheckedAccount<'info>,

    /// CHECK: Must equal CCTP Message Transmitter program ID.
    #[account(address = MESSAGE_TRANSMITTER_V2_PROGRAM_ID)]
    message_transmitter_program: UncheckedAccount<'info>,

    /// CHECK: Seeds must be \["__event_authority"\] (CCTP Token Messenger Minter program).
    #[account(
        seeds = [b"__event_authority"],
        seeds::program = TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
        bump,
    )]
    token_messenger_minter_event_authority: UncheckedAccount<'info>,

    /// CHECK: Mutable. Seeds must be \["message_transmitter"\] (CCTP Message Transmitter program).
    #[account(
        mut,
        seeds = [b"message_transmitter"],
        seeds::program = MESSAGE_TRANSMITTER_V2_PROGRAM_ID,
        bump,
    )]
    message_transmitter: UncheckedAccount<'info>,

    /// CHECK: Seeds must be \["token_messenger"\] (CCTP Token Messenger Minter program).
    #[account(
        seeds = [b"token_messenger"],
        seeds::program = TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
        bump,
    )]
    token_messenger: UncheckedAccount<'info>,

    /// CHECK: Seeds must be \["remote_token_messenger"\, remote_domain.to_string()] (CCTP Token
    /// Messenger Minter program).
    #[account(
        seeds = [b"remote_token_messenger", destination_domain.to_string().as_bytes()],
        seeds::program = TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
        bump,
    )]
    remote_token_messenger: UncheckedAccount<'info>,

    /// CHECK: Seeds must be \["token_minter"\] (CCTP Token Messenger Minter program).
    #[account(
        seeds = [b"token_minter"],
        seeds::program = TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
        bump,
    )]
    token_minter: UncheckedAccount<'info>,

    /// CHECK: Seeds must be \["sender_authority"\] (CCTP Token Messenger Minter program).
    #[account(
        seeds = [b"sender_authority"],
        seeds::program = TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID,
        bump,
    )]
    token_messenger_minter_sender_authority: UncheckedAccount<'info>,

    /// CHECK: Safe because it's a sysvar account
    #[account(address = sysvar::ID)]
    pub signature: AccountInfo<'info>,
}
