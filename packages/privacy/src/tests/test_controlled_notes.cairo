use core::panic_with_felt252;
use privacy::actions::{
    ClientAction, ComputeAndInvokeInput, CreateControlledNoteInput, CreateEncNoteInput,
    InvokeExternalInput, ServerAction, UseControlledNoteInput, UseNoteInput,
};
use privacy::hashes::compute_controlled_note_nullifier;
use privacy::objects::ControlledNote;
use privacy::tests::mock_note_controller::MockNoteController::{
    AUTHORIZATION, CALLBACK_MARKER, CONTROLLER_DENIED, WRONG_PRIVATE_AMOUNT,
};
use privacy::tests::mock_note_controller::{
    IMockNoteControllerDispatcher, IMockNoteControllerDispatcherTrait,
};
use privacy::tests::utils_for_tests::{
    PrivacyCfgTrait, Test, TestTrait, User, UserTrait, deploy_mock_note_controller,
};
use privacy::utils::compute_controlled_note_actions_hash;
use privacy::utils::constants::{ERR_WRAPPER, INVOKE_SELECTOR, INVOKE_WITH_COMPUTATION_SELECTOR};
use privacy::{errors, events};
use starknet::{ContractAddress, get_execution_info};
use starkware_utils_testing::test_utils::assert_panic_with_felt_error;

const AMOUNT: u128 = 37;
const POLICY_COMMITMENT: felt252 = 'AUCTION_SETTLEMENT';
const SPEND_KEY: felt252 = 'PRIVATE_SPEND_KEY';

fn assert_controller_rejected(result: Result<(), Array<felt252>>, expected_error: felt252) {
    let panic_data = result.expect_err('EXPECTED_CONTROLLER_REJECTION');
    assert_eq!(*panic_data[0], ERR_WRAPPER);
    assert_eq!(*panic_data[1], expected_error);
}

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

fn controlled_note_event(actions: Span<ServerAction>) -> events::ControlledNoteCreated {
    for action in actions {
        if let ServerAction::EmitControlledNoteCreated(event) = *action {
            return event;
        }
    }
    panic_with_felt252('NO_CONTROLLED_NOTE_EVENT')
}

fn create_controlled_note(
    test: @Test,
    user: @User,
    token: ContractAddress,
    use_source: UseNoteInput,
    controller: ContractAddress,
) -> events::ControlledNoteCreated {
    let dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    dispatcher.set_expected_amount(expected_amount: AMOUNT);
    let actions = user
        .execute(
            [
                ClientAction::UseNote(use_source),
                ClientAction::CreateControlledNote(
                    CreateControlledNoteInput {
                        controller,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        amount: AMOUNT,
                        spend_key: SPEND_KEY,
                    },
                ),
                ClientAction::InvokeExternal(
                    InvokeExternalInput {
                        contract_address: controller, calldata: [CALLBACK_MARKER].span(),
                    },
                ),
            ]
                .span(),
        );
    let expected_actions_hash = compute_controlled_note_actions_hash(
        :actions,
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: *test.privacy.address,
    );
    dispatcher.set_expected_actions_hash(:expected_actions_hash);
    test.privacy.apply_actions(:actions);
    controlled_note_event(:actions)
}

fn spend_actions(
    user: @User, note_id: felt252, output: CreateEncNoteInput, controller: ContractAddress,
) -> Span<ServerAction> {
    user
        .execute(
            [
                ClientAction::UseControlledNote(
                    UseControlledNoteInput {
                        note_id,
                        policy_commitment: POLICY_COMMITMENT,
                        token: output.token,
                        amount: AMOUNT,
                        spend_key: SPEND_KEY,
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
        )
}

#[test]
fn test_controlled_actions_hash_is_chain_and_pool_bound() {
    let actions: Array<ServerAction> = array![];
    let chain_id = 'CHAIN_ID';
    let pool_address: ContractAddress = 'POOL_ADDRESS'.try_into().unwrap();
    let actions_hash = compute_controlled_note_actions_hash(
        actions: actions.span(), :chain_id, :pool_address,
    );

    assert_ne!(
        actions_hash,
        compute_controlled_note_actions_hash(
            actions: actions.span(), chain_id: 'OTHER_CHAIN', :pool_address,
        ),
    );
    assert_ne!(
        actions_hash,
        compute_controlled_note_actions_hash(
            actions: actions.span(),
            :chain_id,
            pool_address: 'OTHER_POOL_ADDRESS'.try_into().unwrap(),
        ),
    );
}

#[test]
fn test_controlled_note_lifecycle_uses_private_validation_and_explicit_authorization() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let dispatcher = IMockNoteControllerDispatcher { contract_address: controller };
    let created = create_controlled_note(@test, @user, :token, :use_source, :controller);

    assert_eq!(dispatcher.callback_count(), 1);
    assert_eq!(dispatcher.last_created_note_id(), created.note_id);
    assert_eq!(
        test.privacy.get_controlled_note(note_id: created.note_id),
        ControlledNote { note_commitment: created.note_commitment, controller },
    );

    let actions = spend_actions(@user, note_id: created.note_id, :output, :controller);
    let mut found_authorization = false;
    for action in actions {
        if let ServerAction::ControlledInvoke(input) = *action {
            assert_eq!(input.controller, controller);
            assert_eq!(input.authorization_data, [AUTHORIZATION].span());
            assert_eq!(input.source_selector, INVOKE_SELECTOR);
            found_authorization = true;
        }
    }
    assert!(found_authorization);
    let expected_actions_hash = compute_controlled_note_actions_hash(
        :actions,
        chain_id: get_execution_info().tx_info.chain_id,
        pool_address: test.privacy.address,
    );
    dispatcher.set_expected_actions_hash(:expected_actions_hash);
    test.privacy.apply_actions(:actions);

    let nullifier = compute_controlled_note_nullifier(
        note_id: created.note_id, spend_key: SPEND_KEY,
    );
    assert!(test.privacy.nullifier_exists(:nullifier));
    assert_eq!(dispatcher.callback_count(), 2);
    assert_eq!(dispatcher.last_actions_hash(), expected_actions_hash);
    assert_eq!(dispatcher.last_spent_nullifier(), nullifier);

    let replay = test.privacy.safe_apply_actions(:actions);
    assert_panic_with_felt_error(result: replay, expected_error: errors::NON_ZERO_VALUE);
}

#[test]
fn test_controlled_note_requires_controller_invocation_during_proving() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, _) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    user
        .assert_actions_panic(
            [
                ClientAction::UseNote(use_source),
                ClientAction::CreateControlledNote(
                    CreateControlledNoteInput {
                        controller,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        amount: AMOUNT,
                        spend_key: SPEND_KEY,
                    },
                ),
            ]
                .span(),
            expected_error: errors::CONTROLLED_NOTE_AUTHORIZATION_REQUIRED,
        );
}

#[test]
fn test_controlled_note_transaction_rejects_multiple_controllers() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, _) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let other = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 1,
    );

    user
        .assert_actions_panic(
            [
                ClientAction::UseNote(use_source),
                ClientAction::CreateControlledNote(
                    CreateControlledNoteInput {
                        controller,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        amount: 18,
                        spend_key: SPEND_KEY,
                    },
                ),
                ClientAction::CreateControlledNote(
                    CreateControlledNoteInput {
                        controller: other,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        amount: 19,
                        spend_key: SPEND_KEY + 1,
                    },
                ),
                ClientAction::InvokeExternal(
                    InvokeExternalInput {
                        contract_address: controller, calldata: [CALLBACK_MARKER].span(),
                    },
                ),
            ]
                .span(),
            expected_error: errors::MULTIPLE_CONTROLLED_TARGETS,
        );
}

#[test]
fn test_controlled_note_rejects_wrong_target_and_controller_denial_before_proof() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, output) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let other = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 1,
    );
    let created = create_controlled_note(@test, @user, :token, :use_source, :controller);

    let use_controlled = ClientAction::UseControlledNote(
        UseControlledNoteInput {
            note_id: created.note_id,
            policy_commitment: POLICY_COMMITMENT,
            token,
            amount: AMOUNT,
            spend_key: SPEND_KEY,
        },
    );
    user
        .assert_actions_panic(
            [
                use_controlled, ClientAction::CreateEncNote(output),
                ClientAction::InvokeExternal(
                    InvokeExternalInput {
                        contract_address: other, calldata: [CALLBACK_MARKER].span(),
                    },
                ),
            ]
                .span(),
            expected_error: errors::CONTROLLED_NOTE_TARGET_MISMATCH,
        );

    IMockNoteControllerDispatcher { contract_address: controller }.set_allowed(false);
    assert_controller_rejected(
        user
            .safe_execute(
                [
                    use_controlled, ClientAction::CreateEncNote(output),
                    ClientAction::InvokeExternal(
                        InvokeExternalInput {
                            contract_address: controller, calldata: [CALLBACK_MARKER].span(),
                        },
                    ),
                ]
                    .span(),
            ),
        CONTROLLER_DENIED,
    );
}

#[test]
fn test_controlled_note_rejects_invalid_private_opening() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, _) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let created = create_controlled_note(@test, @user, :token, :use_source, :controller);

    user
        .assert_actions_panic(
            [
                ClientAction::UseControlledNote(
                    UseControlledNoteInput {
                        note_id: created.note_id,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        amount: AMOUNT + 1,
                        spend_key: SPEND_KEY,
                    },
                ),
            ]
                .span(),
            expected_error: errors::INVALID_CONTROLLED_NOTE_OPENING,
        );
    user
        .assert_actions_panic(
            [
                ClientAction::UseControlledNote(
                    UseControlledNoteInput {
                        note_id: created.note_id,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        amount: AMOUNT,
                        spend_key: 'WRONG_SPEND_KEY',
                    },
                ),
            ]
                .span(),
            expected_error: errors::INVALID_CONTROLLED_NOTE_OPENING,
        );
}

#[test]
fn test_controller_validates_pool_derived_private_amount() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, _) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    IMockNoteControllerDispatcher { contract_address: controller }
        .set_expected_amount(expected_amount: AMOUNT + 1);

    assert_controller_rejected(
        user
            .safe_execute(
                [
                    ClientAction::UseNote(use_source),
                    ClientAction::CreateControlledNote(
                        CreateControlledNoteInput {
                            controller,
                            policy_commitment: POLICY_COMMITMENT,
                            token,
                            amount: AMOUNT,
                            spend_key: SPEND_KEY,
                        },
                    ),
                    ClientAction::InvokeExternal(
                        InvokeExternalInput {
                            contract_address: controller, calldata: [CALLBACK_MARKER].span(),
                        },
                    ),
                ]
                    .span(),
            ),
        WRONG_PRIVATE_AMOUNT,
    );
}

#[test]
fn test_controlled_note_supports_private_computation_validation() {
    let mut test: Test = Default::default();
    let mut user = test.new_user();
    let (token, use_source, _) = source_note(ref test, ref user);
    let controller = deploy_mock_note_controller(
        pool_address: test.privacy.address, allowed: true, salt: 0,
    );
    let actions = user
        .execute(
            [
                ClientAction::UseNote(use_source),
                ClientAction::CreateControlledNote(
                    CreateControlledNoteInput {
                        controller,
                        policy_commitment: POLICY_COMMITMENT,
                        token,
                        amount: AMOUNT,
                        spend_key: SPEND_KEY,
                    },
                ),
                ClientAction::ComputeAndInvoke(
                    ComputeAndInvokeInput {
                        contract_address: controller,
                        compute_additional_data: [CALLBACK_MARKER].span(),
                        invoke_additional_data: [CALLBACK_MARKER].span(),
                    },
                ),
            ]
                .span(),
        );
    let mut found_authorization = false;
    for action in actions {
        if let ServerAction::ControlledInvoke(input) = *action {
            assert_eq!(input.source_selector, INVOKE_WITH_COMPUTATION_SELECTOR);
            found_authorization = true;
        }
    }
    assert!(found_authorization);
    test.privacy.apply_actions(:actions);
    assert_eq!(IMockNoteControllerDispatcher { contract_address: controller }.callback_count(), 1);
}
