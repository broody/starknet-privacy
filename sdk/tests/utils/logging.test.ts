import { afterEach, describe, expect, it, vi } from "vitest";
import { consoleLogCallback, debugLog, withLogging } from "../../src/utils/logging.js";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("private data in SDK logs", () => {
  it.each(["debugLog", "consoleLogCallback"])(
    "redacts structured and opaque data in %s",
    (logger) => {
      vi.stubEnv("SDK_DEBUG", "compiler");
      const output = vi.spyOn(console, "log").mockImplementation(() => {});
      const secret = "private-log-sentinel";
      const data = {
        controller: 0xabcn,
        notes: [{ spendKey: secret }, { spend_key: secret }],
        computeAdditionalData: [secret],
        compute_additional_data: [secret],
        privateAuxiliaryData: { arbitrary: secret },
        private_auxiliary_data: [secret],
        invocation: { calldata: [secret] },
        // A standalone invocation must also hide its positional witness.
        request: { type: "INVOKE", sender_address: "0xabc", calldata: [secret] },
        keyed: new Map([
          ["spendKey", secret],
          ["controller", "0xabc"],
        ]),
        nested: new Set([{ spend_key: secret }]),
        custom: { spendKey: secret, toJSON: () => secret },
      };
      if (logger === "debugLog") {
        debugLog("compiler", "compile", data);
      } else {
        consoleLogCallback("compiler", "compile", [data], undefined, "ENTER", "1");
        consoleLogCallback("compiler", "compile", [], data, "EXIT", "1");
      }
      const logs = output.mock.calls.flat().join("\n");
      expect(logs).not.toContain(secret);
      expect(logs).toContain("[REDACTED]");
      expect(logs).toContain("0xabc");
      expect(data.notes[0].spendKey).toBe(secret);
      expect(data.computeAdditionalData).toEqual([secret]);
      expect(data.keyed.get("spendKey")).toBe(secret);
    }
  );

  it("gives custom log callbacks sanitized copies without changing method inputs or results", async () => {
    vi.stubEnv("SDK_DEBUG", "compiler");
    const secret = "private-callback-sentinel";
    const request = { spendKey: secret, calldata: [secret], controller: "0xabc" };
    const callback = vi.fn();
    const submit = vi.fn(async (input: typeof request) => input);
    const wrapped = withLogging({ submit }, "compiler", callback);

    expect(await wrapped.submit(request)).toBe(request);
    expect(submit).toHaveBeenCalledWith(request);
    expect(callback).toHaveBeenCalledTimes(2);
    expect(JSON.stringify(callback.mock.calls)).not.toContain(secret);
    expect(JSON.stringify(callback.mock.calls)).toContain("0xabc");
    expect(request.spendKey).toBe(secret);

    const rejected = withLogging(
      {
        async reject() {
          throw secret;
        },
      },
      "compiler",
      callback
    );
    await expect(rejected.reject()).rejects.toBe(secret);
    expect(JSON.stringify(callback.mock.calls)).not.toContain(secret);
  });

  it("omits error details while rethrowing the original sync and async errors", async () => {
    vi.stubEnv("SDK_DEBUG", "compiler");
    const output = vi.spyOn(console, "log").mockImplementation(() => {});
    const error = new Error("request contained private-error-sentinel");
    const wrapped = withLogging(
      {
        fail() {
          throw error;
        },
        async reject() {
          throw error;
        },
      },
      "compiler",
      consoleLogCallback
    );

    expect(() => wrapped.fail()).toThrow(error);
    await expect(wrapped.reject()).rejects.toBe(error);
    consoleLogCallback("compiler", "direct", [], error, "ERROR", "1");
    debugLog("compiler", "error", error);
    expect(output.mock.calls.flat().join("\n")).not.toContain("private-error-sentinel");
    expect(output.mock.calls.flat().join("\n")).toContain("[REDACTED]");
  });

  it("preserves public diagnostics, handles cycles, and leaves disabled lazy logs unevaluated", () => {
    vi.stubEnv("SDK_DEBUG", "compiler");
    const output = vi.spyOn(console, "log").mockImplementation(() => {});
    const data = { controller: 0xabcn, notes: new Map([[1n, new Set([2n])]]), self: {} };
    data.self = data;
    debugLog("compiler", "compile", "actions", data);
    const logs = output.mock.calls.flat().join("\n");
    expect(logs).toContain("actions");
    expect(logs).toContain("0xabc");
    expect(logs).toContain("0x2");
    expect(logs).toContain("[Circular]");

    const lazy = vi.fn(() => data);
    vi.stubEnv("SDK_DEBUG", "");
    debugLog("compiler", "compile", lazy);
    expect(lazy).not.toHaveBeenCalled();
    expect(output).toHaveBeenCalledOnce();
  });
});
