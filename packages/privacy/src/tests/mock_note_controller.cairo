//! Controller used to exercise private validation and proof-bound controlled-note application.

use starknet::ClassHash;

#[starknet::interface]
pub trait IMockNoteController<T> {
    fn upgrade(ref self: T, new_class_hash: ClassHash);
    fn set_allowed(ref self: T, allowed: bool);
    fn set_expected_amount(ref self: T, expected_amount: u128);
    fn set_epoch(ref self: T, epoch: felt252);
    fn callback_count(self: @T) -> u32;
}

#[starknet::contract]
pub mod MockNoteController {
    use core::num::traits::Zero;
    use privacy::interface::IControlledNoteController;
    use privacy::objects::ControlledValidationContext;
    use privacy::utils::{validate_controlled_apply_caller, validate_controlled_validation_context};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait};
    use super::IMockNoteController;

    pub const CALLBACK_MARKER: felt252 = 'CONTROLLED_CALLBACK';
    pub const AUTHORIZATION: felt252 = 'CONTROLLED_AUTH';
    pub const CONTROLLER_DENIED: felt252 = 'CONTROLLER_DENIED';
    pub const WRONG_PRIVATE_AMOUNT: felt252 = 'WRONG_PRIVATE_AMOUNT';
    pub const STALE_AUTHORIZATION: felt252 = 'STALE_AUTHORIZATION';

    #[storage]
    struct Storage {
        pool_address: ContractAddress,
        allowed: bool,
        expected_amount: u128,
        epoch: felt252,
        callback_count: u32,
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

        fn set_epoch(ref self: ContractState, epoch: felt252) {
            self.epoch.write(epoch);
        }

        fn callback_count(self: @ContractState) -> u32 {
            self.callback_count.read()
        }
    }

    #[abi(embed_v0)]
    impl ControlledNoteControllerImpl of IControlledNoteController<ContractState> {
        fn privacy_validate_controlled_transition(
            self: @ContractState,
            context: ControlledValidationContext,
            identity_key: felt252,
            private_auxiliary_data: Span<felt252>,
            public_calldata: Span<felt252>,
        ) -> Span<felt252> {
            self._validate_private_context(:context);
            if identity_key.is_zero() {
                assert(private_auxiliary_data.is_empty(), 'UNEXPECTED_PRIVATE_DATA');
            } else {
                assert(private_auxiliary_data == [CALLBACK_MARKER].span(), 'WRONG_PRIVATE_DATA');
            }
            assert(public_calldata == [CALLBACK_MARKER].span(), 'WRONG_PUBLIC_DATA');
            array![AUTHORIZATION, self.epoch.read()].span()
        }

        fn privacy_apply_controlled_transition(
            ref self: ContractState,
            public_authorization: Span<felt252>,
            public_calldata: Span<felt252>,
        ) {
            validate_controlled_apply_caller(expected_pool: self.pool_address.read());
            assert(
                public_authorization == [AUTHORIZATION, self.epoch.read()].span(),
                STALE_AUTHORIZATION,
            );
            assert(public_calldata == [CALLBACK_MARKER].span(), 'WRONG_PUBLIC_DATA');
            self.callback_count.write(self.callback_count.read() + 1);
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
