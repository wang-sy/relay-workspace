import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { entrySchema, type Entry } from "./domain.js";
import { JournalStore } from "./store.js";

const dir = process.argv[2];
if (!dir) throw new Error("Pass the path to a fully downloaded RelayEvents folder");
const entries = new Map<string, Entry>();
for (const name of readdirSync(dir)) {
  if (name.endsWith(".json.icloud")) throw new Error("Download the entire journal before importing");
  if (!name.endsWith(".json")) continue;
  const raw = JSON.parse(readFileSync(join(dir, name), "utf8"));
  const batch = name === "Starter.json" ? entrySchema.array().parse(raw) : [entrySchema.parse(raw)];
  for (const entry of batch) {
    const old = entries.get(entry.id);
    if (old && !isDeepStrictEqual(old, entry)) throw new Error("Conflicting copies of event " + entry.id);
    entries.set(entry.id, entry);
  }
}
const ordered = [...entries.values()].sort((a, b) => a.sequence - b.sequence || a.id.localeCompare(b.id));
const store = new JournalStore(resolve(process.env.RELAY_DB ?? "data/relay.sqlite"));
try { console.log("Imported " + store.import(ordered) + " events."); }
finally { store.close(); }
