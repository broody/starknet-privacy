use privacy::objects::{EncPrivateKey, EncUserAddr, OpenNoteScreeningPolicy};
use starknet::{ClassHash, ContractAddress};

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct ViewingKeySet {
    /// The user address.
    #[key]
    pub user_addr: ContractAddress,
    /// The public viewing key.
    #[key]
    pub public_key: felt252,
    /// The encrypted private key.
    pub enc_private_key: EncPrivateKey,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct Withdrawal {
    /// Encrypted address of the withdrawing user. Can be decrypted by the auditor.
    pub enc_user_addr: EncUserAddr,
    /// The address the funds are withdrawn to.
    #[key]
    pub to_addr: ContractAddress,
    /// The token address.
    #[key]
    pub token: ContractAddress,
    /// The withdrawn amount.
    pub amount: u128,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct Deposit {
    /// The depositing user address.
    #[key]
    pub user_addr: ContractAddress,
    /// The token address.
    #[key]
    pub token: ContractAddress,
    /// The deposited amount.
    pub amount: u128,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct AuditorPublicKeySet {
    /// The auditor public key.
    pub auditor_public_key: felt252,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct ScreenerPublicKeySet {
    /// The screener public key is used to verify depositor screening attestations.
    pub screener_public_key: felt252,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct OpenNoteCreated {
    /// Encrypted recipient address (the note owner). Can be decrypted by the auditor.
    pub enc_recipient_addr: EncUserAddr,
    /// The token address.
    #[key]
    pub token: ContractAddress,
    /// The note ID.
    #[key]
    pub note_id: felt252,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct OpenNoteDeposited {
    /// The address that performed the deposit.
    #[key]
    pub depositor: ContractAddress,
    /// The token address.
    #[key]
    pub token: ContractAddress,
    /// The note ID deposited into.
    #[key]
    pub note_id: felt252,
    /// The deposited amount.
    pub amount: u128,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct ExternalContractInvoked {
    /// The external contract the pool invoked.
    #[key]
    pub contract_address: ContractAddress,
    /// The entry point selector the pool called: `privacy_invoke` for a plain invoke,
    /// `privacy_invoke_with_computation` for a compute-and-invoke. Lets consumers tell the
    /// two apart (the private computation itself is not observable). Calldata is not emitted.
    #[key]
    pub selector: felt252,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct EncNoteCreated {
    /// The note ID.
    #[key]
    pub note_id: felt252,
    /// The packed note value (encodes salt and amount).
    pub packed_value: felt252,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct NoteUsed {
    /// The nullifier of the used note.
    #[key]
    pub nullifier: felt252,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct PredicateNoteCreated {
    /// The note ID.
    #[key]
    pub note_id: felt252,
    /// The predicate contract address.
    #[key]
    pub predicate_address: ContractAddress,
    /// The application-specific predicate commitment.
    #[key]
    pub predicate_commitment: felt252,
    /// The predicate implementation bound for the lifetime of the note.
    pub predicate_class_hash: ClassHash,
    /// The note's token. Predicate-note token types are intentionally public to the predicate.
    pub token: ContractAddress,
    /// Hiding commitment to the private amount and blinding.
    pub note_commitment: felt252,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct PredicateNoteUsed {
    /// Secret-derived nullifier of the used predicate note. This does not reveal its note ID.
    #[key]
    pub nullifier: felt252,
    /// The predicate contract address that authorized the spend.
    #[key]
    pub predicate_address: ContractAddress,
    /// Application-specific policy commitment bound at creation.
    #[key]
    pub predicate_commitment: felt252,
    /// The implementation class bound at creation.
    pub predicate_class_hash: ClassHash,
    /// Token released into the private transaction's conservation balance.
    pub token: ContractAddress,
}
#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct FeeAmountSet {
    /// The fee amount in FRI per `apply_actions` call.
    pub fee_amount: u128,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct FeeCollectorSet {
    /// The address that receives the fee.
    pub fee_collector: ContractAddress,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct ProofValidityBlocksSet {
    /// The number of blocks that a proof is valid for.
    pub proof_validity_blocks: u64,
}

#[derive(Serde, Copy, Debug, Drop, PartialEq, starknet::Event)]
pub struct OpenNoteScreeningPolicySet {
    /// The open-note depositor address whose screening policy changed.
    #[key]
    pub depositor: ContractAddress,
    /// New screening policy.
    pub policy: OpenNoteScreeningPolicy,
}
