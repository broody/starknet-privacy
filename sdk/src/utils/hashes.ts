/**
 * Hash utility functions for privacy operations.
 * AUTO-GENERATED from packages/privacy/src/hashes.cairo
 * To regenerate: npx tsx scripts/generate-hashes.ts
 */

import { hash } from "./crypto.js";

// Domain separation tags (from Cairo domain_separation module)
const CHANNEL_MARKER_TAG = "CHANNEL_MARKER_TAG:V1";
const CHANNEL_KEY_TAG = "CHANNEL_KEY_TAG:V1";
const SUBCHANNEL_MARKER_TAG = "SUBCHANNEL_MARKER_TAG:V1";
const SUBCHANNEL_ID_TAG = "SUBCHANNEL_ID_TAG:V1";
const NULLIFIER_TAG = "NULLIFIER_TAG:V1";
const ENC_CHANNEL_KEY_TAG = "ENC_CHANNEL_KEY_TAG:V1";
const ENC_SENDER_ADDR_TAG = "ENC_SENDER_ADDR_TAG:V1";
const NOTE_ID_TAG = "NOTE_ID_TAG:V1";
const ENC_AMOUNT_TAG = "ENC_AMOUNT_TAG:V1";
const ENC_TOKEN_TAG = "ENC_TOKEN_TAG:V1";
const ENC_PRIVATE_KEY_TAG = "ENC_PRIVATE_KEY_TAG:V1";
const ENC_USER_ADDR_TAG = "ENC_USER_ADDR_TAG:V1";
const ENC_RECIPIENT_ADDR_TAG = "ENC_RECIPIENT_ADDR_TAG:V1";
const OUTGOING_CHANNEL_ID_TAG = "OUTGOING_CHANNEL_ID_TAG:V1";
const IDENTITY_KEY_TAG = "IDENTITY_KEY_TAG:V1";
const ESCROW_NOTE_ID_TAG = "ESCROW_NOTE_ID_TAG:V1";
const ESCROW_NOTE_NONCE_TAG = "ESCROW_NOTE_NONCE_TAG:V1";
const ESCROW_NOTE_BLINDING_TAG = "ESCROW_NOTE_BLINDING_TAG:V1";
const ESCROW_NOTE_COMMIT_TAG = "ESCROW_NOTE_COMMIT_TAG:V1";
const ESCROW_NOTE_NULLIFIER_TAG = "ESCROW_NOTE_NULLIFIER_TAG:V1";
const OPEN_ESCROW_NOTE_ID_TAG = "OPEN_ESCROW_ID_TAG:V1";
const OPEN_ESCROW_NOTE_NONCE_TAG = "OPEN_ESCROW_NONCE_TAG:V1";
const OPEN_ESCROW_NOTE_COMMIT_TAG = "OPEN_ESCROW_COMMIT_TAG:V1";
const OPEN_ESCROW_NOTE_NULLIFIER_TAG = "OPEN_ESCROW_NULLIFIER_TAG:V1";

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_identity_key(user_addr: bigint, user_private_key: bigint, contract_address: bigint): bigint {
  return hash(IDENTITY_KEY_TAG, user_addr, user_private_key, contract_address);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_enc_private_key_hash(shared_x: bigint): bigint {
  return hash(ENC_PRIVATE_KEY_TAG, shared_x);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_enc_user_addr_hash(shared_x: bigint): bigint {
  return hash(ENC_USER_ADDR_TAG, shared_x);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_enc_token_hash(channel_key: bigint, index: number, salt: bigint): bigint {
  return hash(ENC_TOKEN_TAG, channel_key, index, 0n, salt);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_enc_channel_key_hash(shared_x: bigint): bigint {
  return hash(ENC_CHANNEL_KEY_TAG, shared_x);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_enc_sender_addr_hash(shared_x: bigint): bigint {
  return hash(ENC_SENDER_ADDR_TAG, shared_x);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_enc_recipient_addr_hash(sender_addr: bigint, sender_private_key: bigint, index: number, salt: bigint): bigint {
  return hash(ENC_RECIPIENT_ADDR_TAG, sender_addr, sender_private_key, index, 0n, salt);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_channel_key(sender_addr: bigint, sender_private_key: bigint, recipient_addr: bigint, recipient_public_key: bigint): bigint {
  return hash(CHANNEL_KEY_TAG, sender_addr, sender_private_key, recipient_addr, recipient_public_key);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_outgoing_channel_id(sender_addr: bigint, sender_private_key: bigint, index: number): bigint {
  return hash(OUTGOING_CHANNEL_ID_TAG, sender_addr, sender_private_key, index, 0n);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_channel_marker(channel_key: bigint, sender_addr: bigint, recipient_addr: bigint, recipient_public_key: bigint): bigint {
  return hash(CHANNEL_MARKER_TAG, channel_key, sender_addr, recipient_addr, recipient_public_key);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_subchannel_id(channel_key: bigint, index: number): bigint {
  return hash(SUBCHANNEL_ID_TAG, channel_key, index, 0n);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_subchannel_marker(channel_key: bigint, recipient_addr: bigint, recipient_public_key: bigint, token: bigint): bigint {
  return hash(SUBCHANNEL_MARKER_TAG, channel_key, recipient_addr, recipient_public_key, token);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_note_id(channel_key: bigint, token: bigint, index: number): bigint {
  return hash(NOTE_ID_TAG, channel_key, token, index, 0n);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_enc_amount_hash(channel_key: bigint, token: bigint, index: number, salt: bigint): bigint {
  return hash(ENC_AMOUNT_TAG, channel_key, token, index, 0n, salt);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_nullifier(channel_key: bigint, token: bigint, index: number, owner_private_key: bigint): bigint {
  return hash(NULLIFIER_TAG, channel_key, token, index, 0n, owner_private_key);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function derive_escrow_note_nonce(secret: bigint): bigint {
  return hash(ESCROW_NOTE_NONCE_TAG, secret);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function derive_escrow_note_blinding(secret: bigint): bigint {
  return hash(ESCROW_NOTE_BLINDING_TAG, secret);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_escrow_note_id(sender_addr: bigint, contract_address: bigint, policy_commitment: bigint, token: bigint, secret: bigint): bigint {
  return hash(ESCROW_NOTE_ID_TAG, sender_addr, contract_address, policy_commitment, token, derive_escrow_note_nonce(secret));
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_escrow_note_commitment(note_id: bigint, contract_address: bigint, policy_commitment: bigint, token: bigint, amount: bigint, secret: bigint): bigint {
  return hash(ESCROW_NOTE_COMMIT_TAG, note_id, contract_address, policy_commitment, token, amount, derive_escrow_note_blinding(secret));
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_escrow_note_nullifier(note_id: bigint, secret: bigint): bigint {
  return hash(ESCROW_NOTE_NULLIFIER_TAG, note_id, derive_escrow_note_blinding(secret));
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function derive_open_escrow_note_nonce(secret: bigint): bigint {
  return hash(OPEN_ESCROW_NOTE_NONCE_TAG, secret);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_open_escrow_note_id(sender_addr: bigint, contract_address: bigint, policy_commitment: bigint, token: bigint, secret: bigint): bigint {
  return hash(OPEN_ESCROW_NOTE_ID_TAG, sender_addr, contract_address, policy_commitment, token, derive_open_escrow_note_nonce(secret));
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_open_escrow_note_opening_commitment(note_id: bigint, contract_address: bigint, policy_commitment: bigint, token: bigint, secret: bigint): bigint {
  return hash(OPEN_ESCROW_NOTE_COMMIT_TAG, note_id, contract_address, policy_commitment, token, secret);
}

/** See packages/privacy/src/hashes.cairo for documentation. */
export function compute_open_escrow_note_nullifier(note_id: bigint, secret: bigint): bigint {
  return hash(OPEN_ESCROW_NOTE_NULLIFIER_TAG, note_id, secret);
}
