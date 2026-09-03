//! Predicate callback used to exercise predicate-note authorization and context binding.

use privacy::objects::{OpenNoteDeposit, PredicateContext};

#[starknet::interface]
pub trait IMockPredicate<T> {
    fn set_allowed(ref self: T, allowed: bool);
    fn set_expected_actions_hash(ref self: T, expected_actions_hash: felt252);
    fn callback_count(self: @T) -> u32;
    fn last_actions_hash(self: @T) -> felt252;
    fn last_created_note_id(self: @T) -> felt252;
    fn last_spent_nullifier(self: @T) -> felt252;
    fn privacy_predicate_invoke(
        ref self: T, context: PredicateContext, marker: felt252,
    ) -> Span<OpenNoteDeposit>;
}

#[starknet::contract]
pub mod MockPredicate {
    use core::num::traits::Zero;
    use privacy::actions::ServerAction;
    use privacy::objects::{OpenNoteDeposit, PredicateContext};
    use privacy::utils::compute_predicate_actions_hash;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_execution_info};
    use super::IMockPredicate;

    pub const CALLBACK_MARKER: felt252 = 'PREDICATE_CALLBACK';
    pub const PREDICATE_DENIED: felt252 = 'PREDICATE_DENIED';
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
    impl MockPredicateImpl of IMockPredicate<ContractState> {
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

        fn privacy_predicate_invoke(
            ref self: ContractState, context: PredicateContext, marker: felt252,
        ) -> Span<OpenNoteDeposit> {
            assert(get_caller_address() == self.pool_address.read(), 'CALLER_NOT_POOL');
            assert(context.pool_address == self.pool_address.read(), 'WRONG_POOL');
            assert(context.chain_id == get_execution_info().tx_info.chain_id, 'WRONG_CHAIN');
            assert(marker == CALLBACK_MARKER, 'WRONG_MARKER');
            assert(self.allowed.read(), PREDICATE_DENIED);

            let expected_actions_hash = self.expected_actions_hash.read();
            if expected_actions_hash.is_non_zero() {
                assert(context.actions_hash == expected_actions_hash, WRONG_ACTIONS_HASH);
            }
            let mut serialized_actions = context.serialized_actions;
            let actions: Span<ServerAction> = Serde::deserialize(ref serialized_actions)
                .expect('INVALID_ACTIONS');
            assert(serialized_actions.is_empty(), 'TRAILING_ACTION_DATA');
            assert(
                context
                    .actions_hash == compute_predicate_actions_hash(
                        :actions, chain_id: context.chain_id, pool_address: context.pool_address,
                    ),
                WRONG_ACTIONS_HASH,
            );

            assert(context.created_notes.len() <= 1, 'TOO_MANY_CREATED');
            assert(context.spent_notes.len() <= 1, 'TOO_MANY_SPENT');
            self.last_actions_hash.write(context.actions_hash);
            self
                .last_created_note_id
                .write(
                    if context.created_notes.is_empty() {
                        Zero::zero()
                    } else {
                        (*context.created_notes[0]).note_id
                    },
                );
            self
                .last_spent_nullifier
                .write(
                    if context.spent_notes.is_empty() {
                        Zero::zero()
                    } else {
                        (*context.spent_notes[0]).nullifier
                    },
                );
            self.callback_count.write(self.callback_count.read() + 1);
            [].span()
        }
    }
}
