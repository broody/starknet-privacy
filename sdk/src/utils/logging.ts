// ============ Logging Utilities ============
import { toHex } from "./convert.js";

// --- Environment Access (Browser-Compatible) ---

/** Safely get environment variable (works in both Node.js and browser) */
const getEnv = (key: string): string | undefined => {
  if (typeof process !== "undefined" && process.env) {
    return process.env[key];
  }
  return undefined;
};

// --- Tracing Context ---

type TraceContext = {
  id: string; // e.g. "1.2"
  childCounter: number; // Counter for children
};

// Try to use AsyncLocalStorage if available (Node.js only)
// In browsers, we fall back to simple counter-based trace IDs
type AsyncLocalStorageType = import("async_hooks").AsyncLocalStorage<TraceContext>;
let traceStorage: AsyncLocalStorageType | undefined;

try {
  // Only attempt to load in Node.js environment
  if (typeof window === "undefined" && typeof process !== "undefined") {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const asyncHooks = require("async_hooks");
    traceStorage = new asyncHooks.AsyncLocalStorage();
  }
} catch {
  // async_hooks not available (browser or unsupported environment)
  traceStorage = undefined;
}

let rootTraceCounter = 0;

function getTraceId(): string {
  if (traceStorage) {
    const current = traceStorage.getStore();
    if (current) {
      current.childCounter++;
      return `${current.id}.${current.childCounter}`;
    }
  }
  rootTraceCounter++;
  return `${rootTraceCounter}`;
}

// --- Types ---

export type LogPhase = "ENTER" | "EXIT" | "ERROR";

/** Callback type for logging method calls. `withLogging` supplies sanitized log snapshots. */
export type LogCallback = (
  targetName: string,
  methodName: string,
  args: unknown[],
  result: unknown, // result or error
  phase: LogPhase,
  traceId: string
) => void;

/**
 * Wraps an object to intercept all method calls and invoke a callback.
 * Useful for debugging/logging.
 *
 * @param target - The object to wrap
 * @param name - Name to identify this object in logs
 * @param callback - Function called for each method invocation (with result after execution)
 */
export function withLogging<T extends object>(target: T, name: string, callback: LogCallback): T {
  // Skip proxy overhead if debug is not enabled for this target
  if (!isDebugEnabledForTarget(name)) {
    return target;
  }
  return new Proxy(target, {
    get(obj, prop, receiver) {
      const value = Reflect.get(obj, prop, receiver);
      if (typeof value === "function" && typeof prop === "string" && !prop.startsWith("_")) {
        return function (this: unknown, ...args: unknown[]) {
          const traceId = getTraceId();
          const context: TraceContext = { id: traceId, childCounter: 0 };
          const log = (result: unknown, phase: LogPhase) =>
            callback(
              name,
              prop,
              sanitizeLogValue(args) as unknown[],
              phase === "ERROR" ? REDACTED : sanitizeLogValue(result),
              phase,
              traceId
            );

          const executeWithLogging = () => {
            try {
              // Log Enter
              log(undefined, "ENTER");

              // Apply on 'this' (which is the proxy if called via proxy) to ensure internal calls
              // also go through the proxy.
              const result = value.apply(this, args);

              // Handle promises - log result when resolved
              if (result instanceof Promise) {
                return result.then(
                  (resolved) => {
                    log(resolved, "EXIT");
                    return resolved;
                  },
                  (error) => {
                    log(error, "ERROR");
                    throw error;
                  }
                );
              }

              log(result, "EXIT");
              return result;
            } catch (error) {
              log(error, "ERROR");
              throw error;
            }
          };

          // Use AsyncLocalStorage if available (Node.js), otherwise just execute
          if (traceStorage) {
            return traceStorage.run(context, executeWithLogging);
          }
          return executeWithLogging();
        };
      }
      return value;
    },
  });
}

/** Environment variable to enable debug logging */
export const DEBUG_ENV_VAR = "SDK_DEBUG";

/** Check if debug logging is enabled */
export const isDebugEnabled = (targetName?: string) => {
  const env = getEnv(DEBUG_ENV_VAR);
  if (!env) return false;
  if (env === "1" || env === "true") return true;
  if (targetName) {
    const patterns = env.split(",");
    // Check for exact match or prefix match (pattern + ".")
    // e.g. "foo" matches "foo" and "foo.bar"
    return patterns.some((p) => targetName === p || targetName.startsWith(`${p}.`));
  }
  return false;
};

/** Check if debug logging could be enabled for any method of a target */
const isDebugEnabledForTarget = (name: string) => {
  const env = getEnv(DEBUG_ENV_VAR);
  if (!env) return false;
  if (env === "1" || env === "true") return true;
  const patterns = env.split(",");
  // Check if any pattern matches this target or is a prefix of target methods
  // e.g. "foo" or "foo.bar" patterns would enable logging for target "foo"
  return patterns.some((p) => p === name || p.startsWith(`${name}.`) || name.startsWith(`${p}.`));
};

// ANSI color codes
const CYAN = 36;
const GREEN = 32;
const RED = 31;

// Check if we are in a TTY environment or if color is forced
const useColor = () => {
  if (getEnv("SDK_DEBUG_COLOR") === "0" || getEnv("NO_COLOR")) return false;
  if (getEnv("SDK_DEBUG_COLOR") === "1" || getEnv("FORCE_COLOR")) return true;
  // Check if stdout exists and is TTY (Node.js only)
  if (typeof process !== "undefined" && process.stdout?.isTTY) return true;
  return false;
};

/** Apply color if environment supports it */
const color = (text: string, code: number) => {
  if (!useColor()) return text;
  return `\u001b[${code}m${text}\u001b[0m`;
};

// ... existing code ...

/** Get current timestamp as HH:MM:SS.mmm */
const getTimestamp = () => {
  const now = new Date();
  const hours = now.getHours().toString().padStart(2, "0");
  const minutes = now.getMinutes().toString().padStart(2, "0");
  const seconds = now.getSeconds().toString().padStart(2, "0");
  const ms = now.getMilliseconds().toString().padStart(3, "0");
  return `${hours}:${minutes}:${seconds}.${ms}`;
};

const REDACTED = "[REDACTED]";
// Match both SDK camelCase and Cairo snake_case fields. Opaque calldata can contain a
// positional witness or serialized JSON, so redact it before inspecting its contents.
const PRIVATE_LOG_FIELDS = new Set([
  "spendkey",
  "privatekey",
  "viewingkey",
  "userprivatekey",
  "userviewingkey",
  "signer",
  "computeadditionaldata",
  "privateauxiliarydata",
  "privatedata",
  "computationdata",
  "calldata",
  "executeviewcalldata",
  "executecalldata",
  "compiledcalldata",
  "invocation",
  "proofinvocation",
]);

/** Build a log-only copy, without invoking custom toJSON methods or mutating the witness. */
function sanitizeLogValue(value: unknown, key = "", seen = new WeakSet<object>()): unknown {
  if (PRIVATE_LOG_FIELDS.has(key.replace(/_/g, "").toLowerCase())) return REDACTED;
  // Error messages, stacks, and causes may echo entire private requests.
  if (value instanceof Error) return REDACTED;
  if (typeof value === "bigint") return toHex(value);
  if (typeof value === "function") return "[Function]";
  if (value instanceof Uint8Array) return toHex(value);
  if (typeof value !== "object" || value === null) return value;
  if (seen.has(value)) return "[Circular]";
  seen.add(value);
  if (Array.isArray(value)) return value.map((item) => sanitizeLogValue(item, "", seen));
  if (value instanceof Map) {
    return {
      dataType: "Map",
      value: Array.from(value, ([entryKey, item]) => [
        sanitizeLogValue(entryKey, "", seen),
        sanitizeLogValue(item, typeof entryKey === "string" ? entryKey : "", seen),
      ]),
    };
  }
  if (value instanceof Set) return Array.from(value, (item) => sanitizeLogValue(item, "", seen));
  return Object.fromEntries(
    Object.entries(value).map(([field, item]) => [field, sanitizeLogValue(item, field, seen)])
  );
}

/**
 * Console logging callback for use with withLogging.
 * Logs method calls to console in format: [TraceID] [TargetName.method] -> (args)
 * Only logs when SDK_DEBUG environment variable is set.
 */
export const consoleLogCallback: LogCallback = (
  targetName,
  methodName,
  args,
  result,
  phase,
  traceId
) => {
  // Check if debug is enabled for the specific method path
  if (!isDebugEnabled(`${targetName}.${methodName}`)) return;

  const format = (value: unknown): string => {
    return JSON.stringify(sanitizeLogValue(value));
  };

  const timestamp = color(`[${getTimestamp()}]`, 90); // Gray color for timestamp
  const prefix = color(`[${traceId}] [${targetName}.${methodName}]`, CYAN);

  if (phase === "ENTER") {
    const argsStr = args.map(format).join(", ");
    console.log(`${timestamp} ${prefix} ${color("→", GREEN)} (${argsStr})`);
  } else if (phase === "EXIT") {
    console.log(`${timestamp} ${prefix} ${color("←", GREEN)} ${format(result)}`);
  } else if (phase === "ERROR") {
    console.log(`${timestamp} ${prefix} ${color("✖", RED)} ${REDACTED}`);
  }
};

/**
 * Log arbitrary messages if debug is enabled for the target.
 * Function arguments are lazily evaluated - they're only called if debug is enabled.
 * This allows passing expensive computations like: debugLog("x", "y", "msg", () => expensiveCall())
 */
export const debugLog = (target: string, sub: string, ...args: unknown[]) => {
  if (isDebugEnabled(`${target}.${sub}`)) {
    // Attempt to get current trace ID if inside a logged context
    const current = traceStorage?.getStore();
    const traceId = current ? current.id : "?";

    const timestamp = color(`[${getTimestamp()}]`, 90); // Gray color for timestamp

    // Evaluate function arguments lazily (only now that we know debug is enabled)
    const evaluatedArgs = args.map((arg) => (typeof arg === "function" ? arg() : arg));

    console.log(
      timestamp,
      color(`[${traceId}] [${target}.${sub}]`, CYAN),
      ...evaluatedArgs.map((arg) =>
        typeof arg === "string" ? arg : JSON.stringify(sanitizeLogValue(arg), undefined, 2)
      )
    );
  }
};

/** No-op logging callback - does nothing */
export const noopLogCallback: LogCallback = () => {};

/** Helper message to show when tests fail */
export const debugHint = `\nTip: Run with ${DEBUG_ENV_VAR}=1 for detailed logging`;
