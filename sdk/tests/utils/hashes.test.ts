/**
 * Tests for hash function compatibility between TypeScript and Cairo implementations.
 *
 * These tests validate that the TypeScript hash functions produce the same results
 * as the Cairo implementation to ensure cross-language compatibility.
 */

import { describe, it, expect } from "vitest";
import {
  compute_channel_key,
  compute_channel_marker,
  compute_subchannel_id,
  compute_subchannel_marker,
  compute_note_id,
  compute_nullifier,
  compute_enc_amount_hash,
  compute_enc_token_hash,
  compute_enc_private_key_hash,
  compute_enc_channel_key_hash,
  compute_enc_sender_addr_hash,
  compute_enc_recipient_addr_hash,
  compute_outgoing_channel_id,
  compute_predicate_note_id,
  compute_predicate_note_commitment,
  compute_predicate_nullifier,
} from "../../src/utils/hashes.js";
import referenceHashes from "../fixtures/cairo-reference-data.json" with { type: "json" };

describe("Hash Compatibility with Cairo", () => {
  const { inputs, outputs } = referenceHashes;

  // Parse inputs
  const sender = BigInt(inputs.sender);
  const recipient = BigInt(inputs.recipient);
  const senderPrivateKey = BigInt(inputs.senderPrivateKey);
  const recipientPublicKey = BigInt(inputs.recipientPublicKey);
  const channelKey = BigInt(inputs.channelKey);
  const token = BigInt(inputs.token);
  const index = inputs.index;
  const salt = BigInt(inputs.salt);
  const sharedX = BigInt(inputs.sharedX);
  const predicateChainId = BigInt(inputs.predicateChainId);
  const predicatePool = BigInt(inputs.predicatePool);
  const predicateAddress = BigInt(inputs.predicateAddress);
  const predicateClassHash = BigInt(inputs.predicateClassHash);
  const predicateCommitment = BigInt(inputs.predicateCommitment);
  const predicateNonce = BigInt(inputs.predicateNonce);
  const predicateBlinding = BigInt(inputs.predicateBlinding);

  it("compute_channel_key matches Cairo", () => {
    const result = compute_channel_key(sender, senderPrivateKey, recipient, recipientPublicKey);
    expect(result.toString(16)).toBe(BigInt(outputs.channelKey).toString(16));
  });

  it("compute_channel_marker matches Cairo", () => {
    const result = compute_channel_marker(channelKey, sender, recipient, recipientPublicKey);
    expect(result.toString(16)).toBe(BigInt(outputs.channelMarker).toString(16));
  });

  it("compute_subchannel_id matches Cairo", () => {
    const result = compute_subchannel_id(channelKey, index);
    expect(result.toString(16)).toBe(BigInt(outputs.subchannelId).toString(16));
  });

  it("compute_subchannel_marker matches Cairo", () => {
    const result = compute_subchannel_marker(channelKey, recipient, recipientPublicKey, token);
    expect(result.toString(16)).toBe(BigInt(outputs.subchannelMarker).toString(16));
  });

  it("compute_note_id matches Cairo", () => {
    const result = compute_note_id(channelKey, token, index);
    expect(result.toString(16)).toBe(BigInt(outputs.noteId).toString(16));
  });

  it("compute_nullifier matches Cairo", () => {
    const result = compute_nullifier(channelKey, token, index, senderPrivateKey);
    expect(result.toString(16)).toBe(BigInt(outputs.nullifier).toString(16));
  });

  it("compute_enc_amount_hash matches Cairo", () => {
    const result = compute_enc_amount_hash(channelKey, token, index, salt);
    expect(result.toString(16)).toBe(BigInt(outputs.encAmountHash).toString(16));
  });

  it("compute_enc_token_hash matches Cairo", () => {
    const result = compute_enc_token_hash(channelKey, index, salt);
    expect(result.toString(16)).toBe(BigInt(outputs.encTokenHash).toString(16));
  });

  it("compute_enc_private_key_hash matches Cairo", () => {
    const result = compute_enc_private_key_hash(sharedX);
    expect(result.toString(16)).toBe(BigInt(outputs.encPrivateKeyHash).toString(16));
  });

  it("compute_enc_channel_key_hash matches Cairo", () => {
    const result = compute_enc_channel_key_hash(sharedX);
    expect(result.toString(16)).toBe(BigInt(outputs.encChannelKeyHash).toString(16));
  });

  it("compute_enc_sender_addr_hash matches Cairo", () => {
    const result = compute_enc_sender_addr_hash(sharedX);
    expect(result.toString(16)).toBe(BigInt(outputs.encSenderAddrHash).toString(16));
  });

  it("compute_enc_recipient_addr_hash matches Cairo", () => {
    const result = compute_enc_recipient_addr_hash(sender, senderPrivateKey, index, salt);
    expect(result.toString(16)).toBe(BigInt(outputs.encRecipientAddrHash).toString(16));
  });

  it("compute_outgoing_channel_id matches Cairo", () => {
    const result = compute_outgoing_channel_id(sender, senderPrivateKey, index);
    expect(result.toString(16)).toBe(BigInt(outputs.outgoingChannelId).toString(16));
  });

  it("predicate note hashes match Cairo", () => {
    const predicateNoteId = compute_predicate_note_id(
      predicateChainId,
      predicatePool,
      sender,
      predicateAddress,
      predicateClassHash,
      predicateCommitment,
      token,
      predicateNonce
    );
    expect(predicateNoteId.toString(16)).toBe(BigInt(outputs.predicateNoteId).toString(16));

    const noteCommitment = compute_predicate_note_commitment(
      predicateChainId,
      predicatePool,
      predicateNoteId,
      predicateAddress,
      predicateClassHash,
      predicateCommitment,
      token,
      BigInt(inputs.amount),
      predicateBlinding
    );
    expect(noteCommitment.toString(16)).toBe(BigInt(outputs.predicateNoteCommitment).toString(16));
    expect(
      compute_predicate_nullifier(
        predicateChainId,
        predicatePool,
        predicateNoteId,
        predicateBlinding
      ).toString(16)
    ).toBe(BigInt(outputs.predicateNullifier).toString(16));
  });
});
