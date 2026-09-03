use core::panic_with_felt252;
use privacy::actions::{
    ClientAction, CreateContractNoteInput, CreateEncNoteInput, InvokeExternalInput, ServerAction,
    UseContractNoteInput, UseNoteInput,
};
use privacy::hashes::compute_contract_note_nullifier;
use privacy::objects::ContractNote;
use privacy::tests::mock_note_controller::MockNoteController::{CALLBACK_MARKER, CONTROLLER_DENIED};
use privacy::tests::mock_note_controller::{
    IMockNoteControllerDispatcher, IMockNoteControllerDispatcherTrait,
};
use privacy::tests::utils_for_tests::{
    PrivacyCfgTrait, Test, TestTrait, User, UserTrait, deploy_mock_note_controller,
};
use privacy::utils::compute_contract_note_actions_hash;
use privacy::utils::constants::CONTRACT_NOTE_INVOKE_SELECTOR;
use privacy::{errors, events};
use snforge_std::{EventSpyTrait, EventsFilterTrait, get_class_hash, spy_events};
use starknet::{ContractAddress, get_execution_info};
use starkware_utils_testing::test_utils::{
    assert_expected_event_emitted, assert_panic_with_felt_error,
};

const AMOUNT: u128 = 37;
const CONTROLLER_COMMITMENT: felt252 = 'AUCTION_SETTLEMENT';
const NONCE: felt252 = 'PRIVATE_NOTE_NONCE';
const BLINDING: felt252 = 'PRIVATE_BLINDING';

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

fn contract_note_event(actions: Span<ServerAction>) -> events::ContractNoteCreated {
    for action in actions {
        if let ServerAction::CreateContractNote(event) = *action {
            return event;
        }
    }
    panic_with_felt252('NO_CONTRACT_NOTE_EVENT')
}

fn create_contract_note(
    test: @Test,
    user: @User,
    token: ContractAddress,
    use_source: UseNoteInput,
    controller: ContractAddress,
) -> events::ContractNoteCreated {
    let invoke = InvokeExternalInput {
        contract_address: controller, calldata: [CALLBACK_MARKER].span(),
    };
    let actions = user
        .execute(
            [
                ClientAction::UseNote(use_source),
                ClientAction::CreateContractNote(
                    CreateContractNoteInput {
                        controller_contract: controller,
                        controller_commitment: CONTROLLER_COMMITMENT,
                        token,
                        amount: AMOUNT,
                        nonce: NONCE,
                        blinding: BLINDING,
                    },
                ),
                ClientAction::InvokeExternal(invoke),
            ]
                .span(),
        );
    let expected_actions_hash = compute_contract_note_actions_hash(
        :actions,
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: *test.privacy.address,
    );
    let dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    dispatcher.set_expected_actions_hash(:expected_actions_hash);
    test.privacy.apply_actions(:actions);
    contract_note_event(:actions)
}

fn spend_actions(
    user: @User, note_id: felt252, output: CreateEncNoteInput, controller: ContractAddress,
) -> Span<ServerAction> {
    user
        .execute(
            [
                ClientAction::UseContractNote(
                    UseContractNoteInput { note_id, amount: AMOUNT, blinding: BLINDING },
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
fn test_contract_note_lifecycle_binds_exact_actions_and_authorizes_atomically() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let controller_dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    let created = create_contract_note(@test, @user, :token, :use_source, :controller);

    assert_eq!(controller_dispatcher.callback_count(), 1);
    assert_eq!(controller_dispatcher.last_created_note_id(), created.note_id);
    assert_eq!(controller_dispatcher.last_spent_nullifier(), 0);
    assert_eq!(created.controller_class_hash, get_class_hash(controller));
    assert_eq!(
        test.privacy.get_contract_note(note_id: created.note_id),
        ContractNote {
            note_commitment: created.note_commitment,
            controller_contract: controller,
            controller_class_hash: created.controller_class_hash,
            controller_commitment: CONTROLLER_COMMITMENT,
            token,
        },
    );

    let actions = spend_actions(@user, note_id: created.note_id, :output, :controller);
    let expected_actions_hash = compute_contract_note_actions_hash(
        :actions,
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
    );
    controller_dispatcher.set_expected_actions_hash(:expected_actions_hash);
    let mut spy = spy_events();
    test.privacy.apply_actions(:actions);

    let nullifier = compute_contract_note_nullifier(
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
        note_id: created.note_id,
        blinding: BLINDING,
    );
    assert!(test.privacy.contract_note_nullifier_exists(:nullifier));
    assert_eq!(controller_dispatcher.callback_count(), 2);
    assert_eq!(controller_dispatcher.last_actions_hash(), expected_actions_hash);
    assert_eq!(controller_dispatcher.last_created_note_id(), 0);
    assert_eq!(controller_dispatcher.last_spent_nullifier(), nullifier);
    let emitted_events = spy.get_events().emitted_by(contract_address: test.privacy.address).events;
    let expected_event = events::ContractNoteUsed {
        nullifier,
        controller_contract: controller,
        controller_commitment: CONTROLLER_COMMITMENT,
        controller_class_hash: created.controller_class_hash,
        token,
    };
    assert_expected_event_emitted(
        spied_event: emitted_events[0],
        :expected_event,
        expected_event_selector: @selector!("ContractNoteUsed"),
        expected_event_name: "ContractNoteUsed",
    );

    let replay = test.privacy.safe_apply_actions(:actions);
    assert_panic_with_felt_error(result: replay, expected_error: errors::NON_ZERO_VALUE);
}

#[test]
fn test_contract_note_spend_requires_callback_and_rolls_back() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let created = create_contract_note(@test, @user, :token, :use_source, :controller);

    let actions = user
        .execute(
            [
                ClientAction::UseContractNote(
                    UseContractNoteInput {
                        note_id: created.note_id, amount: AMOUNT, blinding: BLINDING,
                    },
                ),
                ClientAction::CreateEncNote(output),
            ]
                .span(),
        );
    let result = test.privacy.safe_apply_actions(:actions);
    assert_panic_with_felt_error(:result, expected_error: errors::CONTRACT_NOTE_CALLBACK_REQUIRED);
    let nullifier = compute_contract_note_nullifier(
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
        note_id: created.note_id,
        blinding: BLINDING,
    );
    assert!(!test.privacy.contract_note_nullifier_exists(:nullifier));
}

#[test]
fn test_contract_note_spend_rejects_wrong_target_and_denial() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let other_controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 1,
    );
    let created = create_contract_note(@test, @user, :token, :use_source, :controller);

    let wrong_target_actions = spend_actions(
        @user, note_id: created.note_id, :output, controller: other_controller,
    );
    let wrong_target = test.privacy.safe_apply_actions(actions: wrong_target_actions);
    assert_panic_with_felt_error(
        result: wrong_target, expected_error: errors::CONTRACT_NOTE_TARGET_MISMATCH,
    );

    let dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    dispatcher.set_allowed(false);
    let denied_actions = spend_actions(@user, note_id: created.note_id, :output, :controller);
    let denied = test.privacy.safe_apply_actions(actions: denied_actions);
    assert_panic_with_felt_error(result: denied, expected_error: CONTROLLER_DENIED);
    let nullifier = compute_contract_note_nullifier(
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
        note_id: created.note_id,
        blinding: BLINDING,
    );
    assert!(!test.privacy.contract_note_nullifier_exists(:nullifier));
}

#[test]
fn test_contract_note_spend_rejects_invalid_private_opening() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, _) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let created = create_contract_note(@test, @user, :token, :use_source, :controller);

    user
        .assert_actions_panic(
            [
                ClientAction::UseContractNote(
                    UseContractNoteInput {
                        note_id: created.note_id, amount: AMOUNT + 1, blinding: BLINDING,
                    },
                ),
            ]
                .span(),
            expected_error: errors::INVALID_CONTRACT_NOTE_OPENING,
        );
}

#[test]
fn test_contract_note_callback_uses_dedicated_selector() {
    assert_ne!(CONTRACT_NOTE_INVOKE_SELECTOR, selector!("privacy_invoke"));
}
