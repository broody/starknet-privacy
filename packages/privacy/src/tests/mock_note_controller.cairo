//! Contract-note callback used to exercise contract-note authorization and context binding.

use privacy::objects::{ContractNoteContext, OpenNoteDeposit};
use starknet::ClassHash;

#[starknet::interface]
pub trait IMockNoteController<T> {
    fn upgrade(ref self: T, new_class_hash: ClassHash);
    fn set_allowed(ref self: T, allowed: bool);
    fn set_expected_actions_hash(ref self: T, expected_actions_hash: felt252);
    fn callback_count(self: @T) -> u32;
    fn last_actions_hash(self: @T) -> felt252;
    fn last_created_note_id(self: @T) -> felt252;
    fn last_spent_nullifier(self: @T) -> felt252;
    fn privacy_contract_note_invoke(
        ref self: T, context: ContractNoteContext, marker: felt252,
    ) -> Span<OpenNoteDeposit>;
}

#[starknet::contract]
pub mod MockNoteController {
    use core::num::traits::Zero;
    use privacy::actions::ServerAction;
    use privacy::objects::{ContractNoteContext, OpenNoteDeposit};
    use privacy::utils::validate_contract_note_context;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait, get_caller_address};
    use super::IMockNoteController;

    pub const CALLBACK_MARKER: felt252 = 'CONTRACT_NOTE_CALLBACK';
    pub const CONTROLLER_DENIED: felt252 = 'CONTROLLER_DENIED';
    pub const WRONG_ACTIONS_HASH: felt252 = 'WRONG_ACTIONS_HASH';

    #[storage]
    struct Storage {
        pool_address: ContractAddress,
        allowed: bool,
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

        fn privacy_contract_note_invoke(
            ref self: ContractState, context: ContractNoteContext, marker: felt252,
        ) -> Span<OpenNoteDeposit> {
            let pool_address = get_caller_address();
            assert(pool_address == self.pool_address.read(), 'CALLER_NOT_POOL');
            assert(marker == CALLBACK_MARKER, 'WRONG_MARKER');
            assert(self.allowed.read(), CONTROLLER_DENIED);

            let expected_actions_hash = self.expected_actions_hash.read();
            if expected_actions_hash.is_non_zero() {
                assert(context.actions_hash == expected_actions_hash, WRONG_ACTIONS_HASH);
            }
            let actions = validate_contract_note_context(context);

            let mut created_count: usize = 0;
            let mut spent_count: usize = 0;
            let mut created_note_id: felt252 = Zero::zero();
            let mut spent_nullifier: felt252 = Zero::zero();
            for action in actions {
                match *action {
                    ServerAction::CreateContractNote(event) => {
                        created_count += 1;
                        created_note_id = event.note_id;
                    },
                    ServerAction::UseContractNote(event) => {
                        spent_count += 1;
                        spent_nullifier = event.nullifier;
                    },
                    _ => {},
                }
            }
            assert(created_count <= 1, 'TOO_MANY_CREATED');
            assert(spent_count <= 1, 'TOO_MANY_SPENT');
            self.last_actions_hash.write(context.actions_hash);
            self.last_created_note_id.write(created_note_id);
            self.last_spent_nullifier.write(spent_nullifier);
            self.callback_count.write(self.callback_count.read() + 1);
            [].span()
        }
    }
}
