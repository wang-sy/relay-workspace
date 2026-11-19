import { randomUUID } from "node:crypto";
import type { DatabaseSync, SQLOutputValue } from "node:sqlite";
import { isDeepStrictEqual } from "node:util";
import { ApiError, type Entry, type Item, type Write } from "./domain.js";
import { iso, nextDue, type Definition, type FunctionContext } from "./function-contract.js";
import { runCode } from "./function-runtime.js";

type Row = Record<string, SQLOutputValue>;
type Journal = {
  transaction<T>(body: () => T): T;
  event(id: string): Entry | undefined;
  item(id: string): Item | undefined;
  append(write: Write, time: string): void;
};
type Attempt = { id: string; token: string; code: string; context: FunctionContext; snapshot: string | number;
  itemID: string | null; attempts: number };
const maxAttempts = 3;
const inputLimit = 256 * 1024;
const definitionOf = (row: Row): Definition => JSON.parse(String(row.definition));

export class HostedFunctions {
  constructor(private db: DatabaseSync, private journal: Journal) {
    db.exec(`
      CREATE TABLE IF NOT EXISTS hosted_functions (
        id TEXT PRIMARY KEY, revision INTEGER NOT NULL, definition TEXT NOT NULL,
        actor TEXT NOT NULL, updated_by TEXT NOT NULL, updated_at INTEGER NOT NULL, enabled INTEGER NOT NULL,
        operation TEXT, target TEXT, delay_seconds INTEGER NOT NULL, next_due INTEGER
      );
      CREATE INDEX IF NOT EXISTS functions_on_event ON hosted_functions(operation, enabled, target);
      CREATE INDEX IF NOT EXISTS functions_on_timer ON hosted_functions(next_due) WHERE next_due IS NOT NULL;
      CREATE TABLE IF NOT EXISTS function_runs (
        id TEXT PRIMARY KEY, function_id TEXT NOT NULL, revision INTEGER NOT NULL,
        event_id TEXT, item_id TEXT, scheduled_at INTEGER NOT NULL, state TEXT NOT NULL,
        available_at INTEGER NOT NULL, token TEXT, attempts INTEGER NOT NULL DEFAULT 0,
        finished_at INTEGER, error TEXT, writes INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS runs_due ON function_runs(available_at)
        WHERE state IN ('queued','running');
      CREATE INDEX IF NOT EXISTS runs_history ON function_runs(function_id, scheduled_at DESC);
      CREATE INDEX IF NOT EXISTS runs_pending_by_function ON function_runs(function_id, scheduled_at)
        WHERE state IN ('queued','running');
    `);
  }

  private row(id: string) {
    return this.db.prepare("SELECT * FROM hosted_functions WHERE id = ?").get(id);
  }

  private summary(row: Row) {
    const { name, trigger, enabled } = definitionOf(row);
    const pending = this.db.prepare("SELECT MIN(scheduled_at) AS due FROM function_runs WHERE function_id=? AND state IN ('queued','running')").get(row.id!);
    const dates = [row.next_due, pending?.due].filter((v): v is number => typeof v === "number");
    return { id: String(row.id), revision: Number(row.revision), name, trigger, enabled,
      actor: String(row.actor), updatedBy: String(row.updated_by), updatedAt: iso(Number(row.updated_at)), nextAt: dates.length ? iso(Math.min(...dates)) : null };
  }

  list() {
    return this.db.prepare("SELECT * FROM hosted_functions ORDER BY enabled DESC, json_extract(definition, '$.name') COLLATE NOCASE, id")
      .all().map(row => this.summary(row));
  }

  get(id: string) {
    const row = this.row(id);
    if (!row) throw new ApiError(404, "Hosted function not found");
    const runs = this.db.prepare("SELECT * FROM function_runs WHERE function_id=? ORDER BY scheduled_at DESC, rowid DESC LIMIT 30")
      .all(id).map(r => ({
        id: String(r.id), revision: Number(r.revision), itemID: r.item_id, eventID: r.event_id,
        scheduledAt: iso(Number(r.scheduled_at)), finishedAt: r.finished_at === null ? null : iso(Number(r.finished_at)),
        status: String(r.state), writes: Number(r.writes), attempts: Number(r.attempts), error: r.error,
      }));
    return { ...this.summary(row), code: definitionOf(row).code, runs };
  }

  deploy(id: string, expected: number, definition: Definition, actor: string, now = Date.now()) {
    return this.journal.transaction(() => this.save(id, expected, definition, actor, actor, now));
  }

  setEnabled(id: string, expected: number, enabled: boolean, actor: string, now = Date.now()) {
    return this.journal.transaction(() => {
      const old = this.row(id);
      if (!old) throw new ApiError(404, "Hosted function not found");
      return this.save(id, expected, { ...definitionOf(old), enabled }, String(old.actor), actor, now);
    });
  }

  private save(id: string, expected: number, definition: Definition, actor: string, changedBy: string, now: number) {
    const old = this.row(id);
    const revision = Number(old?.revision ?? 0);
    const same = !!old && isDeepStrictEqual(definition, definitionOf(old));
    if (revision !== expected) {
      if (revision === expected + 1 && same && old?.updated_by === changedBy) return this.get(id);
      throw new ApiError(409, "Function revision changed. Read the current definition first.");
    }
    if (same) return this.get(id);
    const next = nextDue(definition.trigger, now);
    if (definition.enabled && !old?.enabled) {
      const count = this.db.prepare("SELECT COUNT(*) AS n FROM hosted_functions WHERE enabled=1").get();
      if (Number(count?.n) >= 128) throw new ApiError(409, "This workspace already has 128 enabled functions");
    }
    const trigger = definition.trigger;
    this.db.prepare(`INSERT INTO hosted_functions(id, revision, definition, actor, updated_by, updated_at, enabled, operation, target, delay_seconds, next_due)
      VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
      revision=excluded.revision, definition=excluded.definition, actor=excluded.actor, updated_by=excluded.updated_by, updated_at=excluded.updated_at,
      enabled=excluded.enabled, operation=excluded.operation, target=excluded.target,
      delay_seconds=excluded.delay_seconds, next_due=excluded.next_due`)
      .run(id, revision + 1, JSON.stringify(definition), actor, changedBy, now, Number(definition.enabled),
        trigger.kind === "event" ? trigger.operation : null, trigger.itemID ?? null,
        trigger.kind === "event" ? trigger.delaySeconds : 0, definition.enabled ? next : null);
    this.db.prepare("UPDATE function_runs SET state='cancelled', finished_at=?, token=NULL WHERE function_id=? AND state IN ('queued','running')").run(now, id);
    return this.get(id);
  }

  // Called inside the event's own commit. Imported history and function outputs are never fan-out sources.
  onEvent(event: Entry, now: number) {
    const rows = this.db.prepare("SELECT id, revision, delay_seconds FROM hosted_functions WHERE enabled=1 AND operation=? AND (target IS NULL OR target=?)")
      .all(event.change.operation, event.change.itemID);
    for (const row of rows) {
      this.enqueue(row, event.id, event.change.itemID, now + Number(row.delay_seconds) * 1000);
    }
  }

  private enqueue(row: Row, eventID: string | null, itemID: string | null, due: number) {
    const id = String(row.id) + "/" + row.revision + "/" + (eventID ?? due);
    this.db.prepare(`INSERT INTO function_runs(id,function_id,revision,event_id,item_id,scheduled_at,state,available_at)
      VALUES(?,?,?,?,?,?,'queued',?) ON CONFLICT(id) DO NOTHING`)
      .run(id, row.id!, row.revision!, eventID, itemID, due, due);
  }

  private snapshotKey(itemID: string | null) {
    if (itemID !== null) return String(this.db.prepare("SELECT value FROM items WHERE id=?").get(itemID)?.value ?? "");
    return Number(this.db.prepare("SELECT MAX(seq) AS seq FROM events").get()?.seq ?? 0);
  }

  private currentItems(): Item[] {
    let bytes = 0;
    const items: Item[] = [];
    for (const row of this.db.prepare("SELECT value FROM items ORDER BY id").iterate()) {
      const value = String(row.value);
      bytes += Buffer.byteLength(value) + 1;
      if (bytes > inputLimit) throw new ApiError(422, "Workspace input exceeds 256 KiB. Scope the trigger to an item.");
      items.push(JSON.parse(value));
    }
    return items;
  }

  private claim(now: number): Attempt | undefined {
    return this.journal.transaction(() => {
      const timers = this.db.prepare("SELECT * FROM hosted_functions WHERE enabled=1 AND next_due<=? ORDER BY next_due LIMIT 16").all(now);
      for (const row of timers) {
        const { trigger } = definitionOf(row);
        this.enqueue(row, null, trigger.itemID ?? null, Number(row.next_due));
        // Coalesce missed cron ticks to one durable invocation after downtime.
        const next = trigger.kind === "cron" ? nextDue(trigger, now) : null;
        this.db.prepare("UPDATE hosted_functions SET next_due=? WHERE id=?").run(next, row.id!);
      }
      const run = this.db.prepare(`SELECT r.*, f.actor, f.definition FROM function_runs r
        JOIN hosted_functions f ON f.id=r.function_id AND f.revision=r.revision AND f.enabled=1
        WHERE r.state IN ('queued','running') AND r.available_at<=? ORDER BY r.available_at,r.rowid LIMIT 1`).get(now);
      if (!run) return;
      const id = String(run.id);
      const attempts = Number(run.attempts) + 1;
      try {
        if (attempts > maxAttempts) throw new ApiError(422, "Execution lease expired after the final attempt");
        const itemID = run.item_id === null ? null : String(run.item_id);
        const context: FunctionContext = {
          functionID: String(run.function_id), revision: Number(run.revision), actor: String(run.actor),
          now: iso(now), scheduledAt: iso(Number(run.scheduled_at)),
          item: itemID === null ? null : this.journal.item(itemID) ?? null,
          event: run.event_id === null ? null : this.journal.event(String(run.event_id)) ?? null,
          ...(itemID === null ? { items: this.currentItems() } : {}),
        };
        if (Buffer.byteLength(JSON.stringify(context)) > inputLimit) throw new ApiError(422, "Function input exceeds 256 KiB");
        const token = randomUUID();
        this.db.prepare("UPDATE function_runs SET state='running', token=?, attempts=?, available_at=?, error=NULL WHERE id=?")
          .run(token, attempts, now + 15000, id);
        return { id, token, attempts, context, itemID, code: definitionOf(run).code, snapshot: this.snapshotKey(itemID) };
      } catch (error) {
        if (!(error instanceof ApiError)) throw error;
        this.db.prepare("UPDATE function_runs SET state='failed', error=?, finished_at=?, token=NULL WHERE id=?").run(error.message, now, id);
      }
    });
  }

  private reject(attempt: Attempt, message: string, retry: boolean, now: number) {
    const again = retry && attempt.attempts < maxAttempts;
    this.db.prepare(`UPDATE function_runs SET state=?, error=?, finished_at=?, token=NULL, available_at=?
      WHERE id=? AND state='running' AND token=?`).run(again ? "queued" : "failed", message.slice(0, 300),
        again ? null : now, now + attempt.attempts * 2000, attempt.id, attempt.token);
  }

  async tick(clock: () => number = Date.now, execute = runCode) {
    const attempt = this.claim(clock());
    if (!attempt) return false;
    try {
      const changes = await execute(attempt.code, attempt.context);
      this.journal.transaction(() => {
        const now = clock();
        const owns = this.db.prepare("SELECT 1 FROM function_runs WHERE id=? AND state='running' AND token=?")
          .get(attempt.id, attempt.token);
        if (!owns) return;
        if (this.snapshotKey(attempt.itemID) !== attempt.snapshot) {
          this.reject(attempt, "Workspace changed during execution", true, now);
          return;
        }
        for (const change of changes) {
          this.journal.append({ requestID: randomUUID(), actor: attempt.context.actor,
            source: "Relay Function / " + attempt.context.functionID, session: attempt.id, change }, iso(now));
        }
        this.db.prepare("UPDATE function_runs SET state=?, writes=?, finished_at=?, token=NULL WHERE id=?")
          .run(changes.length ? "succeeded" : "skipped", changes.length, now, attempt.id);
      });
    } catch (error) {
      const rejection = error instanceof ApiError;
      this.journal.transaction(() => this.reject(attempt, rejection ? error.message : "Execution temporarily unavailable", !rejection, clock()));
    }
    return true;
  }
}
