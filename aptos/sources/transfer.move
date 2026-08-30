module cashmere_cctp::transfer {
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::FungibleAsset;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object;
    use aptos_framework::object::Object;
    // `signer` lives in the standard library, not in `aptos_framework`.
    use std::signer;
    use aptos_framework::timestamp;
    use aptos_std::ed25519;
    use std::bcs;
    use aptos_framework::coin;
    use aptos_framework::coin::Coin;
    use token_messenger_minter::token_messenger::deposit_for_burn;

    const SEED_NAME: vector<u8> = b"CASHMERE_CCTP_CONFIG";
    const BP: u64 = 10000;
    const MAX_FEE_BP: u64 = 100;
    /// CCTP domain identifier of Aptos.
    const LOCAL_DOMAIN: u32 = 9;
    /// Highest CCTP domain identifier accepted by this module.
    const MAX_DOMAIN: u32 = 32;
    /// Byte length of an ed25519 public key.
    const ED25519_PUBLIC_KEY_LENGTH: u64 = 32;

    const E_WRONG_SIGNATURE: u64 = 0x1000;
    const E_DEADLINE_EXPIRED: u64 = 0x1001;
    const E_GAS_DROP_LIMIT_EXCEEDED: u64 = 0x1002;
    const E_FEE_EXCEEDS_AMOUNT: u64 = 0x1003;
    const E_NATIVE_FEE_TOO_LOW: u64 = 0x1004;
    const E_PAUSED: u64 = 0x1005;
    const E_MAX_FEE_BP_EXCEEDED: u64 = 0x1006;
    const E_INVALID_DOMAIN: u64 = 0x1007;
    const E_ZERO_AMOUNT: u64 = 0x1008;
    const E_INVALID_SIGNER_KEY: u64 = 0x1009;
    const E_ZERO_ADDRESS: u64 = 0x100A;

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

    /// The payload the backend signs to authorize a single transfer.
    ///
    /// Every field that decides where the value goes, how much of it moves, and what the
    /// user is charged is bound in. The previous version covered only the two domains, the
    /// flat `fee`, the `deadline` and `fee_is_native`, so a signature broadcast once could
    /// be reused by anybody for a different `usdc_amount`, `recipient` and `gas_drop_amount`
    /// — a quote for a small transfer authorized an arbitrarily large one.
    ///
    /// NOTE: changing this struct changes the bytes the backend signer service must sign.
    /// The signer service has to be updated in lockstep with this module.
    struct TransferParams has drop, copy {
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

    // All admin setters are `public entry` so they can be invoked directly by a transaction.
    // As plain `public fun` they were unreachable from outside Move and the module had no
    // way to be reconfigured after publication.

    public entry fun set_paused(sender: &signer, auth: Object<AdminCap>, paused: bool) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.paused = paused;
    }

    public entry fun set_fee_bp(sender: &signer, auth: Object<AdminCap>, fee_bp: u64) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        assert!(fee_bp <= MAX_FEE_BP, E_MAX_FEE_BP_EXCEEDED);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.fee_bp = fee_bp;
    }

    public entry fun set_signer_key(sender: &signer, auth: Object<AdminCap>, signer_key: vector<u8>) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        // `new_unvalidated_public_key_from_bytes` accepts any byte vector, so a wrong-length
        // key would be stored and would silently reject every subsequent signature.
        assert!(std::vector::length(&signer_key) == ED25519_PUBLIC_KEY_LENGTH, E_INVALID_SIGNER_KEY);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.signer_key = ed25519::new_unvalidated_public_key_from_bytes(signer_key);
    }

    public entry fun set_fee_collector(sender: &signer, auth: Object<AdminCap>, fee_collector: address) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        assert!(fee_collector != @0x0, E_ZERO_ADDRESS);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.fee_collector = fee_collector;
    }

    public entry fun set_gas_drop_collector(sender: &signer, auth: Object<AdminCap>, gas_drop_collector: address) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        assert!(gas_drop_collector != @0x0, E_ZERO_ADDRESS);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.gas_drop_collector = gas_drop_collector;
    }

    public entry fun set_max_usdc_gas_drop(sender: &signer, auth: Object<AdminCap>, new_limit: u64) acquires Config {
        assert!(object::is_owner(auth, signer::address_of(sender)), E_NOT_AN_ADMIN);
        let config: &mut Config = borrow_global_mut(get_object_address());
        config.max_usdc_gas_drop = new_limit;
    }

    public entry fun set_max_native_gas_drop(sender: &signer, auth: Object<AdminCap>, new_limit: u64) acquires Config {
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
        assert!(usdc_amount > 0, E_ZERO_AMOUNT);
        // A domain this module cannot reach, or Aptos' own domain, would burn the USDC with
        // no remote messenger able to mint it back.
        assert!(destination_domain < MAX_DOMAIN, E_INVALID_DOMAIN);
        assert!(destination_domain != LOCAL_DOMAIN, E_INVALID_DOMAIN);

        let usdc_fee_amount = get_fee(usdc_amount, if (fee_is_native) { 0 } else { fee });
        // Strict comparison: an equal fee would leave nothing to bridge and CCTP rejects a
        // zero-amount burn with an opaque error.
        assert!(usdc_amount > usdc_fee_amount, E_FEE_EXCEEDS_AMOUNT);

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
            sender: signer::address_of(sender),
            usdc_amount,
            recipient,
            solana_owner,
            gas_drop_amount,
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

        // Amount actually handed to CCTP, i.e. net of the USDC fee and of any USDC-denominated
        // gas drop. The event previously reported the gross `usdc_amount`, which does not
        // match what the destination chain mints and made off-chain reconciliation wrong.
        let bridged_amount = fungible_asset::amount(&usdc_asset);
        let cctp_nonce = deposit_for_burn(sender, usdc_asset, destination_domain, recipient);
        config.nonce += 1;

        0x1::event::emit(CashmereTransfer {
            destination_domain,
            nonce: config.nonce,
            recipient,
            solana_owner,
            user: signer::address_of(sender),
            amount: bridged_amount,
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

    #[test_only]
    use aptos_std::debug;
    // `std::bcs` is already imported at module scope; re-importing it here under the same
    // alias is a duplicate-alias error.
    #[test_only]
    use aptos_std::type_info;

    #[test]
    fun bcs_encoding() {
        // let transfer_params = ed25519::new_signed_message(create_transfer_params(7, 100, 1747396422));
        let type_info = type_info::type_of<TransferParams>();
        let encoded = bcs::to_bytes(&type_info);
        debug::print(&encoded);
    }
}
