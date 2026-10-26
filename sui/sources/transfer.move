module cashmere_cctp::transfer {
    use token_messenger_minter::deposit_for_burn::{
        create_deposit_for_burn_ticket,
        DepositForBurnTicket,
    };
    use token_messenger_minter::burn_message::BurnMessage;
    use message_transmitter::message::Message;
    use token_messenger_minter_v2::deposit_for_burn::{
        create_deposit_for_burn_with_package_auth_ticket,
        DepositForBurnWithPackageAuthTicket,
    };
    use usdc::usdc::USDC;
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
    const LOCAL_DOMAIN: u32 = 8;
    // version byte the gas API puts in front of the transfer params for V2 (`version=2`)
    const CCTP_VERSION_2: u8 = 2;
    // Circle assigns V2 nonces when it attests the burn, so the event carries 0 like the V2
    // message itself; off-chain code finds the message by transaction digest
    const CCTP_V2_NONCE: u256 = 0;

    const E_WRONG_SIGNATURE: u64 = 0x1000;
    const E_DEADLINE_EXPIRED: u64 = 0x1001;
    const E_GAS_DROP_LIMIT_EXCEEDED: u64 = 0x1002;
    const E_FEE_EXCEEDS_AMOUNT: u64 = 0x1003;
    const E_NATIVE_FEE_TOO_LOW: u64 = 0x1004;
    const E_DUPLICATE_NONCE: u64 = 0x1005;
    const E_PAUSED: u64 = 0x1006;

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

    // Parameters that ARE INCLUDED in backend signature (gas_on_destination is **not** signed)
    public struct TransferParams has drop, copy {
        local_domain: u32,
        destination_domain: u32,
        fee: u64,
        deadline: u64,
        fee_is_native: bool,
    }

    // TransferParams behind the CCTP version, so a signature for one version fails on the other
    public struct TransferParamsV2 has drop, copy {
        cctp_version: u8,
        local_domain: u32,
        destination_domain: u32,
        fee: u64,
        deadline: u64,
        fee_is_native: bool,
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

    public struct DepositInfo has drop {
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
        assert!(fee_bp <= MAX_FEE_BP, 0x2000);
        config.fee_bp = fee_bp;
    }

    public fun set_signer_key(_: &AdminCap, config: &mut Config, signer_key: vector<u8>) {
        config.signer_key = signer_key;
    }

    public fun set_fee_collector(_: &AdminCap, config: &mut Config, fee_collector: address) {
        config.fee_collector = fee_collector;
    }

    public fun set_gas_drop_collector(_: &AdminCap, config: &mut Config, gas_drop_collector: address) {
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
        let usdc_fee_amount = get_fee(config, usdc_value, if (fee_is_native) { 0 } else { fee });
        assert!(usdc_fee_amount <= usdc_value, E_FEE_EXCEEDS_AMOUNT);

        if (fee_is_native) {
            assert!(gas_drop_amount <= config.max_native_gas_drop, E_GAS_DROP_LIMIT_EXCEEDED);
        } else {
            assert!(gas_drop_amount <= config.max_usdc_gas_drop, E_GAS_DROP_LIMIT_EXCEEDED);
        };

        let msg_struct = TransferParams {
            local_domain: 8,
            destination_domain,
            fee,
            deadline,
            fee_is_native,
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

        (
            create_deposit_for_burn_ticket<T, Auth>(
                auth,
                usdc_coin,
                destination_domain,
                recipient,
            ),
            DepositInfo {
                initial_amount: usdc_value,
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
        // should abort on duplicate nonce
        // required because BurnMessage and Message are copyable
        assert!(!config.processed_cctp_nonces.contains(message.nonce()), E_DUPLICATE_NONCE);
        config.processed_cctp_nonces.add(message.nonce(), true);
        config.nonce = config.nonce + 1;
        emit(CashmereTransfer {
            destination_domain: message.destination_domain(),
            nonce: config.nonce,
            recipient: burn_message.mint_recipient(),
            solana_owner: deposit_info.solana_owner,
            user: deposit_info.user,
            amount: deposit_info.initial_amount,
            gas_drop_amount: deposit_info.gas_drop_amount,
            fee_is_native: deposit_info.fee_is_native,
            cctp_nonce: message.nonce() as u256,
        });
    }

    // Same checks, fees and event as V1 for a CCTP V2 burn of USDC, signed over TransferParamsV2.
    // Returns Circle's package-auth burn ticket; the PTB then calls, on the latest TMM V2 and
    // handler packages, deposit_for_burn_with_package_auth<USDC, Auth> -> handler::burn ->
    // complete_burn<USDC, handler::Auth>. None of the values in that chain can be dropped, so
    // the burn happens in the same transaction and the event needs no post_deposit_for_burn step.
    public fun prepare_deposit_for_burn_v2(
        mut usdc_coin: Coin<USDC>,
        mut native_fee_coin: Coin<SUI>,
        destination_domain: u32,
        recipient: address,
        solana_owner: address,
        fee: u64,
        deadline: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
        max_fee: u256,
        min_finality_threshold: u32,
        signature: vector<u8>,
        config: &mut Config,
        clock: &Clock,
        ctx: &mut TxContext,
    ): DepositForBurnWithPackageAuthTicket<USDC, Auth> {
        assert!(!config.paused, E_PAUSED);

        let gas_drop_native = if (gas_drop_amount > 0 && fee_is_native) {
            (&mut native_fee_coin).split(gas_drop_amount, ctx)
        } else {
            coin::zero<SUI>(ctx)
        };
        let gas_drop_usdc = if (gas_drop_amount > 0 && !fee_is_native) {
            (&mut usdc_coin).split(gas_drop_amount, ctx)
        } else {
            coin::zero<USDC>(ctx)
        };

        let usdc_value = usdc_coin.value();
        let usdc_fee_amount = get_fee(config, usdc_value, if (fee_is_native) { 0 } else { fee });
        assert!(usdc_fee_amount <= usdc_value, E_FEE_EXCEEDS_AMOUNT);

        if (fee_is_native) {
            assert!(gas_drop_amount <= config.max_native_gas_drop, E_GAS_DROP_LIMIT_EXCEEDED);
        } else {
            assert!(gas_drop_amount <= config.max_usdc_gas_drop, E_GAS_DROP_LIMIT_EXCEEDED);
        };

        let msg_struct = TransferParamsV2 {
            cctp_version: CCTP_VERSION_2,
            local_domain: LOCAL_DOMAIN,
            destination_domain,
            fee,
            deadline,
            fee_is_native,
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

        config.nonce = config.nonce + 1;
        emit(CashmereTransfer {
            destination_domain,
            nonce: config.nonce,
            recipient,
            solana_owner,
            user: ctx.sender(),
            amount: usdc_value,
            gas_drop_amount,
            fee_is_native,
            cctp_nonce: CCTP_V2_NONCE,
        });

        // destination caller 0x0: anyone can mint on the destination, as with V1
        create_deposit_for_burn_with_package_auth_ticket<USDC, Auth>(
            usdc_coin,
            destination_domain,
            recipient,
            @0x0,
            max_fee,
            min_finality_threshold,
            vector[],
            Auth {},
        )
    }

    #[test_only]
    use std::debug;

    #[test]
    fun test_signature() {
        let msg_struct = TransferParams {
            local_domain: 8,
            destination_domain: 1,
            fee: 2,
            deadline: 3,
            fee_is_native: false,
        };
        let msg = bcs::to_bytes(&msg_struct);
        debug::print(&msg);
    }

    #[test]
    fun transfer_params_v2_is_version_byte_then_v1_params() {
        let v1 = TransferParams { local_domain: LOCAL_DOMAIN, destination_domain: 6, fee: 190000, deadline: 1793007291, fee_is_native: false };
        let v2 = TransferParamsV2 { cctp_version: CCTP_VERSION_2, local_domain: LOCAL_DOMAIN, destination_domain: 6, fee: 190000, deadline: 1793007291, fee_is_native: false };
        let mut expected = vector[CCTP_VERSION_2];
        expected.append(bcs::to_bytes(&v1));
        assert!(bcs::to_bytes(&v2) == expected, 0);
    }

    // message and signature returned by gas.cashmere.exchange/getEd25519Sig_native?localDomain=8
    // &destinationDomain=6&isNative=false&version=2 on 2026-10-26; the key is the signer_key in
    // the mainnet Config
    #[test]
    fun gas_api_v2_signature_verifies_only_on_v2_params() {
        let v2_msg = bcs::to_bytes(&TransferParamsV2 { cctp_version: CCTP_VERSION_2, local_domain: LOCAL_DOMAIN, destination_domain: 6, fee: 190000, deadline: 1793007291, fee_is_native: false });
        assert!(v2_msg == x"02080000000600000030e6020000000000bb1edf6a0000000000", 0);

        let signer_key = x"a72bce6ad6443b4f3fc41adb9b68a2e0696a67662f6cc7f70e86f31d93f50280";
        let signature = x"9cfb0f3b96c2508d70c4dbbeef40d4f4a018429fc904d429743e307b8b46d899d381c4a1849765b1217c252829352a89a1d9968486eb0187fac6e0c49bf3410b";
        assert!(ed25519::ed25519_verify(&signature, &signer_key, &v2_msg), 1);

        let v1_msg = bcs::to_bytes(&TransferParams { local_domain: LOCAL_DOMAIN, destination_domain: 6, fee: 190000, deadline: 1793007291, fee_is_native: false });
        assert!(!ed25519::ed25519_verify(&signature, &signer_key, &v1_msg), 2);
    }

    #[test_only]
    use sui::test_scenario;
    #[test_only]
    use token_messenger_minter_v2::{
        deposit_for_burn::{deposit_for_burn_with_package_auth, get_burn_details, destroy_burn_receipt_for_testing},
        state as tmm_v2_state,
        token_utils::calculate_token_id,
    };

    // The V2 ticket through Circle's TMM V2 phase 1 with the gas API signature above. The handler
    // burn and complete_burn that follow in the PTB are Circle's code and take no Cashmere input.
    #[test]
    fun v2_ticket_is_accepted_by_token_messenger_minter_v2() {
        let user = @0xa11ce;
        let fee_collector = @0xfee;
        let gas_drop_collector = @0x6a5;
        let recipient = @0x00000000000000000000000095a807bcab5a16901628acf90fc3057061a3fce9;
        let mut scenario = test_scenario::begin(user);
        init(scenario.ctx());
        scenario.next_tx(user);

        let mut config = scenario.take_shared<Config>();
        config.signer_key = x"a72bce6ad6443b4f3fc41adb9b68a2e0696a67662f6cc7f70e86f31d93f50280";
        config.fee_bp = 0;
        config.fee_collector = fee_collector;
        config.gas_drop_collector = gas_drop_collector;
        let mut clock = sui::clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(1793007000 * 1000);

        let ticket = prepare_deposit_for_burn_v2(
            coin::mint_for_testing<USDC>(10_000_000, scenario.ctx()),
            coin::zero<SUI>(scenario.ctx()),
            6,
            recipient,
            recipient,
            190000,
            1793007291,
            0,
            false,
            0,
            2000,
            x"9cfb0f3b96c2508d70c4dbbeef40d4f4a018429fc904d429743e307b8b46d899d381c4a1849765b1217c252829352a89a1d9968486eb0187fac6e0c49bf3410b",
            &mut config,
            &clock,
            scenario.ctx(),
        );

        assert!(config.nonce == 1, 0);
        let events = sui::event::events_by_type<CashmereTransfer>();
        assert!(events.length() == 1, 1);
        let event = &events[0];
        assert!(event.destination_domain == 6 && event.nonce == 1 && event.recipient == recipient && event.user == user, 2);
        assert!(event.amount == 10_000_000 && event.gas_drop_amount == 0 && !event.fee_is_native && event.cctp_nonce == 0, 3);

        let mut tmm_state = tmm_v2_state::new_for_testing(1, user, scenario.ctx());
        tmm_state.add_remote_token_messenger_for_testing(6, @0x28b5a0e9c621a5badaa536219b3a228c8168cf5d);
        tmm_state.add_burn_limit_for_testing(calculate_token_id<USDC>(), 1_000_000_000_000);
        let (receipt, coin) = deposit_for_burn_with_package_auth(ticket, &tmm_state, scenario.ctx());
        let (burn_token, amount, mint_recipient) = get_burn_details(&receipt);
        assert!(burn_token == calculate_token_id<USDC>() && amount == 10_000_000 - 190000 && mint_recipient == recipient, 4);
        assert!(coin.value() == amount, 5);

        destroy_burn_receipt_for_testing(receipt);
        coin.burn_for_testing();
        std::unit_test::destroy(tmm_state);
        clock.destroy_for_testing();
        test_scenario::return_shared(config);

        scenario.next_tx(user);
        let fee = scenario.take_from_address<Coin<USDC>>(fee_collector);
        assert!(fee.value() == 190000, 6);
        fee.burn_for_testing();
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_WRONG_SIGNATURE)]
    fun v2_rejects_a_v1_signature() {
        let user = @0xa11ce;
        let mut scenario = test_scenario::begin(user);
        init(scenario.ctx());
        scenario.next_tx(user);
        let mut config = scenario.take_shared<Config>();
        config.signer_key = x"a72bce6ad6443b4f3fc41adb9b68a2e0696a67662f6cc7f70e86f31d93f50280";
        let mut clock = sui::clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(1793007000 * 1000);
        // V1 signature from the gas API (no version) for localDomain=8, destinationDomain=6
        let ticket = prepare_deposit_for_burn_v2(
            coin::mint_for_testing<USDC>(10_000_000, scenario.ctx()),
            coin::zero<SUI>(scenario.ctx()),
            6,
            @0x1,
            @0x1,
            190000,
            1793007292,
            0,
            false,
            0,
            2000,
            x"18c705a6c3798129bc7576ce0a4a9d650ed884d617273b9671af56210a9324db1178b16459701e916b37697d6850bb08aa766922c2830bae3f47073eeeb5670d",
            &mut config,
            &clock,
            scenario.ctx(),
        );
        std::unit_test::destroy(ticket);
        clock.destroy_for_testing();
        test_scenario::return_shared(config);
        scenario.end();
    }
}
