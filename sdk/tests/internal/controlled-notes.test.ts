import { describe, expect, it } from "vitest";
import type { ClientAction } from "../../src/internal/client-actions.js";
import type { StarknetAddress } from "../../src/interfaces.js";
import type { MockContract } from "../../src/testing/contracts.js";
import { bigintReviver } from "../../src/testing/mock-proof-invocation-factory.js";
import { shortStringToFelt, toBigInt } from "../../src/utils/index.js";
import {
  compute_controlled_note_commitment,
  compute_controlled_note_id,
  compute_controlled_note_nullifier,
  compute_identity_key,
} from "../../src/utils/hashes.js";
import { createTestEnv } from "../helpers/test-fixtures.js";

const CONTROLLER = "0xabc";
const OTHER_CONTROLLER = "0xdef";
const AUTHORIZATION = [0xa11n, 0xb22n];

type ControlledTransition = {
  controlled_inputs: Record<string, unknown>[];
  controlled_outputs: Record<string, unknown>[];
  deposits: Record<string, unknown>[];
  private_inputs: Record<string, unknown>[];
  private_outputs: Record<string, unknown>[];
  open_outputs: Record<string, unknown>[];
  withdrawals: Record<string, unknown>[];
};

type ValidationContext = {
  protocol_version: bigint;
  chain_id: bigint;
  pool_address: bigint;
  executor: bigint;
  transition: ControlledTransition;
};

type ApplyContext = {
  protocol_version: bigint;
  actions_hash: bigint;
  serialized_actions: string[];
};

class MockControlledController implements MockContract {
  [key: string]: unknown;
  validationCalls: { context: ValidationContext; calldata: bigint[] }[] = [];
  computedValidationCalls: {
    context: ValidationContext;
    identityKey: bigint;
    calldata: bigint[];
  }[] = [];
  applyCalls: { context: ApplyContext; authorization: bigint[]; calldata: bigint[] }[] = [];

  constructor(public address: StarknetAddress) {}

  privacy_validate_controlled_transition(context: ValidationContext, calldata: bigint[]): bigint[] {
    this.validationCalls.push({ context, calldata });
    return AUTHORIZATION;
  }

  privacy_validate_controlled_transition_with_computation(
    context: ValidationContext,
    identityKey: bigint,
    calldata: bigint[]
  ): bigint[] {
    this.computedValidationCalls.push({ context, identityKey, calldata });
    return AUTHORIZATION;
  }

  privacy_apply_controlled_transition(
    context: ApplyContext,
    authorization: bigint[],
    calldata: bigint[]
  ) {
    this.applyCalls.push({ context, authorization, calldata });
    return { open_note_deposits: [], associated_addresses: [] };
  }
}

function clientActions(calldata: unknown): ClientAction[] {
  return JSON.parse((calldata as string[])[2], bigintReviver) as ClientAction[];
}

describe("controlled note builder", () => {
  it("executes the private controlled-note lifecycle through validation and apply callbacks", async () => {
    const { env, mocknet, transfers } = createTestEnv();
    const token = toBigInt(env.ace);
    const controller = toBigInt(CONTROLLER);
    const policyCommitment = 91n;
    const spendKey = 123n;
    const amount = 37n;
    const noteId = compute_controlled_note_id(
      env.alice.address,
      controller,
      policyCommitment,
      token,
      spendKey
    );
    const app = new MockControlledController(CONTROLLER);
    env.contracts.register(app);

    const creation = await transfers.alice
      .build()
      .with(token)
      .deposit({ amount })
      .createControlledNote({ controller, policyCommitment, amount, spendKey })
      .done()
      .invoke(({ controlledNotes }) => {
        expect(controlledNotes).toEqual([{ noteId, token, controller, policyCommitment }]);
        return { contractAddress: controller, calldata: [7n] };
      })
      .execute();

    const creationActions = creation.callAndProof.call.calldata as string[];
    expect(creationActions.indexOf("EmitControlledNoteCreated")).toBe(
      creationActions.indexOf("WriteOnce") + 1
    );
    expect(app.validationCalls).toHaveLength(1);
    expect(app.applyCalls).toHaveLength(0);
    expect(app.validationCalls[0]).toMatchObject({
      calldata: [7n],
      context: {
        protocol_version: shortStringToFelt("CONTROLLED_NOTE_PROTOCOL_V1"),
        pool_address: env.pool.address,
        executor: env.alice.address,
        transition: {
          deposits: [{ depositor: env.alice.address, token, amount }],
          controlled_outputs: [
            {
              note_id: noteId,
              policy_commitment: policyCommitment,
              token,
              amount,
              spend_key: spendKey,
            },
          ],
        },
      },
    });

    mocknet.executeOutside(creation);
    expect(app.applyCalls).toHaveLength(1);
    expect(app.applyCalls[0]).toMatchObject({ authorization: AUTHORIZATION, calldata: [7n] });
    expect(app.applyCalls[0].context.serialized_actions).toContain("ControlledInvoke");
    expect(env.pool.get_controlled_note(noteId)).toEqual({
      note_commitment: compute_controlled_note_commitment(
        noteId,
        controller,
        policyCommitment,
        token,
        amount,
        spendKey
      ),
      controller,
    });

    const spend = () =>
      transfers.alice
        .build()
        .with(token)
        .useControlledNote({ noteId, policyCommitment, amount, spendKey, controller })
        .withdraw({ amount })
        .done()
        .invoke(() => ({ contractAddress: controller, calldata: [8n] }));

    const spending = await spend().execute();
    expect(app.validationCalls[1].context.transition).toMatchObject({
      controlled_inputs: [
        {
          note_id: noteId,
          policy_commitment: policyCommitment,
          token,
          amount,
          spend_key: spendKey,
        },
      ],
      withdrawals: [{ recipient: env.alice.address, token, amount }],
    });
    mocknet.executeOutside(spending);

    expect(env.pool.nullifier_exists(compute_controlled_note_nullifier(noteId, spendKey))).toBe(
      true
    );
    expect(env.contracts.get(token).balanceOf(env.alice.address)).toBe(1000n);
    expect(app.validationCalls).toHaveLength(2);
    expect(app.applyCalls).toHaveLength(2);
    await expect(spend().execute()).rejects.toThrow(/Nullifier .* already exists/);
  });

  it("compiles private openings and exposes only output identifiers to the invoke builder", async () => {
    const { env, transfers } = createTestEnv();
    const token = toBigInt(env.ace);
    const expectedNoteId = compute_controlled_note_id(
      env.alice.address,
      toBigInt(CONTROLLER),
      91n,
      token,
      123n
    );

    const result = await transfers.alice
      .build()
      .with(token)
      .deposit({ amount: 37n })
      .createControlledNote({
        controller: CONTROLLER,
        policyCommitment: 91n,
        amount: 37n,
        spendKey: 123n,
      })
      .done()
      .invoke(({ controlledNotes }) => {
        expect(controlledNotes).toEqual([
          { noteId: expectedNoteId, token, controller: 0xabcn, policyCommitment: 91n },
        ]);
        return { contractAddress: CONTROLLER, calldata: [expectedNoteId] };
      })
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata)).toEqual([
      { type: "Deposit", input: { token, amount: 37n } },
      {
        type: "CreateControlledNote",
        input: {
          controller: 0xabcn,
          policy_commitment: 91n,
          token,
          amount: 37n,
          spend_key: 123n,
        },
      },
      { type: "InvokeExternal", input: { contract_address: 0xabcn, calldata: [expectedNoteId] } },
    ]);
  });

  it("uses the dedicated validation-with-computation path for VDF-style release", async () => {
    const { env, mocknet, transfers } = createTestEnv();
    const token = toBigInt(env.ace);
    const controller = toBigInt(CONTROLLER);
    const app = new MockControlledController(CONTROLLER);
    env.contracts.register(app);

    const result = await transfers.alice
      .build()
      .with(token)
      .deposit({ amount: 5n })
      .createControlledNote({ controller, policyCommitment: 91n, amount: 5n, spendKey: 123n })
      .done()
      .computeAndInvoke(() => ({
        contractAddress: controller,
        computeAdditionalData: [11n, 12n],
        invokeAdditionalData: [13n],
      }))
      .execute();

    expect(app.validationCalls).toHaveLength(0);
    expect(app.computedValidationCalls).toEqual([
      {
        context: expect.objectContaining({ executor: env.alice.address }),
        identityKey: compute_identity_key(env.alice.address, env.alice.privateKey, controller),
        calldata: [11n, 12n],
      },
    ]);
    mocknet.executeOutside(result);
    expect(app.applyCalls[0]).toMatchObject({ authorization: AUTHORIZATION, calldata: [13n] });
  });

  it("compiles a spend before outputs and the controller invoke", async () => {
    const { env, transfers } = createTestEnv();

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .useControlledNote({
        noteId: 123n,
        policyCommitment: 91n,
        amount: 37n,
        spendKey: 456n,
        controller: CONTROLLER,
      })
      .withdraw({ recipient: env.alice.address, amount: 37n })
      .done()
      .invoke(() => ({ contractAddress: CONTROLLER, calldata: [] }))
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata).map((action) => action.type)).toEqual([
      "UseControlledNote",
      "Withdraw",
      "InvokeExternal",
    ]);
  });

  it("requires one controller and a matching invoke-phase target", async () => {
    const { env, transfers } = createTestEnv();
    const mixedControllers = transfers.alice
      .build()
      .with(env.ace)
      .useControlledNote({
        noteId: 123n,
        policyCommitment: 91n,
        amount: 18n,
        spendKey: 456n,
        controller: CONTROLLER,
      })
      .useControlledNote({
        noteId: 789n,
        policyCommitment: 92n,
        amount: 19n,
        spendKey: 101n,
        controller: OTHER_CONTROLLER,
      })
      .withdraw({ recipient: env.alice.address, amount: 37n })
      .done()
      .invoke(() => ({ contractAddress: CONTROLLER, calldata: [] }));
    await expect(mixedControllers.createProofInvocation()).rejects.toThrow(
      "A transaction may target only one controlled-note controller"
    );

    const withoutInvoke = transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createControlledNote({
        controller: CONTROLLER,
        policyCommitment: 91n,
        amount: 37n,
        spendKey: 123n,
      });
    await expect(withoutInvoke.createProofInvocation()).rejects.toThrow(
      "Controlled-note creation and spend require .invoke() or .computeAndInvoke()"
    );

    const wrongTarget = withoutInvoke
      .done()
      .invoke(() => ({ contractAddress: OTHER_CONTROLLER, calldata: [] }));
    await expect(wrongTarget.createProofInvocation()).rejects.toThrow(
      "The invoke target must match the controlled-note controller"
    );
  });
});
