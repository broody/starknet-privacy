use core::panic_with_felt252;
use privacy::actions::{
    ClientAction, CreateEncNoteInput, CreatePredicateNoteInput, InvokeExternalInput, ServerAction,
    UseNoteInput, UsePredicateNoteInput,
};
use privacy::hashes::compute_predicate_nullifier;
use privacy::objects::PredicateNote;
use privacy::tests::mock_predicate::MockPredicate::{CALLBACK_MARKER, PREDICATE_DENIED};
use privacy::tests::mock_predicate::{IMockPredicateDispatcher, IMockPredicateDispatcherTrait};
use privacy::tests::utils_for_tests::{
    PrivacyCfgTrait, Test, TestTrait, User, UserTrait, deploy_mock_predicate,
};
use privacy::utils::compute_predicate_actions_hash;
use privacy::utils::constants::PREDICATE_INVOKE_SELECTOR;
use privacy::{errors, events};
use snforge_std::{EventSpyTrait, EventsFilterTrait, get_class_hash, spy_events};
use starknet::{ContractAddress, get_execution_info};
use starkware_utils_testing::test_utils::{
    assert_expected_event_emitted, assert_panic_with_felt_error,
};

const AMOUNT: u128 = 37;
const PREDICATE_COMMITMENT: felt252 = 'AUCTION_SETTLEMENT';
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

fn predicate_event(actions: Span<ServerAction>) -> events::PredicateNoteCreated {
    for action in actions {
        if let ServerAction::CreatePredicateNote(event) = *action {
            return event;
        }
    }
    panic_with_felt252('NO_PREDICATE_EVENT')
}

fn create_predicate_note(
    test: @Test,
    user: @User,
    token: ContractAddress,
    use_source: UseNoteInput,
    predicate: ContractAddress,
) -> events::PredicateNoteCreated {
    let invoke = InvokeExternalInput {
        contract_address: predicate, calldata: [CALLBACK_MARKER].span(),
    };
    let actions = user
        .execute(
            [
                ClientAction::UseNote(use_source),
                ClientAction::CreatePredicateNote(
                    CreatePredicateNoteInput {
                        predicate_address: predicate,
                        predicate_commitment: PREDICATE_COMMITMENT,
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
    let expected_actions_hash = compute_predicate_actions_hash(
        :actions,
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: *test.privacy.address,
    );
    let dispatcher = IMockPredicateDispatcher { contract_address: predicate };
    dispatcher.set_expected_actions_hash(:expected_actions_hash);
    test.privacy.apply_actions(:actions);
    predicate_event(:actions)
}

fn spend_actions(
    user: @User, note_id: felt252, output: CreateEncNoteInput, predicate: ContractAddress,
) -> Span<ServerAction> {
    user
        .execute(
            [
                ClientAction::UsePredicateNote(
                    UsePredicateNoteInput { note_id, amount: AMOUNT, blinding: BLINDING },
                ),
                ClientAction::CreateEncNote(output),
                ClientAction::InvokeExternal(
                    InvokeExternalInput {
                        contract_address: predicate, calldata: [CALLBACK_MARKER].span(),
                    },
                ),
            ]
                .span(),
        )
}

#[test]
fn test_predicate_note_lifecycle_binds_exact_actions_and_authorizes_atomically() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let predicate = deploy_mock_predicate(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let predicate_dispatcher = IMockPredicateDispatcher { contract_address: predicate };
    let created = create_predicate_note(@test, @user, :token, :use_source, :predicate);

    assert_eq!(predicate_dispatcher.callback_count(), 1);
    assert_eq!(predicate_dispatcher.last_created_note_id(), created.note_id);
    assert_eq!(predicate_dispatcher.last_spent_nullifier(), 0);
    assert_eq!(created.predicate_class_hash, get_class_hash(predicate));
    assert_eq!(
        test.privacy.get_predicate_note(note_id: created.note_id),
        PredicateNote {
            note_commitment: created.note_commitment,
            predicate_address: predicate,
            predicate_class_hash: created.predicate_class_hash,
            predicate_commitment: PREDICATE_COMMITMENT,
            token,
        },
    );

    let actions = spend_actions(@user, note_id: created.note_id, :output, :predicate);
    let expected_actions_hash = compute_predicate_actions_hash(
        :actions,
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
    );
    predicate_dispatcher.set_expected_actions_hash(:expected_actions_hash);
    let mut spy = spy_events();
    test.privacy.apply_actions(:actions);

    let nullifier = compute_predicate_nullifier(
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
        note_id: created.note_id,
        blinding: BLINDING,
    );
    assert!(test.privacy.predicate_nullifier_exists(:nullifier));
    assert_eq!(predicate_dispatcher.callback_count(), 2);
    assert_eq!(predicate_dispatcher.last_actions_hash(), expected_actions_hash);
    assert_eq!(predicate_dispatcher.last_created_note_id(), 0);
    assert_eq!(predicate_dispatcher.last_spent_nullifier(), nullifier);
    let emitted_events = spy.get_events().emitted_by(contract_address: test.privacy.address).events;
    let expected_event = events::PredicateNoteUsed {
        nullifier,
        predicate_address: predicate,
        predicate_commitment: PREDICATE_COMMITMENT,
        predicate_class_hash: created.predicate_class_hash,
        token,
    };
    assert_expected_event_emitted(
        spied_event: emitted_events[0],
        :expected_event,
        expected_event_selector: @selector!("PredicateNoteUsed"),
        expected_event_name: "PredicateNoteUsed",
    );

    let replay = test.privacy.safe_apply_actions(:actions);
    assert_panic_with_felt_error(result: replay, expected_error: errors::NON_ZERO_VALUE);
}

#[test]
fn test_predicate_spend_requires_callback_and_rolls_back() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let predicate = deploy_mock_predicate(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let created = create_predicate_note(@test, @user, :token, :use_source, :predicate);

    let actions = user
        .execute(
            [
                ClientAction::UsePredicateNote(
                    UsePredicateNoteInput {
                        note_id: created.note_id, amount: AMOUNT, blinding: BLINDING,
                    },
                ),
                ClientAction::CreateEncNote(output),
            ]
                .span(),
        );
    let result = test.privacy.safe_apply_actions(:actions);
    assert_panic_with_felt_error(:result, expected_error: errors::PREDICATE_CALLBACK_REQUIRED);
    let nullifier = compute_predicate_nullifier(
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
        note_id: created.note_id,
        blinding: BLINDING,
    );
    assert!(!test.privacy.predicate_nullifier_exists(:nullifier));
}

#[test]
fn test_predicate_spend_rejects_wrong_target_and_denial() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let predicate = deploy_mock_predicate(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let other_predicate = deploy_mock_predicate(
        pool_address: test.privacy.address, allowed: true, salt: 1,
    );
    let created = create_predicate_note(@test, @user, :token, :use_source, :predicate);

    let wrong_target_actions = spend_actions(
        @user, note_id: created.note_id, :output, predicate: other_predicate,
    );
    let wrong_target = test.privacy.safe_apply_actions(actions: wrong_target_actions);
    assert_panic_with_felt_error(
        result: wrong_target, expected_error: errors::PREDICATE_TARGET_MISMATCH,
    );

    let dispatcher = IMockPredicateDispatcher { contract_address: predicate };
    dispatcher.set_allowed(false);
    let denied_actions = spend_actions(@user, note_id: created.note_id, :output, :predicate);
    let denied = test.privacy.safe_apply_actions(actions: denied_actions);
    assert_panic_with_felt_error(result: denied, expected_error: PREDICATE_DENIED);
    let nullifier = compute_predicate_nullifier(
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
        note_id: created.note_id,
        blinding: BLINDING,
    );
    assert!(!test.privacy.predicate_nullifier_exists(:nullifier));
}

#[test]
fn test_predicate_spend_rejects_invalid_private_opening() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, _) = source_note(ref test, ref user);
    let predicate = deploy_mock_predicate(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let created = create_predicate_note(@test, @user, :token, :use_source, :predicate);

    user
        .assert_actions_panic(
            [
                ClientAction::UsePredicateNote(
                    UsePredicateNoteInput {
                        note_id: created.note_id, amount: AMOUNT + 1, blinding: BLINDING,
                    },
                ),
            ]
                .span(),
            expected_error: errors::INVALID_PREDICATE_OPENING,
        );
}

#[test]
fn test_predicate_callback_uses_dedicated_selector() {
    assert_ne!(PREDICATE_INVOKE_SELECTOR, selector!("privacy_invoke"));
}
