import { describe, expect, it } from "vitest";
import type { ClientAction } from "../../src/internal/client-actions.js";
import { bigintReviver } from "../../src/testing/mock-proof-invocation-factory.js";
import { toBigInt } from "../../src/utils/index.js";
import { createTestEnv } from "../helpers/test-fixtures.js";

const PREDICATE = "0xabc";
const OTHER_PREDICATE = "0xdef";

function clientActions(calldata: unknown): ClientAction[] {
  return JSON.parse((calldata as string[])[2], bigintReviver) as ClientAction[];
}

describe("predicate note builder", () => {
  it("compiles creation with explicit private openings and an atomic predicate invoke", async () => {
    const { env, transfers } = createTestEnv();

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createPredicateNote({
        predicateAddress: PREDICATE,
        predicateCommitment: 91n,
        amount: 37n,
        nonce: 123n,
        blinding: 456n,
      })
      .done()
      .invoke(() => ({ contractAddress: PREDICATE, calldata: [7n] }))
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata)).toEqual([
      { type: "Deposit", input: { token: toBigInt(env.ace), amount: 37n } },
      {
        type: "CreatePredicateNote",
        input: {
          predicate_address: 0xabcn,
          predicate_commitment: 91n,
          token: toBigInt(env.ace),
          amount: 37n,
          nonce: 123n,
          blinding: 456n,
        },
      },
      {
        type: "InvokeExternal",
        input: { contract_address: 0xabcn, calldata: [7n] },
      },
    ]);
  });

  it("compiles a predicate spend before outputs and the predicate invoke", async () => {
    const { env, transfers } = createTestEnv();

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .usePredicateNote({ noteId: 123n, amount: 37n, blinding: 456n })
      .withdraw({ recipient: env.alice.address, amount: 37n })
      .done()
      .invoke(() => ({ contractAddress: PREDICATE, calldata: [] }))
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata).map((action) => action.type)).toEqual([
      "UsePredicateNote",
      "Withdraw",
      "InvokeExternal",
    ]);
  });

  it("fails fast without an invoke or when a creation targets a different predicate", async () => {
    const { env, transfers } = createTestEnv();
    const withoutInvoke = transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createPredicateNote({
        predicateAddress: PREDICATE,
        predicateCommitment: 91n,
        amount: 37n,
        nonce: 123n,
        blinding: 456n,
      });

    await expect(withoutInvoke.createProofInvocation()).rejects.toThrow(
      "Predicate-note creation and spend require .invoke() or .computeAndInvoke()"
    );

    const wrongTarget = transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createPredicateNote({
        predicateAddress: PREDICATE,
        predicateCommitment: 91n,
        amount: 37n,
        nonce: 123n,
        blinding: 456n,
      })
      .done()
      .invoke(() => ({ contractAddress: OTHER_PREDICATE, calldata: [] }));

    await expect(wrongTarget.createProofInvocation()).rejects.toThrow(
      "The invoke target must match the predicate controlling created notes"
    );
  });
});
