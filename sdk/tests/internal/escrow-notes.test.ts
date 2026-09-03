import { describe, expect, it } from "vitest";
import type { ClientAction } from "../../src/internal/client-actions.js";
import { bigintReviver } from "../../src/testing/mock-proof-invocation-factory.js";
import { toBigInt } from "../../src/utils/index.js";
import {
  compute_escrow_note_commitment,
  compute_escrow_note_id,
  compute_escrow_note_nullifier,
  compute_open_escrow_note_id,
} from "../../src/utils/hashes.js";
import { createTestEnv } from "../helpers/test-fixtures.js";

const CONTROLLER = "0xabc";
const OTHER_CONTROLLER = "0xdef";

function clientActions(calldata: unknown): ClientAction[] {
  return JSON.parse((calldata as string[])[2], bigintReviver) as ClientAction[];
}

describe("escrow note builder", () => {
  it("executes the private escrow-note lifecycle through the mock pool", async () => {
    const { env, mocknet, transfers } = createTestEnv();
    const token = toBigInt(env.ace);
    const controller = toBigInt(CONTROLLER);
    const policyCommitment = 91n;
    const secret = 123n;
    const noteId = compute_escrow_note_id(
      env.alice.address,
      controller,
      policyCommitment,
      token,
      secret
    );
    let callbackCount = 0;
    env.contracts.register({
      address: CONTROLLER,
      privacy_escrow_invoke: () => {
        callbackCount++;
        return { open_escrow_note_deposits: [] };
      },
    });

    const creation = await transfers.alice
      .build()
      .with(token)
      .deposit({ amount: 37n })
      .createEscrowNote({
        contractAddress: controller,
        policyCommitment,
        amount: 37n,
        secret,
      })
      .done()
      .invoke(() => ({ contractAddress: controller, calldata: [7n] }))
      .execute();
    const creationActions = creation.callAndProof.call.calldata as string[];
    expect(creationActions.indexOf("EmitEscrowNoteCreated")).toBe(
      creationActions.indexOf("WriteOnce") + 1
    );
    mocknet.executeOutside(creation);

    expect(env.pool.get_escrow_note(noteId)).toEqual({
      note_commitment: compute_escrow_note_commitment(
        noteId,
        controller,
        policyCommitment,
        token,
        37n,
        secret
      ),
      contract_address: controller,
      policy_commitment: policyCommitment,
      token,
    });

    const spend = () =>
      transfers.alice
        .build()
        .with(token)
        .useEscrowNote({
          noteId,
          amount: 37n,
          secret,
          contractAddress: controller,
        })
        .withdraw({ amount: 37n })
        .done()
        .invoke(() => ({ contractAddress: controller, calldata: [8n] }));

    const spending = await spend().execute();
    const spendActions = spending.callAndProof.call.calldata as string[];
    expect(spendActions.indexOf("EmitEscrowNoteUsed")).toBe(spendActions.indexOf("WriteOnce") + 1);
    mocknet.executeOutside(spending);

    const nullifier = compute_escrow_note_nullifier(noteId, secret);
    expect(env.pool.nullifier_exists(nullifier)).toBe(true);
    expect(env.contracts.get(token).balanceOf(env.alice.address)).toBe(1000n);
    expect(callbackCount).toBe(2);
    await expect(spend().execute()).rejects.toThrow(/Nullifier .* already exists/);
  });

  it("compiles creation with a private secret and an atomic contract invoke", async () => {
    const { env, transfers } = createTestEnv();

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createEscrowNote({
        contractAddress: CONTROLLER,
        policyCommitment: 91n,
        amount: 37n,
        secret: 123n,
      })
      .done()
      .invoke(() => ({ contractAddress: CONTROLLER, calldata: [7n] }))
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata)).toEqual([
      { type: "Deposit", input: { token: toBigInt(env.ace), amount: 37n } },
      {
        type: "CreateEscrowNote",
        input: {
          contract_address: 0xabcn,
          policy_commitment: 91n,
          token: toBigInt(env.ace),
          amount: 37n,
          secret: 123n,
        },
      },
      {
        type: "InvokeExternal",
        input: { contract_address: 0xabcn, calldata: [7n] },
      },
    ]);
  });

  it("compiles an escrow-note spend before outputs and the contract invoke", async () => {
    const { env, transfers } = createTestEnv();

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .useEscrowNote({
        noteId: 123n,
        amount: 37n,
        secret: 456n,
        contractAddress: CONTROLLER,
      })
      .withdraw({ recipient: env.alice.address, amount: 37n })
      .done()
      .invoke(() => ({ contractAddress: CONTROLLER, calldata: [] }))
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata).map((action) => action.type)).toEqual([
      "UseEscrowNote",
      "Withdraw",
      "InvokeExternal",
    ]);
  });

  it("derives an open escrow note ID for atomic callback funding", async () => {
    const { env, transfers } = createTestEnv();
    const expectedNoteId = compute_open_escrow_note_id(
      toBigInt(env.alice.address),
      0xabcn,
      91n,
      toBigInt(env.ace),
      123n
    );

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .createOpenEscrowNote({
        contractAddress: CONTROLLER,
        policyCommitment: 91n,
        secret: 123n,
      })
      .done()
      .invoke(({ openEscrowNotes }) => {
        expect(openEscrowNotes).toEqual([
          {
            noteId: expectedNoteId,
            token: toBigInt(env.ace),
            contractAddress: 0xabcn,
            policyCommitment: 91n,
          },
        ]);
        return { contractAddress: CONTROLLER, calldata: [expectedNoteId, 37n] };
      })
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata)).toEqual([
      {
        type: "CreateOpenEscrowNote",
        input: {
          contract_address: 0xabcn,
          policy_commitment: 91n,
          token: toBigInt(env.ace),
          secret: 123n,
        },
      },
      {
        type: "InvokeExternal",
        input: { contract_address: 0xabcn, calldata: [expectedNoteId, 37n] },
      },
    ]);
  });

  it("uses an open escrow note as a public-amount private input", async () => {
    const { env, transfers } = createTestEnv();

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .useOpenEscrowNote({
        noteId: 123n,
        amount: 37n,
        secret: 456n,
        contractAddress: CONTROLLER,
      })
      .withdraw({ recipient: env.alice.address, amount: 37n })
      .done()
      .invoke(() => ({ contractAddress: CONTROLLER, calldata: [] }))
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata).map((action) => action.type)).toEqual([
      "UseOpenEscrowNote",
      "Withdraw",
      "InvokeExternal",
    ]);
  });

  it("rejects an invoke target that does not control the spent escrow note", async () => {
    const { env, transfers } = createTestEnv();
    const wrongTarget = transfers.alice
      .build()
      .with(env.ace)
      .useEscrowNote({
        noteId: 123n,
        amount: 37n,
        secret: 456n,
        contractAddress: CONTROLLER,
      })
      .withdraw({ recipient: env.alice.address, amount: 37n })
      .done()
      .invoke(() => ({ contractAddress: OTHER_CONTROLLER, calldata: [] }));

    await expect(wrongTarget.createProofInvocation()).rejects.toThrow(
      "The invoke target must match the contract of escrow notes"
    );
  });

  it("rejects spends controlled by different application contracts", async () => {
    const { env, transfers } = createTestEnv();
    const mixedControllers = transfers.alice
      .build()
      .with(env.ace)
      .useEscrowNote({
        noteId: 123n,
        amount: 18n,
        secret: 456n,
        contractAddress: CONTROLLER,
      })
      .useOpenEscrowNote({
        noteId: 789n,
        amount: 19n,
        secret: 101n,
        contractAddress: OTHER_CONTROLLER,
      })
      .withdraw({ recipient: env.alice.address, amount: 37n })
      .done()
      .invoke(() => ({ contractAddress: CONTROLLER, calldata: [] }));

    await expect(mixedControllers.createProofInvocation()).rejects.toThrow(
      "A transaction may target only one escrow application contract"
    );
  });

  it("applies invoke and target invariants to open escrow notes", async () => {
    const { env, transfers } = createTestEnv();
    const withoutInvoke = transfers.alice.build().with(env.ace).createOpenEscrowNote({
      contractAddress: CONTROLLER,
      policyCommitment: 91n,
      secret: 123n,
    });

    await expect(withoutInvoke.createProofInvocation()).rejects.toThrow(
      "Escrow-note creation and spend require .invoke() or .computeAndInvoke()"
    );

    const wrongTarget = transfers.alice
      .build()
      .with(env.ace)
      .createOpenEscrowNote({
        contractAddress: CONTROLLER,
        policyCommitment: 91n,
        secret: 123n,
      })
      .done()
      .invoke(() => ({ contractAddress: OTHER_CONTROLLER, calldata: [] }));

    await expect(wrongTarget.createProofInvocation()).rejects.toThrow(
      "The invoke target must match the contract of escrow notes"
    );
  });

  it("fails fast without an invoke or when a creation targets a different contract", async () => {
    const { env, transfers } = createTestEnv();
    const withoutInvoke = transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createEscrowNote({
        contractAddress: CONTROLLER,
        policyCommitment: 91n,
        amount: 37n,
        secret: 123n,
      });

    await expect(withoutInvoke.createProofInvocation()).rejects.toThrow(
      "Escrow-note creation and spend require .invoke() or .computeAndInvoke()"
    );

    const wrongTarget = transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createEscrowNote({
        contractAddress: CONTROLLER,
        policyCommitment: 91n,
        amount: 37n,
        secret: 123n,
      })
      .done()
      .invoke(() => ({ contractAddress: OTHER_CONTROLLER, calldata: [] }));

    await expect(wrongTarget.createProofInvocation()).rejects.toThrow(
      "The invoke target must match the contract of escrow notes"
    );
  });
});
