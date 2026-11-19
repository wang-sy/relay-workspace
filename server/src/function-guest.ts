// This disposable process only passes JSON to an isolated QuickJS WebAssembly runtime.
import { getQuickJS, shouldInterruptAfterDeadline } from "quickjs-emscripten";
import type { FunctionContext } from "./function-contract.js";

process.once("message", async (input: { code: string; context?: FunctionContext }) => {
  try {
    const vm = await getQuickJS();
    const body = JSON.stringify('"use strict";\n' + input.code);
    const compile = "new Function('ctx'," + body + ")";
    let expression = "void " + compile;
    if (input.context) {
      const context = JSON.stringify(JSON.stringify(input.context));
      expression = "(() => { const value = (" + compile + ")(JSON.parse(" + context + "));" +
        "if (value != null && !Array.isArray(value)) throw new Error('Return an array of Relay changes');" +
        "const json = JSON.stringify(value ?? []);" +
        "if (json.length > 32768) throw new Error('Output exceeds 32 KiB'); return json; })()";
    }
    const value = vm.evalCode(expression, {
      memoryLimitBytes: 8 * 1024 * 1024, maxStackSizeBytes: 256 * 1024,
      shouldInterrupt: shouldInterruptAfterDeadline(Date.now() + 150),
    });
    process.send?.({ ok: true, json: typeof value === "string" ? value : "[]" });
  } catch (error) {
    const message = error instanceof Error ? error.message : "The function failed";
    process.send?.({ ok: false, error: message.slice(0, 300) });
  }
});
