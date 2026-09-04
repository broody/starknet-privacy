//! Controller used to exercise private validation and proof-bound controlled-note application.

use starknet::ClassHash;

#[starknet::interface]
pub trait IMockNoteController<T> {
    fn upgrade(ref self: T, new_class_hash: ClassHash);
    fn set_allowed(ref self: T, allowed: bool);
    fn set_expected_amount(ref self: T, expected_amount: u128);
    fn set_expected_actions_hash(ref self: T, expected_actions_hash: felt252);
    fn callback_count(self: @T) -> u32;
    fn last_actions_hash(self: @T) -> felt252;
    fn last_created_note_id(self: @T) -> felt252;
    fn last_spent_nullifier(self: @T) -> felt252;
}

#[starknet::contract]
pub mod MockNoteController {
    use core::num::traits::Zero;
    use privacy::actions::ServerAction;
    use privacy::interface::IControlledNoteController;
    use privacy::objects::{
        ControlledApplyContext, ControlledInvokeResult, ControlledValidationContext,
        OpenNoteDeposit,
    };
    use privacy::utils::{validate_controlled_apply_context, validate_controlled_validation_context};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait};
    use super::IMockNoteController;

    pub const CALLBACK_MARKER: felt252 = 'CONTROLLED_CALLBACK';
    pub const AUTHORIZATION: felt252 = 'CONTROLLED_AUTH';
    pub const CONTROLLER_DENIED: felt252 = 'CONTROLLER_DENIED';
    pub const WRONG_ACTIONS_HASH: felt252 = 'WRONG_ACTIONS_HASH';
    pub const WRONG_PRIVATE_AMOUNT: felt252 = 'WRONG_PRIVATE_AMOUNT';

    #[storage]
    struct Storage {
        pool_address: ContractAddress,
        allowed: bool,
        expected_amount: u128,
        expected_actions_hash: felt252,
        callback_count: u32,
        last_actions_hash: felt252,
        last_created_note_id: felt252,
        last_spent_nullifier: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, pool_address: ContractAddress, allowed: bool) {
        self.pool_address.write(pool_address);
        self.allowed.write(allowed);
    }

    #[abi(embed_v0)]
    impl MockNoteControllerImpl of IMockNoteController<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            replace_class_syscall(new_class_hash).unwrap_syscall();
        }

        fn set_allowed(ref self: ContractState, allowed: bool) {
            self.allowed.write(allowed);
        }

        fn set_expected_amount(ref self: ContractState, expected_amount: u128) {
            self.expected_amount.write(expected_amount);
        }

        fn set_expected_actions_hash(ref self: ContractState, expected_actions_hash: felt252) {
            self.expected_actions_hash.write(expected_actions_hash);
        }

        fn callback_count(self: @ContractState) -> u32 {
            self.callback_count.read()
        }

        fn last_actions_hash(self: @ContractState) -> felt252 {
            self.last_actions_hash.read()
        }

        fn last_created_note_id(self: @ContractState) -> felt252 {
            self.last_created_note_id.read()
        }

        fn last_spent_nullifier(self: @ContractState) -> felt252 {
            self.last_spent_nullifier.read()
        }
    }

    #[abi(embed_v0)]
    impl ControlledNoteControllerImpl of IControlledNoteController<ContractState> {
        fn privacy_validate_controlled_transition(
            self: @ContractState, context: ControlledValidationContext, calldata: Span<felt252>,
        ) -> Span<felt252> {
            self._validate_private_context(:context);
            assert(calldata == [CALLBACK_MARKER].span(), 'WRONG_MARKER');
            array![AUTHORIZATION].span()
        }

        fn privacy_validate_controlled_transition_with_computation(
            self: @ContractState,
            context: ControlledValidationContext,
            identity_key: felt252,
            computation_data: Span<felt252>,
        ) -> Span<felt252> {
            self._validate_private_context(:context);
            assert(identity_key.is_non_zero(), 'ZERO_IDENTITY_KEY');
            assert(computation_data == [CALLBACK_MARKER].span(), 'WRONG_MARKER');
            array![AUTHORIZATION].span()
        }

        fn privacy_apply_controlled_transition(
            ref self: ContractState,
            context: ControlledApplyContext,
            authorization_data: Span<felt252>,
            calldata: Span<felt252>,
        ) -> ControlledInvokeResult {
            assert(authorization_data == [AUTHORIZATION].span(), 'INVALID_AUTHORIZATION');
            assert(calldata == [CALLBACK_MARKER].span(), 'WRONG_MARKER');

            let expected_actions_hash = self.expected_actions_hash.read();
            if expected_actions_hash.is_non_zero() {
                assert(context.actions_hash == expected_actions_hash, WRONG_ACTIONS_HASH);
            }
            let actions = validate_controlled_apply_context(
                context, expected_pool: self.pool_address.read(),
            );
            let mut created_note_id: felt252 = Zero::zero();
            let mut spent_nullifier: felt252 = Zero::zero();
            for action in actions {
                match *action {
                    ServerAction::EmitControlledNoteCreated(event) => {
                        assert(created_note_id.is_zero(), 'TOO_MANY_CREATED');
                        created_note_id = event.note_id;
                    },
                    ServerAction::EmitControlledNoteUsed(event) => {
                        assert(spent_nullifier.is_zero(), 'TOO_MANY_SPENT');
                        spent_nullifier = event.nullifier;
                    },
                    _ => {},
                }
            }
            self.last_actions_hash.write(context.actions_hash);
            self.last_created_note_id.write(created_note_id);
            self.last_spent_nullifier.write(spent_nullifier);
            self.callback_count.write(self.callback_count.read() + 1);

            let open_note_deposits: Array<OpenNoteDeposit> = array![];
            let associated_addresses: Array<ContractAddress> = array![];
            ControlledInvokeResult {
                open_note_deposits: open_note_deposits.span(),
                associated_addresses: associated_addresses.span(),
            }
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _validate_private_context(self: @ContractState, context: ControlledValidationContext) {
            let transition = validate_controlled_validation_context(
                context, expected_pool: self.pool_address.read(),
            );
            assert(self.allowed.read(), CONTROLLER_DENIED);

            let expected_amount = self.expected_amount.read();
            if expected_amount.is_non_zero() {
                let actual_amount = if !transition.controlled_inputs.is_empty() {
                    (*transition.controlled_inputs[0]).amount
                } else {
                    (*transition.controlled_outputs[0]).amount
                };
                assert(actual_amount == expected_amount, WRONG_PRIVATE_AMOUNT);
            }
        }
    }
}
