module cashmere_cctp::transfer {
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::FungibleAsset;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::signer;
    use aptos_framework::timestamp;
    use aptos_std::ed25519;
    use std::bcs;
    use aptos_framework::coin;
    use aptos_framework::coin::Coin;
    use token_messenger_minter::token_messenger::deposit_for_burn;
    use token_messenger_minter_v2::token_messenger_minter as cctp_v2;
    use stablecoin_handler::handler as cctp_v2_handler;

    const SEED_NAME: vector<u8> = b"CASHMERE_CCTP_CONFIG";
    const BP: u64 = 10000;
    const MAX_FEE_BP: u64 = 100;
    const LOCAL_DOMAIN: u32 = 9;
    // version byte the gas API puts in front of the transfer params for V2 (`version=2`)
    const CCTP_VERSION_2: u8 = 2;
    // Circle assigns V2 nonces when it attests the burn, so the event carries 0 like the V2
    // message itself; off-chain code finds the message by transaction hash
    const CCTP_V2_NONCE: u256 = 0;

    const E_WRONG_SIGNATURE: u64 = 0x1000;
    const E_DEADLINE_EXPIRED: u64 = 0x1001;
    const E_GAS_DROP_LIMIT_EXCEEDED: u64 = 0x1002;
    const E_FEE_EXCEEDS_AMOUNT: u64 = 0x1003;
    const E_NATIVE_FEE_TOO_LOW: u64 = 0x1004;
    const E_PAUSED: u64 = 0x1005;
    const E_MAX_FEE_BP_EXCEEDED: u64 = 0x1006;

    const E_NOT_AN_ADMIN: u64 = 0x2000;

    struct AdminCap has key, store {}

    struct Config has key {
        fee_collector: address,
        gas_drop_collector: address,
        fee_bp: u64,
        nonce: u256,
        signer_key: ed25519::UnvalidatedPublicKey,
        max_usdc_gas_drop: u64,
        max_native_gas_drop: u64,
        paused: bool,
    }

    struct TransferParams has drop, copy {
        local_domain: u32,
        destination_domain: u32,
        fee: u64,
        deadline: u64,
        fee_is_native: bool,
    }

    // TransferParams behind the CCTP version, so a signature for one version fails on the other
    struct TransferParamsV2 has drop, copy {
        cctp_version: u8,
        local_domain: u32,
        destination_domain: u32,
        fee: u64,
        deadline: u64,
        fee_is_native: bool,
    }

    #[event]
    struct CashmereTransfer has drop, store {
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

    fun init_module(sender: &signer) {
        let config_constructor_ref = object::create_named_object(sender, SEED_NAME);
        let config_object_signer = object::generate_signer(&config_constructor_ref);
        let config_transfer_ref = object::generate_transfer_ref(&config_constructor_ref);
        object::disable_ungated_transfer(&config_transfer_ref);
        let config_linear_transfer_ref = object::generate_linear_transfer_ref(&config_transfer_ref);

        let config = Config {
            fee_collector: @fee_collector,
            gas_drop_collector: @gas_drop_collector,
            fee_bp: 1,
            nonce: 0,
            signer_key: ed25519::new_unvalidated_public_key_from_bytes(vector[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            max_usdc_gas_drop: 100_000_000,
            max_native_gas_drop: 0,
            paused: false,
        };
        move_to(&config_object_signer, config);

        object::transfer_with_ref(config_linear_transfer_ref, signer::address_of(sender));

        let admin_cap_constructor_ref = object::create_object(signer::address_of(sender));
        let admin_cap_object_signer = object::generate_signer(&admin_cap_constructor_ref);

        move_to(&admin_cap_object_signer, AdminCap {});
    }

    public fun set_paused(sender: &signer, auth: Object<AdminCap>, paused: bool) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.paused = paused;
    }

    public fun set_fee_bp(sender: &signer, auth: Object<AdminCap>, fee_bp: u64) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        assert!(fee_bp <= MAX_FEE_BP, E_MAX_FEE_BP_EXCEEDED);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.fee_bp = fee_bp;
    }

    public entry fun set_signer_key(sender: &signer, auth: Object<AdminCap>, signer_key: vector<u8>) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.signer_key = ed25519::new_unvalidated_public_key_from_bytes(signer_key);
    }

    public fun set_fee_collector(sender: &signer, auth: Object<AdminCap>, fee_collector: address) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.fee_collector = fee_collector;
    }

    public fun set_gas_drop_collector(sender: &signer, auth: Object<AdminCap>, gas_drop_collector: address) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.gas_drop_collector = gas_drop_collector;
    }

    public fun set_max_usdc_gas_drop(sender: &signer, auth: Object<AdminCap>, new_limit: u64) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.max_usdc_gas_drop = new_limit;
    }

    public fun set_max_native_gas_drop(sender: &signer, auth: Object<AdminCap>, new_limit: u64) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.max_native_gas_drop = new_limit;
    }

    fun get_object_address(): address {
        object::create_object_address(&@cashmere_cctp, SEED_NAME)
    }

    #[view]
    public fun get_fee(amount: u64, static_fee: u64): u64 acquires Config {
        let config: &Config = borrow_global(get_object_address());
        amount * config.fee_bp / BP + static_fee
    }

    public fun transfer(
        sender: &signer,
        usdc_asset: FungibleAsset,
        native_fee: Coin<0x1::aptos_coin::AptosCoin>,
        destination_domain: u32,
        recipient: address,
        solana_owner: address,
        fee: u64,
        deadline: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
        signature: vector<u8>
    ) acquires Config {
        let gas_drop_native = if (gas_drop_amount > 0 && fee_is_native) {
            coin::extract(&mut native_fee, gas_drop_amount)
        } else {
            coin::zero<0x1::aptos_coin::AptosCoin>()
        };
        let gas_drop_usdc = if (gas_drop_amount > 0 && !fee_is_native) {
            fungible_asset::extract(&mut usdc_asset, gas_drop_amount)
        } else {
            let metadata = aptos_framework::object::address_to_object<aptos_framework::fungible_asset::Metadata>(@usdc);
            fungible_asset::zero(metadata)
        };

        let usdc_amount = fungible_asset::amount(&usdc_asset);
        let usdc_fee_amount = get_fee(usdc_amount, if (fee_is_native) { 0 } else { fee });
        assert!(usdc_amount >= usdc_fee_amount, E_FEE_EXCEEDS_AMOUNT);

        let config: &mut Config = borrow_global_mut(get_object_address());
        assert!(!config.paused, E_PAUSED);
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
        };
        let msg = bcs::to_bytes(&msg_struct);
        assert!(ed25519::signature_verify_strict(&ed25519::new_signature_from_bytes(signature), &config.signer_key, msg), E_WRONG_SIGNATURE);
        assert!(deadline >= timestamp::now_seconds(), E_DEADLINE_EXPIRED);

        if (usdc_fee_amount > 0) {
            let fee_asset = fungible_asset::extract(&mut usdc_asset, usdc_fee_amount);
            primary_fungible_store::deposit(config.fee_collector, fee_asset);
        };
        primary_fungible_store::deposit(config.gas_drop_collector, gas_drop_usdc);
        coin::deposit(config.gas_drop_collector, gas_drop_native);
        if (fee_is_native) {
            assert!(coin::value(&native_fee) >= fee, E_NATIVE_FEE_TOO_LOW);
            let fee_coin = coin::extract(&mut native_fee, fee);
            coin::deposit(config.fee_collector, fee_coin);
        };
        // return native change; should handle zero coin
        coin::deposit(signer::address_of(sender), native_fee);

        let cctp_nonce = deposit_for_burn(sender, usdc_asset, destination_domain, recipient);
        config.nonce += 1;

        0x1::event::emit(CashmereTransfer {
            destination_domain,
            nonce: config.nonce,
            recipient,
            solana_owner,
            user: signer::address_of(sender),
            amount: usdc_amount,
            gas_drop_amount,
            fee_is_native,
            cctp_nonce: cctp_nonce as u256,
        });
    }

    public entry fun transfer_outer(
        sender: &signer,
        usdc_amount: u64,
        native_amount: u64,
        destination_domain: u32,
        recipient: address,
        solana_owner: address,
        fee: u64,
        deadline: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
        signature: vector<u8>
    ) acquires Config {
        let metadata = aptos_framework::object::address_to_object<aptos_framework::fungible_asset::Metadata>(@usdc);
        let usdc_amount = usdc_amount + if (fee_is_native) { 0 } else { gas_drop_amount };
        let usdc_asset = aptos_framework::primary_fungible_store::withdraw(sender, metadata, usdc_amount);

        let native_fee = if (fee_is_native && native_amount > 0) {
            coin::withdraw<0x1::aptos_coin::AptosCoin>(sender, native_amount)
        } else {
            coin::zero<0x1::aptos_coin::AptosCoin>()
        };

        transfer(
            sender,
            usdc_asset,
            native_fee,
            destination_domain,
            recipient,
            solana_owner,
            fee,
            deadline,
            gas_drop_amount,
            fee_is_native,
            signature,
        )
    }

    // Same as `transfer` except for the signed params, the burn (Circle's V2 deposit_for_burn,
    // completed by the USDC handler) and the cctp_nonce in the event
    public fun transfer_v2(
        sender: &signer,
        usdc_asset: FungibleAsset,
        native_fee: Coin<0x1::aptos_coin::AptosCoin>,
        destination_domain: u32,
        recipient: address,
        solana_owner: address,
        fee: u64,
        deadline: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
        max_fee: u64,
        min_finality_threshold: u32,
        signature: vector<u8>
    ) acquires Config {
        let gas_drop_native = if (gas_drop_amount > 0 && fee_is_native) {
            coin::extract(&mut native_fee, gas_drop_amount)
        } else {
            coin::zero<0x1::aptos_coin::AptosCoin>()
        };
        let gas_drop_usdc = if (gas_drop_amount > 0 && !fee_is_native) {
            fungible_asset::extract(&mut usdc_asset, gas_drop_amount)
        } else {
            let metadata = aptos_framework::object::address_to_object<aptos_framework::fungible_asset::Metadata>(@usdc);
            fungible_asset::zero(metadata)
        };

        let usdc_amount = fungible_asset::amount(&usdc_asset);
        let usdc_fee_amount = get_fee(usdc_amount, if (fee_is_native) { 0 } else { fee });
        assert!(usdc_amount >= usdc_fee_amount, E_FEE_EXCEEDS_AMOUNT);

        let config: &mut Config = borrow_global_mut(get_object_address());
        assert!(!config.paused, E_PAUSED);
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
        assert!(ed25519::signature_verify_strict(&ed25519::new_signature_from_bytes(signature), &config.signer_key, msg), E_WRONG_SIGNATURE);
        assert!(deadline >= timestamp::now_seconds(), E_DEADLINE_EXPIRED);

        if (usdc_fee_amount > 0) {
            let fee_asset = fungible_asset::extract(&mut usdc_asset, usdc_fee_amount);
            primary_fungible_store::deposit(config.fee_collector, fee_asset);
        };
        primary_fungible_store::deposit(config.gas_drop_collector, gas_drop_usdc);
        coin::deposit(config.gas_drop_collector, gas_drop_native);
        if (fee_is_native) {
            assert!(coin::value(&native_fee) >= fee, E_NATIVE_FEE_TOO_LOW);
            let fee_coin = coin::extract(&mut native_fee, fee);
            coin::deposit(config.fee_collector, fee_coin);
        };
        // return native change; should handle zero coin
        coin::deposit(signer::address_of(sender), native_fee);

        // destination caller 0x0: anyone can mint on the destination, as with V1
        let (burn_receipt, burn_asset) = cctp_v2::deposit_for_burn(
            sender,
            usdc_asset,
            destination_domain,
            recipient,
            @0x0,
            max_fee,
            min_finality_threshold,
            vector[],
        );
        cctp_v2_handler::burn(burn_receipt, burn_asset);
        config.nonce += 1;

        0x1::event::emit(CashmereTransfer {
            destination_domain,
            nonce: config.nonce,
            recipient,
            solana_owner,
            user: signer::address_of(sender),
            amount: usdc_amount,
            gas_drop_amount,
            fee_is_native,
            cctp_nonce: CCTP_V2_NONCE,
        });
    }

    // Arguments of `transfer_outer` with the V2 burn params before the signature; the relayer
    // reads the fee at argument index 5, so that position must not move
    public entry fun transfer_v2_outer(
        sender: &signer,
        usdc_amount: u64,
        native_amount: u64,
        destination_domain: u32,
        recipient: address,
        solana_owner: address,
        fee: u64,
        deadline: u64,
        gas_drop_amount: u64,
        fee_is_native: bool,
        max_fee: u64,
        min_finality_threshold: u32,
        signature: vector<u8>
    ) acquires Config {
        let metadata = aptos_framework::object::address_to_object<aptos_framework::fungible_asset::Metadata>(@usdc);
        let usdc_amount = usdc_amount + if (fee_is_native) { 0 } else { gas_drop_amount };
        let usdc_asset = aptos_framework::primary_fungible_store::withdraw(sender, metadata, usdc_amount);

        let native_fee = if (fee_is_native && native_amount > 0) {
            coin::withdraw<0x1::aptos_coin::AptosCoin>(sender, native_amount)
        } else {
            coin::zero<0x1::aptos_coin::AptosCoin>()
        };

        transfer_v2(
            sender,
            usdc_asset,
            native_fee,
            destination_domain,
            recipient,
            solana_owner,
            fee,
            deadline,
            gas_drop_amount,
            fee_is_native,
            max_fee,
            min_finality_threshold,
            signature,
        )
    }

    #[test_only]
    use aptos_std::debug;
    #[test_only]
    use aptos_std::type_info;

    #[test]
    fun bcs_encoding() {
        // let transfer_params = ed25519::new_signed_message(create_transfer_params(7, 100, 1747396422));
        let type_info = type_info::type_of<TransferParams>();
        let encoded = bcs::to_bytes(&type_info);
        debug::print(&encoded);
    }

    #[test]
    fun transfer_params_v2_is_version_byte_then_v1_params() {
        let v1 = TransferParams { local_domain: LOCAL_DOMAIN, destination_domain: 6, fee: 190000, deadline: 1793005550, fee_is_native: false };
        let v2 = TransferParamsV2 { cctp_version: CCTP_VERSION_2, local_domain: LOCAL_DOMAIN, destination_domain: 6, fee: 190000, deadline: 1793005550, fee_is_native: false };
        let expected = vector[CCTP_VERSION_2];
        std::vector::append(&mut expected, bcs::to_bytes(&v1));
        assert!(bcs::to_bytes(&v2) == expected, 0);
    }

    // message and signature returned by gas.cashmere.exchange/getEd25519Sig_native?localDomain=9
    // &destinationDomain=6&isNative=false&version=2 on 2026-10-26; the key is the signer_key in
    // the mainnet Config
    #[test]
    fun gas_api_v2_signature_verifies_only_on_v2_params() {
        let v2_msg = bcs::to_bytes(&TransferParamsV2 { cctp_version: CCTP_VERSION_2, local_domain: LOCAL_DOMAIN, destination_domain: 6, fee: 190000, deadline: 1793005550, fee_is_native: false });
        assert!(v2_msg == x"02090000000600000030e6020000000000ee17df6a0000000000", 0);

        let signer_key = ed25519::new_unvalidated_public_key_from_bytes(x"a72bce6ad6443b4f3fc41adb9b68a2e0696a67662f6cc7f70e86f31d93f50280");
        let signature = ed25519::new_signature_from_bytes(x"84c1e26e4e7900436a60911b846aa3e149e0f318075765e6586b84fbf77f64158130f00d83d06c0de6c3e35ce12fb1b280644153a1fa689b286051b638bb7505");
        assert!(ed25519::signature_verify_strict(&signature, &signer_key, v2_msg), 1);

        let v1_msg = bcs::to_bytes(&TransferParams { local_domain: LOCAL_DOMAIN, destination_domain: 6, fee: 190000, deadline: 1793005550, fee_is_native: false });
        assert!(!ed25519::signature_verify_strict(&signature, &signer_key, v1_msg), 2);
    }
}
