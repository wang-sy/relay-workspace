import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { isDeepStrictEqual } from "node:util";
import { ApiError, behavior, project, type Entry, type Item, type Write } from "./domain.js";
import { ItemContexts } from "./context-store.js";
import { HostedFunctions } from "./functions.js";
import { iso, nextDue } from "./function-contract.js";
import { baseKinds, builtInTriggers, operations, type TypeRecord } from "./vocabulary.js";

export class JournalStore {
  private readonly db: DatabaseSync;
  readonly functions: HostedFunctions;
  readonly contexts: ItemContexts;

  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL");
    this.db.exec(
      "CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, time TEXT NOT NULL, request TEXT NOT NULL);" +
      "CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, value TEXT NOT NULL);" +
      "CREATE TABLE IF NOT EXISTS type_definitions (family TEXT NOT NULL, id TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(family,id))"
    );
    this.contexts = new ItemContexts(this.db, { item:id=>this.item(id), event:id=>this.event(id),
      transaction:(write,body)=>this.transaction(write,body) });
    this.functions = new HostedFunctions(this.db, {
      transaction: body => this.transaction(true, body), item: id => this.item(id), event: id => this.event(id),
      definition: id => this.definition("trigger", id),
      append: (write, time) => this.insert(write, time, "append"),
    });
  }

  close() { this.db.close(); }

  private transaction<T>(write: boolean, body: () => T): T {
    this.db.exec(write ? "BEGIN IMMEDIATE" : "BEGIN");
    try {
      const result = body();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  private toEntry(seq: number, time: string, write: Write): Entry {
    const { requestID, ...rest } = write;
    return { version: 1, id: requestID, sequence: seq, time, ...rest };
  }

  private event(id: string): Entry | undefined {
    const row = this.db.prepare("SELECT seq, time, request FROM events WHERE id = ?").get(id);
    if (row) return this.toEntry(Number(row.seq), String(row.time), JSON.parse(String(row.request)));
  }

  private item(id: string): Item | undefined {
    const row = this.db.prepare("SELECT value FROM items WHERE id = ?").get(id);
    if (row) return JSON.parse(String(row.value));
  }

  private definition(family: string, id: string): TypeRecord | undefined {
    const row = this.db.prepare("SELECT value FROM type_definitions WHERE family=? AND id=?").get(family, id);
    if (row) return JSON.parse(String(row.value));
  }

  private define(c: Write["change"], time: string) {
    const d = c.definition, id = c.itemID;
    if (!d || c.expectedRevision === undefined ||
        Object.keys(c).some(k => !["operation", "itemID", "definition", "expectedRevision"].includes(k))) {
      throw new ApiError(422, "defineType needs only itemID, definition and expectedRevision");
    }
    const old = this.definition(d.family, id);
    if (c.expectedRevision !== (old?.revision ?? 0)) throw new ApiError(409, "Read the current type revision first");
    if (d.family === "event" && id === "defineType") throw new ApiError(422, "defineType is reserved for declarations");
    if (d.family === "item") {
      if (baseKinds.some(k => k === id) && d.base && d.base !== id) throw new ApiError(422, "A built-in item base is fixed");
      if ((old?.base ?? id) !== (d.base ?? id) && this.db.prepare(
        "SELECT 1 FROM events WHERE json_extract(request,'$.change.kind')=? AND json_extract(request,'$.change.operation')='create' LIMIT 1"
      ).get(id)) throw new ApiError(409, "This item type is in use with a different base");
    }
    if (d.family === "trigger") {
      if (builtInTriggers.includes(id)) throw new ApiError(422, "This trigger name is reserved");
      nextDue(d.source!, Date.parse(time));
    }
    const record: TypeRecord = { ...d, id, revision: c.expectedRevision + 1 };
    this.db.prepare("INSERT INTO type_definitions(family,id,value) VALUES(?,?,?) ON CONFLICT(family,id) DO UPDATE SET value=excluded.value")
      .run(d.family, id, JSON.stringify(record));
  }

  private insert(write: Write, time: string, mode: "append" | "import") {
    const row = this.db.prepare("SELECT seq, time, request FROM events WHERE id = ?").get(write.requestID);
    if (row) {
      if (!isDeepStrictEqual(write, JSON.parse(String(row.request)))) {
        throw new ApiError(409, "This request ID is bound to a different write");
      }
      return { entry: this.toEntry(Number(row.seq), String(row.time), write), created: false };
    }
    if (write.change.operation === "defineType") {
      this.define(write.change, time);
    } else {
      const item = project(write, id => this.item(id), id => this.event(id), (family, id) => this.definition(family, id));
      if (mode !== "import" && behavior(item) === "requirement" && write.change.operation === "close" && !write.change.note?.trim()) {
        throw new ApiError(422, "请写清楚这个需求完成了什么");
      }
      this.db.prepare("INSERT INTO items(id, value) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET value = excluded.value")
        .run(item.id, JSON.stringify(item));
    }
    const result = this.db.prepare("INSERT INTO events(id, time, request) VALUES (?, ?, ?)")
      .run(write.requestID, time, JSON.stringify(write));
    const entry = this.toEntry(Number(result.lastInsertRowid), time, write);
    return { entry, created: true };
  }

  append(write: Write, now = Date.now()) {
    return this.transaction(true, () => {
      const result = this.insert(write, iso(now), "append");
      if (result.created && write.change.operation !== "defineType") this.functions.onEvent(result.entry, now);
      return result;
    });
  }

  import(entries: Entry[]) {
    return this.transaction(true, () => {
      if (this.db.prepare("SELECT 1 FROM events LIMIT 1").get()) {
        throw new ApiError(409, "Import needs an empty database");
      }
      for (const entry of entries) {
        const { id, time, version: _version, sequence: _sequence, ...fields } = entry;
        this.insert({ requestID: id, ...fields }, time, "import");
      }
      return entries.length;
    });
  }

  snapshot(viewer: string | null, previousTag?: string, openTypes = true) {
    return this.transaction(false, () => {
      const last = this.db.prepare("SELECT seq, id FROM events ORDER BY seq DESC LIMIT 1").get();
      const digest = createHash("sha256").update(JSON.stringify([last?.seq, last?.id, viewer, openTypes])).digest("hex");
      const etag = '"' + digest + '"';
      if (previousTag === etag) return { etag, body: null };
      const items: Record<string, Item> = Object.fromEntries(this.db.prepare("SELECT id, value FROM items").all()
        .map(row => [String(row.id), JSON.parse(String(row.value))]));
      const entries = this.db.prepare("SELECT seq, time, request FROM events ORDER BY seq").all()
        .map(row => this.toEntry(Number(row.seq), String(row.time), JSON.parse(String(row.request))));
      if (!openTypes) {
        for (const item of Object.values(items)) {
          const base = behavior(item)!;
          if (baseKinds.some(k => k === base)) item.kind = base;
          else delete items[item.id];
        }
        const compatible = entries.filter(e => e.change.operation !== "defineType" && Object.hasOwn(items, e.change.itemID));
        for (const { change } of compatible) {
          if (!operations.includes(change.operation)) change.operation = "update";
          if (change.kind && !baseKinds.some(k => k === change.kind)) {
            change.kind = this.definition("item", change.kind)?.base ?? items[change.itemID]!.kind;
          }
        }
        return { etag, body: { viewer, workspace: { entries: compatible, items, conflicts: [] } } };
      }
      const definitions = Object.fromEntries(this.db.prepare("SELECT family,id,value FROM type_definitions").all()
        .map(row => {
          const { id, revision, ...definition } = JSON.parse(String(row.value)) as TypeRecord;
          return [row.family + ":" + row.id, { id, revision, definition }];
        }));
      return { etag, body: { viewer, workspace: { entries, items, definitions, conflicts: [] } } };
    });
  }
}
