module cashmere_cctp::transfer {
    use token_messenger_minter::deposit_for_burn::{
        create_deposit_for_burn_ticket,
        DepositForBurnTicket,
    };
    use token_messenger_minter::burn_message::BurnMessage;
    use message_transmitter::message::Message;
    use sui::{
        coin,
        coin::Coin,
        event::emit,
        ed25519,
        bcs,
        clock::Clock,
        sui::SUI,
        table,
    };

    const BP: u64 = 10000;
    const MAX_FEE_BP: u64 = 100; // 1%
    /// CCTP domain identifier of Sui. Previously hardcoded inline at the signature site,
    /// where it could drift out of step with the backend without any compiler help.
    const LOCAL_DOMAIN: u32 = 8;
    /// Highest CCTP domain identifier accepted by this module.
    const MAX_DOMAIN: u32 = 32;
    /// Byte length of an ed25519 public key.
    const ED25519_PUBLIC_KEY_LENGTH: u64 = 32;

    const E_WRONG_SIGNATURE: u64 = 0x1000;
    const E_DEADLINE_EXPIRED: u64 = 0x1001;
    const E_GAS_DROP_LIMIT_EXCEEDED: u64 = 0x1002;
    const E_FEE_EXCEEDS_AMOUNT: u64 = 0x1003;
    const E_NATIVE_FEE_TOO_LOW: u64 = 0x1004;
    const E_DUPLICATE_NONCE: u64 = 0x1005;
    const E_PAUSED: u64 = 0x1006;
    const E_INVALID_DOMAIN: u64 = 0x1007;
    const E_ZERO_AMOUNT: u64 = 0x1008;
    const E_INVALID_SIGNER_KEY: u64 = 0x1009;
    const E_ZERO_ADDRESS: u64 = 0x100A;

    const E_MAX_FEE_BP_EXCEEDED: u64 = 0x2000;

    public struct AdminCap has key, store {
        id: UID
    }

    public struct Config has key {
        id: UID,
        fee_collector: address,
        gas_drop_collector: address,
        fee_bp: u64,
        nonce: u256,
        processed_cctp_nonces: table::Table<u64, bool>,
        signer_key: vector<u8>,
        max_usdc_gas_drop: u64,
        max_native_gas_drop: u64,
        paused: bool,
    }

    /// The payload the backend signs to authorize a single transfer.
    ///
    /// Every field that decides where the value goes, how much of it moves, and what the
    /// user is charged is bound in. The previous version covered only the two domains, the
    /// flat `fee`, the `deadline` and `fee_is_native`, so a signature broadcast once could be
    /// reused by anybody for a different `usdc_amount`, `recipient` and `gas_drop_amount`.
    ///
    /// NOTE: changing this struct changes the bytes the backend signer service must sign.
    /// The signer service has to be updated in lockstep with this module.
    public struct TransferParams has drop, copy {
        local_domain: u32,
        destination_domain: u32,
        fee: u64,
        deadline: u64,
        fee_is_native: bool,
        /// Account authorized to spend this quote.
        sender: address,
        /// Gross USDC amount pulled from the user, before fees.
        usdc_amount: u64,
        recipient: address,
        solana_owner: address,
        gas_drop_amount: u64,
    }

    /// Unified event format across chains
    public struct CashmereTransfer has copy, drop {
        destination_domain: u32,
        nonce: u256,
        recipient: address,
        solana_owner: address,
        user: address,
        amount: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
        cctp_nonce: u256,
    }

    /// Receipt tying a prepared burn ticket to the metadata needed for the transfer event.
    ///
    /// Deliberately has no `drop`: it can only be consumed by `post_deposit_for_burn`, which
    /// records the CCTP nonce and emits `CashmereTransfer`. With `drop` a caller could
    /// discard it and complete a burn that this module never accounted for or announced.
    public struct DepositInfo {
        initial_amount: u64,
        solana_owner: address,
        user: address,
        gas_drop_amount: u64,
        fee_is_native: bool,
    }

    public struct Auth has drop {}

    fun init(ctx: &mut TxContext) {
        let config = Config {
            id: object::new(ctx),
            fee_collector: ctx.sender(),
            gas_drop_collector: ctx.sender(),
            fee_bp: 1,
            nonce: 0,
            processed_cctp_nonces: table::new<u64, bool>(ctx),
            signer_key: vector[],
            max_usdc_gas_drop: 100_000_000,
            max_native_gas_drop: 0,
            paused: false,
        };
        transfer::share_object(config);

        transfer::transfer(AdminCap {id: object::new(ctx)}, ctx.sender());
    }

    public fun set_paused(_: &AdminCap, config: &mut Config, paused: bool) {
        config.paused = paused;
    }

    public fun set_fee_bp(_: &AdminCap, config: &mut Config, fee_bp: u64) {
        assert!(fee_bp <= MAX_FEE_BP, E_MAX_FEE_BP_EXCEEDED);
        config.fee_bp = fee_bp;
    }

    public fun set_signer_key(_: &AdminCap, config: &mut Config, signer_key: vector<u8>) {
        // `ed25519_verify` silently returns false for a wrong-length key, which would brick
        // every transfer with an indistinguishable "wrong signature" error.
        assert!(signer_key.length() == ED25519_PUBLIC_KEY_LENGTH, E_INVALID_SIGNER_KEY);
        config.signer_key = signer_key;
    }

    public fun set_fee_collector(_: &AdminCap, config: &mut Config, fee_collector: address) {
        assert!(fee_collector != @0x0, E_ZERO_ADDRESS);
        config.fee_collector = fee_collector;
    }

    public fun set_gas_drop_collector(_: &AdminCap, config: &mut Config, gas_drop_collector: address) {
        assert!(gas_drop_collector != @0x0, E_ZERO_ADDRESS);
        config.gas_drop_collector = gas_drop_collector;
    }

    public fun set_max_usdc_gas_drop(_: &AdminCap, config: &mut Config, limit: u64) {
        config.max_usdc_gas_drop = limit;
    }

    public fun set_max_native_gas_drop(_: &AdminCap, config: &mut Config, limit: u64) {
        config.max_native_gas_drop = limit;
    }

    public fun get_fee(config: &Config, amount: u64, static_fee: u64): u64 {
        amount * config.fee_bp / BP + static_fee
    }

    public fun prepare_deposit_for_burn_ticket<T: drop>(
        mut usdc_coin: Coin<T>,
        mut native_fee_coin: Coin<SUI>,
        destination_domain: u32,
        recipient: address,
        solana_owner: address,
        fee: u64,
        deadline: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
        signature: vector<u8>,
        config: &Config,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (DepositForBurnTicket<T, Auth>, DepositInfo) {
        assert!(!config.paused, E_PAUSED);

        let auth = Auth {};

        let gas_drop_native = if (gas_drop_amount > 0 && fee_is_native) {
            (&mut native_fee_coin).split(gas_drop_amount, ctx)
        } else {
            coin::zero<SUI>(ctx)
        };
        let gas_drop_usdc = if (gas_drop_amount > 0 && !fee_is_native) {
            (&mut usdc_coin).split(gas_drop_amount, ctx)
        } else {
            coin::zero<T>(ctx)
        };

        let usdc_value = usdc_coin.value();
        assert!(usdc_value > 0, E_ZERO_AMOUNT);
        // A domain this module cannot reach, or Sui's own domain, would burn the USDC with no
        // remote messenger able to mint it back.
        assert!(destination_domain < MAX_DOMAIN, E_INVALID_DOMAIN);
        assert!(destination_domain != LOCAL_DOMAIN, E_INVALID_DOMAIN);

        let usdc_fee_amount = get_fee(config, usdc_value, if (fee_is_native) { 0 } else { fee });
        // Strict comparison: an equal fee would leave nothing to bridge and CCTP rejects a
        // zero-amount burn with an opaque error.
        assert!(usdc_fee_amount < usdc_value, E_FEE_EXCEEDS_AMOUNT);

        if (fee_is_native) {
            assert!(gas_drop_amount <= config.max_native_gas_drop, E_GAS_DROP_LIMIT_EXCEEDED);
        } else {
            assert!(gas_drop_amount <= config.max_usdc_gas_drop, E_GAS_DROP_LIMIT_EXCEEDED);
        };

        let msg_struct = TransferParams {
            local_domain: LOCAL_DOMAIN,
            destination_domain,
            fee,
            deadline,
            fee_is_native,
            sender: ctx.sender(),
            usdc_amount: usdc_value,
            recipient,
            solana_owner,
            gas_drop_amount,
        };
        let msg = bcs::to_bytes(&msg_struct);
        assert!(ed25519::ed25519_verify(&signature, &config.signer_key, &msg), E_WRONG_SIGNATURE);
        assert!(deadline >= (clock.timestamp_ms() / 1000), E_DEADLINE_EXPIRED);

        if (usdc_fee_amount > 0) {
            let fee = (&mut usdc_coin).split(usdc_fee_amount, ctx);
            transfer::public_transfer(fee, config.fee_collector);
        };
        transfer::public_transfer(gas_drop_usdc, config.gas_drop_collector);
        transfer::public_transfer(gas_drop_native, config.gas_drop_collector);
        if (fee_is_native) {
            assert!((&native_fee_coin).value() >= fee, E_NATIVE_FEE_TOO_LOW);
            let fee_coin = (&mut native_fee_coin).split(fee, ctx);
            transfer::public_transfer(fee_coin, config.fee_collector);
        };
        // return native change
        transfer::public_transfer(native_fee_coin, ctx.sender());

        // Amount actually handed to CCTP, i.e. net of the USDC fee and of any USDC-denominated
        // gas drop. The receipt previously carried the pre-fee value, so the emitted event did
        // not match what the destination chain mints.
        let bridged_amount = usdc_coin.value();

        (
            create_deposit_for_burn_ticket<T, Auth>(
                auth,
                usdc_coin,
                destination_domain,
                recipient,
            ),
            DepositInfo {
                initial_amount: bridged_amount,
                solana_owner,
                user: ctx.sender(),
                gas_drop_amount,
                fee_is_native,
            },
        )
    }

    public fun post_deposit_for_burn(
        burn_message: BurnMessage,
        message: Message,
        deposit_info: DepositInfo,
        config: &mut Config,
    ) {
        // `DepositInfo` has no `drop`, so it is destructured here. This is the only way to
        // consume it, which is what forces every prepared burn through this accounting step.
        let DepositInfo {
            initial_amount,
            solana_owner,
            user,
            gas_drop_amount,
            fee_is_native,
        } = deposit_info;

        // should abort on duplicate nonce
        // required because BurnMessage and Message are copyable
        assert!(!config.processed_cctp_nonces.contains(message.nonce()), E_DUPLICATE_NONCE);
        config.processed_cctp_nonces.add(message.nonce(), true);
        config.nonce = config.nonce + 1;
        emit(CashmereTransfer {
            destination_domain: message.destination_domain(),
            nonce: config.nonce,
            recipient: burn_message.mint_recipient(),
            solana_owner,
            user,
            amount: initial_amount,
            gas_drop_amount,
            fee_is_native,
            cctp_nonce: message.nonce() as u256,
        });
    }

    #[test_only]
    use std::debug;

    #[test]
    fun test_signature() {
        let msg_struct = TransferParams {
            local_domain: LOCAL_DOMAIN,
            destination_domain: 1,
            fee: 2,
            deadline: 3,
            fee_is_native: false,
            sender: @0x1,
            usdc_amount: 1_000_000,
            recipient: @0x2,
            solana_owner: @0x3,
            gas_drop_amount: 0,
        };
        let msg = bcs::to_bytes(&msg_struct);
        debug::print(&msg);
    }
}
