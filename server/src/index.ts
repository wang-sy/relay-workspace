import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { memberKeys, relayServer } from "./http.js";
import { JournalStore } from "./store.js";

const host = process.env.RELAY_HOST ?? "127.0.0.1";
const port = Number(process.env.RELAY_PORT ?? 8731);
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("Invalid RELAY_PORT");
const keys = memberKeys(process.env.RELAY_MEMBERS_JSON);
const store = new JournalStore(resolve(process.env.RELAY_DB ?? "data/relay.sqlite"));
const localAgentToken = keys.size === 0 ? randomBytes(32).toString("hex") : undefined;
const server = relayServer(store, host, keys, localAgentToken);
let stopping = false;
let timer: ReturnType<typeof setTimeout>;
let running: Promise<void> = Promise.resolve();
function poll() {
  if (stopping) return;
  running = store.functions.tick().catch(() => {
    console.error("Relay could not poll hosted functions; pending work will be retried.");
    return false;
  }).then(processed => {
    if (!stopping) timer = setTimeout(poll, processed ? 0 : 1000);
  });
}
if (process.env.RELAY_LOG_REQUESTS === "1") {
  server.prependListener("request", (req, res) => {
    const route = req.url?.split("?")[0];
    if (route === "/v1/workspace" || route === "/v1/events" || route === "/v1/functions" || route === "/v1/context/recall") {
      res.once("finish", () => console.log(req.method, route, res.statusCode));
    }
  });
}
function saveLocalAgentToken(port: number, token: string) {
  const dir = process.env.RELAY_LOCAL_AGENT_DIR || join(homedir(), ".relay", "local-agents");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const pending = join(dir, randomUUID() + ".tmp");
  writeFileSync(pending, token, { mode: 0o600, flag: "wx" });
  try { renameSync(pending, join(dir, port + ".token")); }
  catch (error) { rmSync(pending, { force: true }); throw error; }
}

server.listen(port, host, () => {
  const address = server.address();
  if (address && typeof address !== "string") {
    if (localAgentToken) {
      try { saveLocalAgentToken(address.port, localAgentToken); }
      catch {
        console.error("Could not save the local Agent credential. Check the permissions of RELAY_LOCAL_AGENT_DIR.");
        process.exitCode = 1;
        stop();
        return;
      }
    }
    poll();
    console.log("Relay listening on http://" + (host.includes(":") ? "[" + host + "]" : host) + ":" + address.port);
  }
});
function stop() {
  stopping = true;
  clearTimeout(timer);
  server.close(() => { void running.finally(() => store.close()); });
}
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
