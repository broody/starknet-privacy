use core::panic_with_felt252;
use privacy::actions::{
    ClientAction, CreateEncNoteInput, CreateEscrowNoteInput, CreateOpenEscrowNoteInput,
    InvokeExternalInput, ServerAction, UseEscrowNoteInput, UseNoteInput, UseOpenEscrowNoteInput,
};
use privacy::hashes::{
    compute_escrow_note_nullifier, compute_open_escrow_note_id, compute_open_escrow_note_nullifier,
};
use privacy::objects::{
    EscrowInvokeResult, EscrowNote, OpenEscrowNote, OpenEscrowNoteDeposit, OpenNoteDeposit,
};
use privacy::tests::mock_note_controller::MockNoteController::{CALLBACK_MARKER, CONTROLLER_DENIED};
use privacy::tests::mock_note_controller::{
    IMockNoteControllerDispatcher, IMockNoteControllerDispatcherTrait,
};
use privacy::tests::utils_for_tests::{
    PrivacyCfgTrait, Test, TestTrait, User, UserTrait, deploy_mock_note_controller,
};
use privacy::utils::compute_escrow_note_actions_hash;
use privacy::utils::constants::ESCROW_INVOKE_SELECTOR;
use privacy::{errors, events};
use snforge_std::{
    DeclareResultTrait, EventSpyTrait, EventsFilterTrait, TokenTrait, declare, get_class_hash,
    mock_call, spy_events,
};
use starknet::{ContractAddress, SyscallResultTrait, get_execution_info};
use starkware_utils_testing::test_utils::{
    TokenHelperTrait, assert_expected_event_emitted, assert_panic_with_felt_error,
};

const AMOUNT: u128 = 37;
const POLICY_COMMITMENT: felt252 = 'AUCTION_SETTLEMENT';
const SECRET: felt252 = 'PRIVATE_NOTE_SECRET';
const OPEN_ESCROW_SECRET: felt252 = 'OPEN_ESCROW_SECRET';

fn source_note(
    ref test: Test, ref user: User,
) -> (ContractAddress, UseNoteInput, CreateEncNoteInput) {
    user.set_viewing_key_e2e();
    let token = test.mock_new_token();
    user.open_channel_with_token_e2e(recipient: user, token_addr: token, outgoing_channel_index: 0);
    let source = user
        .new_enc_note_with_generated_salt(
            recipient: user, token_addr: token, amount: AMOUNT, index: 0,
        );
    user.cheat_create_enc_note_e2e(create_note_input: source);
    let use_source = UseNoteInput {
        channel_key: user.compute_channel_key(recipient: user), token, index: 0,
    };
    let output = user
        .new_enc_note_with_generated_salt(
            recipient: user, token_addr: token, amount: AMOUNT, index: 1,
        );
    (token, use_source, output)
}

fn escrow_note_event(actions: Span<ServerAction>) -> events::EscrowNoteCreated {
    for action in actions {
        if let ServerAction::EmitEscrowNoteCreated(event) = *action {
            return event;
        }
    }
    panic_with_felt252('NO_ESCROW_NOTE_EVENT')
}

fn open_escrow_note_event(actions: Span<ServerAction>) -> events::OpenEscrowNoteCreated {
    for action in actions {
        if let ServerAction::EmitOpenEscrowNoteCreated(event) = *action {
            return event;
        }
    }
    panic_with_felt252('NO_OPEN_ESCROW_EVENT')
}

fn create_open_escrow_note_actions(
    user: @User, token: ContractAddress, controller: ContractAddress, secret: felt252,
) -> Span<ServerAction> {
    user
        .execute(
            [
                ClientAction::CreateOpenEscrowNote(
                    CreateOpenEscrowNoteInput {
                        contract_address: controller,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        secret,
                    },
                ),
                ClientAction::InvokeExternal(
                    InvokeExternalInput {
                        contract_address: controller, calldata: [CALLBACK_MARKER].span(),
                    },
                ),
            ]
                .span(),
        )
}

fn create_escrow_note(
    test: @Test,
    user: @User,
    token: ContractAddress,
    use_source: UseNoteInput,
    controller: ContractAddress,
) -> events::EscrowNoteCreated {
    let invoke = InvokeExternalInput {
        contract_address: controller, calldata: [CALLBACK_MARKER].span(),
    };
    let actions = user
        .execute(
            [
                ClientAction::UseNote(use_source),
                ClientAction::CreateEscrowNote(
                    CreateEscrowNoteInput {
                        contract_address: controller,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        amount: AMOUNT,
                        secret: SECRET,
                    },
                ),
                ClientAction::InvokeExternal(invoke),
            ]
                .span(),
        );
    let expected_actions_hash = compute_escrow_note_actions_hash(
        :actions,
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: *test.privacy.address,
    );
    let dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    dispatcher.set_expected_actions_hash(:expected_actions_hash);
    test.privacy.apply_actions(:actions);
    escrow_note_event(:actions)
}

fn spend_actions(
    user: @User, note_id: felt252, output: CreateEncNoteInput, controller: ContractAddress,
) -> Span<ServerAction> {
    user
        .execute(
            [
                ClientAction::UseEscrowNote(
                    UseEscrowNoteInput { note_id, amount: AMOUNT, secret: SECRET },
                ),
                ClientAction::CreateEncNote(output),
                ClientAction::InvokeExternal(
                    InvokeExternalInput {
                        contract_address: controller, calldata: [CALLBACK_MARKER].span(),
                    },
                ),
            ]
                .span(),
        )
}

#[test]
fn test_escrow_note_actions_hash_is_chain_and_pool_bound() {
    let actions: Array<ServerAction> = array![];
    let chain_id = 'CHAIN_ID';
    let pool_address: ContractAddress = 'POOL_ADDRESS'.try_into().unwrap();
    let actions_hash = compute_escrow_note_actions_hash(
        actions: actions.span(), :chain_id, :pool_address,
    );

    assert_ne!(
        actions_hash,
        compute_escrow_note_actions_hash(
            actions: actions.span(), chain_id: 'OTHER_CHAIN', :pool_address,
        ),
    );
    assert_ne!(
        actions_hash,
        compute_escrow_note_actions_hash(
            actions: actions.span(),
            :chain_id,
            pool_address: 'OTHER_POOL_ADDRESS'.try_into().unwrap(),
        ),
    );
}

#[test]
fn test_escrow_note_lifecycle_binds_exact_actions_and_authorizes_atomically() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let controller_dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    let created = create_escrow_note(@test, @user, :token, :use_source, :controller);

    assert_eq!(controller_dispatcher.callback_count(), 1);
    assert_eq!(controller_dispatcher.last_created_note_id(), created.note_id);
    assert_eq!(controller_dispatcher.last_spent_nullifier(), 0);
    assert_eq!(
        test.privacy.get_escrow_note(note_id: created.note_id),
        EscrowNote {
            note_commitment: created.note_commitment,
            contract_address: controller,
            policy_commitment: POLICY_COMMITMENT,
            token,
        },
    );

    let actions = spend_actions(@user, note_id: created.note_id, :output, :controller);
    let expected_actions_hash = compute_escrow_note_actions_hash(
        :actions,
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
    );
    controller_dispatcher.set_expected_actions_hash(:expected_actions_hash);
    let mut spy = spy_events();
    test.privacy.apply_actions(:actions);

    let nullifier = compute_escrow_note_nullifier(note_id: created.note_id, secret: SECRET);
    assert!(test.privacy.nullifier_exists(:nullifier));
    assert_eq!(controller_dispatcher.callback_count(), 2);
    assert_eq!(controller_dispatcher.last_actions_hash(), expected_actions_hash);
    assert_eq!(controller_dispatcher.last_created_note_id(), 0);
    assert_eq!(controller_dispatcher.last_spent_nullifier(), nullifier);
    let emitted_events = spy.get_events().emitted_by(contract_address: test.privacy.address).events;
    let expected_event = events::EscrowNoteUsed {
        nullifier, contract_address: controller, policy_commitment: POLICY_COMMITMENT, token,
    };
    assert_expected_event_emitted(
        spied_event: emitted_events[0],
        :expected_event,
        expected_event_selector: @selector!("EscrowNoteUsed"),
        expected_event_name: "EscrowNoteUsed",
    );

    let replay = test.privacy.safe_apply_actions(:actions);
    assert_panic_with_felt_error(result: replay, expected_error: errors::NON_ZERO_VALUE);
}

#[test]
fn test_escrow_note_survives_contract_upgrade() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let contract_address = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let created = create_escrow_note(
        @test, @user, :token, :use_source, controller: contract_address,
    );

    let replacement_class = declare(contract: "MockComputeEmpty")
        .unwrap_syscall()
        .contract_class()
        .class_hash;
    let controller_dispatcher = IMockNoteControllerDispatcher { contract_address };
    controller_dispatcher.upgrade(new_class_hash: *replacement_class);
    assert_eq!(get_class_hash(contract_address), *replacement_class);

    let actions = spend_actions(
        @user, note_id: created.note_id, :output, controller: contract_address,
    );
    // Isolate the pool's address binding from the replacement's application behavior.
    let no_open_note_deposits: Array<OpenNoteDeposit> = array![];
    let no_open_escrow_note_deposits: Array<OpenEscrowNoteDeposit> = array![];
    let no_associated_addresses: Array<ContractAddress> = array![];
    let callback_result = EscrowInvokeResult {
        open_note_deposits: no_open_note_deposits.span(),
        open_escrow_note_deposits: no_open_escrow_note_deposits.span(),
        associated_addresses: no_associated_addresses.span(),
    };
    mock_call(contract_address, ESCROW_INVOKE_SELECTOR, callback_result, 1);
    test.privacy.apply_actions(:actions);

    let nullifier = compute_escrow_note_nullifier(note_id: created.note_id, secret: SECRET);
    assert!(test.privacy.nullifier_exists(:nullifier));
}

#[test]
fn test_escrow_note_spend_requires_callback_and_rolls_back() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let created = create_escrow_note(@test, @user, :token, :use_source, :controller);

    let actions = user
        .execute(
            [
                ClientAction::UseEscrowNote(
                    UseEscrowNoteInput { note_id: created.note_id, amount: AMOUNT, secret: SECRET },
                ),
                ClientAction::CreateEncNote(output),
            ]
                .span(),
        );
    let result = test.privacy.safe_apply_actions(:actions);
    assert_panic_with_felt_error(:result, expected_error: errors::ESCROW_NOTE_CALLBACK_REQUIRED);
    let nullifier = compute_escrow_note_nullifier(note_id: created.note_id, secret: SECRET);
    assert!(!test.privacy.nullifier_exists(:nullifier));
}

#[test]
fn test_escrow_note_spend_rejects_wrong_target_and_denial() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let other_controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 1,
    );
    let created = create_escrow_note(@test, @user, :token, :use_source, :controller);

    let wrong_target_actions = spend_actions(
        @user, note_id: created.note_id, :output, controller: other_controller,
    );
    let wrong_target = test.privacy.safe_apply_actions(actions: wrong_target_actions);
    assert_panic_with_felt_error(
        result: wrong_target, expected_error: errors::ESCROW_NOTE_TARGET_MISMATCH,
    );

    let dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    dispatcher.set_allowed(false);
    let denied_actions = spend_actions(@user, note_id: created.note_id, :output, :controller);
    let denied = test.privacy.safe_apply_actions(actions: denied_actions);
    assert_panic_with_felt_error(result: denied, expected_error: CONTROLLER_DENIED);
    let nullifier = compute_escrow_note_nullifier(note_id: created.note_id, secret: SECRET);
    assert!(!test.privacy.nullifier_exists(:nullifier));
}

#[test]
fn test_escrow_note_spend_rejects_invalid_private_opening() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, _) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let created = create_escrow_note(@test, @user, :token, :use_source, :controller);

    user
        .assert_actions_panic(
            [
                ClientAction::UseEscrowNote(
                    UseEscrowNoteInput {
                        note_id: created.note_id, amount: AMOUNT + 1, secret: SECRET,
                    },
                ),
            ]
                .span(),
            expected_error: errors::INVALID_ESCROW_NOTE_OPENING,
        );
    user
        .assert_actions_panic(
            [
                ClientAction::UseEscrowNote(
                    UseEscrowNoteInput {
                        note_id: created.note_id,
                        amount: AMOUNT,
                        secret: 'WRONG_PRIVATE_NOTE_SECRET',
                    },
                ),
            ]
                .span(),
            expected_error: errors::INVALID_ESCROW_NOTE_OPENING,
        );
}

#[test]
fn test_open_escrow_note_is_callback_funded_and_spent_atomically() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let token = test.new_token();
    let token_address = token.contract_address();
    user.set_viewing_key_e2e();
    user
        .open_channel_with_token_e2e(
            recipient: user, token_addr: token_address, outgoing_channel_index: 0,
        );
    let output = user
        .new_enc_note_with_generated_salt(
            recipient: user, token_addr: token_address, amount: AMOUNT, index: 0,
        );
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let controller_dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    let create_actions = create_open_escrow_note_actions(
        @user, token: token_address, :controller, secret: OPEN_ESCROW_SECRET,
    );
    let created = open_escrow_note_event(actions: create_actions);
    assert_eq!(
        created.note_id,
        compute_open_escrow_note_id(
            sender_addr: user.address,
            contract_address: controller,
            policy_commitment: POLICY_COMMITMENT,
            token: token_address,
            secret: OPEN_ESCROW_SECRET,
        ),
    );
    controller_dispatcher.set_open_escrow_deposit(note_id: created.note_id, amount: AMOUNT);
    token.supply(address: controller, amount: AMOUNT);
    token.approve(owner: controller, spender: test.privacy.address, amount: AMOUNT.into());

    test.privacy.apply_actions(actions: create_actions);

    assert_eq!(
        test.privacy.get_open_escrow_note(note_id: created.note_id),
        OpenEscrowNote {
            opening_commitment: created.opening_commitment,
            amount: AMOUNT,
            contract_address: controller,
            policy_commitment: POLICY_COMMITMENT,
            token: token_address,
        },
    );
    assert_eq!(controller_dispatcher.last_created_note_id(), created.note_id);

    let spend_actions = user
        .execute(
            [
                ClientAction::UseOpenEscrowNote(
                    UseOpenEscrowNoteInput {
                        note_id: created.note_id, amount: AMOUNT, secret: OPEN_ESCROW_SECRET,
                    },
                ),
                ClientAction::CreateEncNote(output),
                ClientAction::InvokeExternal(
                    InvokeExternalInput {
                        contract_address: controller, calldata: [CALLBACK_MARKER].span(),
                    },
                ),
            ]
                .span(),
        );
    test.privacy.apply_actions(actions: spend_actions);

    let nullifier = compute_open_escrow_note_nullifier(
        note_id: created.note_id, secret: OPEN_ESCROW_SECRET,
    );
    assert!(test.privacy.nullifier_exists(:nullifier));
    assert_eq!(controller_dispatcher.last_spent_nullifier(), nullifier);
}

#[test]
fn test_open_escrow_note_creation_requires_same_transaction_funding() {
    let mut test: Test = Default::default();
    let user = test.new_user();
    let token = test.mock_new_token();
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let controller_dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    let actions = create_open_escrow_note_actions(
        @user, :token, :controller, secret: OPEN_ESCROW_SECRET,
    );
    let created = open_escrow_note_event(:actions);

    let result = test.privacy.safe_apply_actions(:actions);

    assert_panic_with_felt_error(:result, expected_error: errors::UNDEPOSITED_OPEN_ESCROW_NOTES);
    assert_eq!(test.privacy.get_open_escrow_note(note_id: created.note_id).opening_commitment, 0);
    assert_eq!(controller_dispatcher.callback_count(), 0);
}

#[test]
fn test_open_escrow_note_rejects_wrong_secret_or_public_amount() {
    let mut test: Test = Default::default();
    let user = test.new_user();
    let token = test.new_token();
    let token_address = token.contract_address();
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let controller_dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    let actions = create_open_escrow_note_actions(
        @user, token: token_address, :controller, secret: OPEN_ESCROW_SECRET,
    );
    let created = open_escrow_note_event(:actions);
    controller_dispatcher.set_open_escrow_deposit(note_id: created.note_id, amount: AMOUNT);
    token.supply(address: controller, amount: AMOUNT);
    token.approve(owner: controller, spender: test.privacy.address, amount: AMOUNT.into());
    test.privacy.apply_actions(:actions);

    user
        .assert_actions_panic(
            [
                ClientAction::UseOpenEscrowNote(
                    UseOpenEscrowNoteInput {
                        note_id: created.note_id, amount: AMOUNT + 1, secret: OPEN_ESCROW_SECRET,
                    },
                ),
            ]
                .span(),
            expected_error: errors::INVALID_OPEN_ESCROW_NOTE_OPENING,
        );
    user
        .assert_actions_panic(
            [
                ClientAction::UseOpenEscrowNote(
                    UseOpenEscrowNoteInput {
                        note_id: created.note_id, amount: AMOUNT, secret: 'WRONG_OPEN_SECRET',
                    },
                ),
            ]
                .span(),
            expected_error: errors::INVALID_OPEN_ESCROW_NOTE_OPENING,
        );
}

#[test]
fn test_open_escrow_note_cannot_be_funded_twice_or_by_another_contract() {
    let mut test: Test = Default::default();
    let user = test.new_user();
    let token = test.new_token();
    let token_address = token.contract_address();
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let other_controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 1,
    );
    let controller_dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    let first_actions = create_open_escrow_note_actions(
        @user, token: token_address, :controller, secret: OPEN_ESCROW_SECRET,
    );
    let first = open_escrow_note_event(actions: first_actions);
    controller_dispatcher.set_open_escrow_deposit(note_id: first.note_id, amount: AMOUNT);
    token.supply(address: controller, amount: AMOUNT);
    token.approve(owner: controller, spender: test.privacy.address, amount: AMOUNT.into());
    test.privacy.apply_actions(actions: first_actions);

    let second_actions = create_open_escrow_note_actions(
        @user, token: token_address, :controller, secret: 'SECOND_OPEN_SECRET',
    );
    let second = open_escrow_note_event(actions: second_actions);
    controller_dispatcher.set_open_escrow_deposit(note_id: first.note_id, amount: AMOUNT);
    let repeated = test.privacy.safe_apply_actions(actions: second_actions);
    assert_panic_with_felt_error(
        result: repeated, expected_error: errors::OPEN_ESCROW_NOTE_ALREADY_FUNDED,
    );
    assert_eq!(test.privacy.get_open_escrow_note(note_id: second.note_id).opening_commitment, 0);

    let other_dispatcher = IMockNoteControllerDispatcher { contract_address: other_controller };
    let third_actions = create_open_escrow_note_actions(
        @user, token: token_address, controller: other_controller, secret: 'THIRD_OPEN_SECRET',
    );
    other_dispatcher.set_open_escrow_deposit(note_id: first.note_id, amount: AMOUNT);
    let wrong_funder = test.privacy.safe_apply_actions(actions: third_actions);
    assert_panic_with_felt_error(
        result: wrong_funder, expected_error: errors::OPEN_ESCROW_NOTE_TARGET_MISMATCH,
    );
}

#[test]
fn test_escrow_callback_uses_dedicated_selector() {
    assert_ne!(ESCROW_INVOKE_SELECTOR, selector!("privacy_invoke"));
}
