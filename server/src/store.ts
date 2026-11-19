import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { isDeepStrictEqual } from "node:util";
import { ApiError, project, type Entry, type Item, type Write } from "./domain.js";
import { HostedFunctions } from "./functions.js";
import { iso } from "./function-contract.js";

export class JournalStore {
  private readonly db: DatabaseSync;
  readonly functions: HostedFunctions;

  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL");
    this.db.exec(
      "CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, time TEXT NOT NULL, request TEXT NOT NULL);" +
      "CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, value TEXT NOT NULL)"
    );
    this.functions = new HostedFunctions(this.db, {
      transaction: body => this.transaction(true, body), item: id => this.item(id), event: id => this.event(id),
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

  private insert(write: Write, time: string, mode: "append" | "import") {
    const row = this.db.prepare("SELECT seq, time, request FROM events WHERE id = ?").get(write.requestID);
    if (row) {
      if (!isDeepStrictEqual(write, JSON.parse(String(row.request)))) {
        throw new ApiError(409, "This request ID is bound to a different write");
      }
      return { entry: this.toEntry(Number(row.seq), String(row.time), write), created: false };
    }
    const item = project(write, id => this.item(id), id => this.event(id));
    if (mode !== "import" && item.kind === "requirement" && write.change.operation === "close" && !write.change.note?.trim()) {
      throw new ApiError(422, "请写清楚这个需求完成了什么");
    }
    const result = this.db.prepare("INSERT INTO events(id, time, request) VALUES (?, ?, ?)")
      .run(write.requestID, time, JSON.stringify(write));
    this.db.prepare("INSERT INTO items(id, value) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET value = excluded.value")
      .run(item.id, JSON.stringify(item));
    const entry = this.toEntry(Number(result.lastInsertRowid), time, write);
    return { entry, created: true };
  }

  append(write: Write, now = Date.now()) {
    return this.transaction(true, () => {
      const result = this.insert(write, iso(now), "append");
      if (result.created) this.functions.onEvent(result.entry, now);
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

  snapshot(viewer: string | null, previousTag?: string) {
    return this.transaction(false, () => {
      const last = this.db.prepare("SELECT seq, id FROM events ORDER BY seq DESC LIMIT 1").get();
      const digest = createHash("sha256").update(JSON.stringify([last?.seq, last?.id, viewer])).digest("hex");
      const etag = '"' + digest + '"';
      if (previousTag === etag) return { etag, body: null };
      const items = Object.fromEntries(this.db.prepare("SELECT id, value FROM items").all()
        .map(row => [String(row.id), JSON.parse(String(row.value))]));
      const entries = this.db.prepare("SELECT seq, time, request FROM events ORDER BY seq").all()
        .map(row => this.toEntry(Number(row.seq), String(row.time), JSON.parse(String(row.request))));
      return { etag, body: { viewer, workspace: { entries, items, conflicts: [] } } };
    });
  }
}
