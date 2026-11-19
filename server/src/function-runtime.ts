import { fork } from "node:child_process";
import { ApiError } from "./domain.js";
import { changesSchema, type FunctionContext } from "./function-contract.js";

function evaluate(code: string, context?: FunctionContext): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = fork(new URL("./function-guest.js", import.meta.url), [], {
      stdio: ["ignore", "ignore", "ignore", "ipc"], env: {}, execArgv: ["--max-old-space-size=48"],
    });
    const timer = setTimeout(() => finish(new ApiError(422, "Function exceeded its execution time")), 4000);
    let settled = false;
    function finish(error?: Error, result = "[]") {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill("SIGKILL");
      if (error) reject(error); else resolve(result);
    }
    child.once("error", () => finish(new Error("Function process unavailable")));
    child.once("exit", () => finish(new Error("Function process exited unexpectedly")));
    child.once("message", (message: { ok?: boolean; json?: string; error?: string }) => {
      if (!message?.ok || typeof message.json !== "string") {
        return finish(new ApiError(422, (message?.error ?? "Function failed").slice(0, 300)));
      }
      if (Buffer.byteLength(message.json) > 32768) return finish(new ApiError(422, "Output exceeds 32 KiB"));
      finish(undefined, message.json);
    });
    child.send({ code, context }, error => {
      if (error) finish(new Error("Cannot start function execution"));
    });
  });
}

let compiling = 0;
export async function validateCode(code: string) {
  if (compiling >= 2) throw new ApiError(429, "Another function is being validated. Retry shortly.");
  compiling++;
  try { await evaluate(code); } finally { compiling--; }
}

export async function runCode(code: string, context: FunctionContext) {
  const json = await evaluate(code, context);
  const parsed = changesSchema.safeParse(JSON.parse(json));
  if (!parsed.success) throw new ApiError(422, "Invalid Relay change at " + parsed.error.issues[0]?.path.join("."));
  return parsed.data;
}
