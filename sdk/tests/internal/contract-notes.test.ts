import { describe, expect, it } from "vitest";
import type { ClientAction } from "../../src/internal/client-actions.js";
import { bigintReviver } from "../../src/testing/mock-proof-invocation-factory.js";
import { toBigInt } from "../../src/utils/index.js";
import { createTestEnv } from "../helpers/test-fixtures.js";

const CONTROLLER = "0xabc";
const OTHER_CONTROLLER = "0xdef";

function clientActions(calldata: unknown): ClientAction[] {
  return JSON.parse((calldata as string[])[2], bigintReviver) as ClientAction[];
}

describe("contract note builder", () => {
  it("compiles creation with explicit private openings and an atomic controller invoke", async () => {
    const { env, transfers } = createTestEnv();

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createContractNote({
        controllerContract: CONTROLLER,
        controllerCommitment: 91n,
        amount: 37n,
        nonce: 123n,
        blinding: 456n,
      })
      .done()
      .invoke(() => ({ contractAddress: CONTROLLER, calldata: [7n] }))
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata)).toEqual([
      { type: "Deposit", input: { token: toBigInt(env.ace), amount: 37n } },
      {
        type: "CreateContractNote",
        input: {
          controller_contract: 0xabcn,
          controller_commitment: 91n,
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

  it("compiles a controller spend before outputs and the controller invoke", async () => {
    const { env, transfers } = createTestEnv();

    const result = await transfers.alice
      .build()
      .with(env.ace)
      .useContractNote({ noteId: 123n, amount: 37n, blinding: 456n })
      .withdraw({ recipient: env.alice.address, amount: 37n })
      .done()
      .invoke(() => ({ contractAddress: CONTROLLER, calldata: [] }))
      .createProofInvocation();

    expect(clientActions(result.invocation.calldata).map((action) => action.type)).toEqual([
      "UseContractNote",
      "Withdraw",
      "InvokeExternal",
    ]);
  });

  it("fails fast without an invoke or when a creation targets a different controller", async () => {
    const { env, transfers } = createTestEnv();
    const withoutInvoke = transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createContractNote({
        controllerContract: CONTROLLER,
        controllerCommitment: 91n,
        amount: 37n,
        nonce: 123n,
        blinding: 456n,
      });

    await expect(withoutInvoke.createProofInvocation()).rejects.toThrow(
      "Contract-note creation and spend require .invoke() or .computeAndInvoke()"
    );

    const wrongTarget = transfers.alice
      .build()
      .with(env.ace)
      .deposit({ amount: 37n })
      .createContractNote({
        controllerContract: CONTROLLER,
        controllerCommitment: 91n,
        amount: 37n,
        nonce: 123n,
        blinding: 456n,
      })
      .done()
      .invoke(() => ({ contractAddress: OTHER_CONTROLLER, calldata: [] }));

    await expect(wrongTarget.createProofInvocation()).rejects.toThrow(
      "The invoke target must match the controller of created contract notes"
    );
  });
});
