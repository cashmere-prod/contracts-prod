pub mod token_messenger_minter_program;
pub mod token_messenger_minter_program_v2;

use anchor_lang::solana_program::{pubkey, pubkey::Pubkey};

pub const MESSAGE_TRANSMITTER_PROGRAM_ID: Pubkey =
    pubkey!("CCTPmbSD7gX1bxKPAmg77w8oFzNFpaQiQUWD43TKaecd");
pub const TOKEN_MESSENGER_MINTER_PROGRAM_ID: Pubkey =
    pubkey!("CCTPiPYPc6AsJuwueEnWgSgucamXDZwBd53dQ11YiKX3");
pub const MESSAGE_TRANSMITTER_V2_PROGRAM_ID: Pubkey =
    pubkey!("CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC");
pub const TOKEN_MESSENGER_MINTER_V2_PROGRAM_ID: Pubkey =
    pubkey!("CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe");
pub const USDC_MINT: Pubkey =
    pubkey!("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");

#[macro_export]
macro_rules! impl_anchor_account_readonly {
    ($anchor_acc:ty, $owner:expr, $disc:expr) => {
        impl anchor_lang::Owner for $anchor_acc {
            fn owner() -> anchor_lang::solana_program::pubkey::Pubkey {
                $owner
            }
        }
        impl anchor_lang::Discriminator for $anchor_acc {
            const DISCRIMINATOR: &'static [u8] = &$disc;
        }

        impl anchor_lang::AccountDeserialize for $anchor_acc {
            fn try_deserialize(buf: &mut &[u8]) -> anchor_lang::Result<Self> {
                require!(
                    buf.len() >= 8,
                    anchor_lang::error::ErrorCode::AccountDidNotDeserialize
                );
                require!(
                    buf[..8] == *<Self as anchor_lang::Discriminator>::DISCRIMINATOR,
                    anchor_lang::error::ErrorCode::AccountDiscriminatorMismatch,
                );
                Self::try_deserialize_unchecked(buf)
            }

            fn try_deserialize_unchecked(buf: &mut &[u8]) -> Result<Self> {
                Self::deserialize(&mut &buf[8..]).map_err(Into::into)
            }
        }

        impl anchor_lang::AccountSerialize for $anchor_acc {}
    };
}

pub use impl_anchor_account_readonly;
