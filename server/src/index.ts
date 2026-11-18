import { resolve } from "node:path";
import { memberKeys, relayServer } from "./http.js";
import { JournalStore } from "./store.js";

const host = process.env.RELAY_HOST ?? "127.0.0.1";
const port = Number(process.env.RELAY_PORT ?? 8731);
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("Invalid RELAY_PORT");
const keys = memberKeys(process.env.RELAY_MEMBERS_JSON);
const store = new JournalStore(resolve(process.env.RELAY_DB ?? "data/relay.sqlite"));
const server = relayServer(store, host, keys);
if (process.env.RELAY_LOG_REQUESTS === "1") {
  server.prependListener("request", (req, res) => {
    const route = req.url?.split("?")[0];
    if (route === "/v1/workspace" || route === "/v1/events") {
      res.once("finish", () => console.log(req.method, route, res.statusCode));
    }
  });
}
server.listen(port, host, () => {
  const address = server.address();
  if (address && typeof address !== "string") {
    console.log("Relay listening on http://" + (host.includes(":") ? "[" + host + "]" : host) + ":" + address.port);
  }
});
function stop() { server.close(() => store.close()); }
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
