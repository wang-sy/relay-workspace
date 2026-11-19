import type { DatabaseSync } from "node:sqlite";
import { ApiError, type Entry, type Item } from "./domain.js";
import { iso } from "./function-contract.js";
import {
  digest,
  prepareMaterial,
  slots,
  type Attachment,
  type Citation,
  type Material,
} from "./context-contract.js";
import { findContexts } from "./context-search.js";

type WorkspaceAccess = {
  item(id: string): Item | undefined;
  event(id: string): Entry | undefined;
  transaction<T>(write: boolean, body: () => T): T;
};
const pageSize = 24;
type Row = Record<string, unknown>;
function citation(row: Row): Citation {
  return JSON.parse(String(row.record));
}
function material(row: Row): Material {
  return JSON.parse(String(row.metadata));
}
const joined = ` FROM context_refs r JOIN context_versions v ON v.material_id=r.material_id AND v.rev=r.rev
  JOIN context_materials m ON m.id=r.material_id `;
function summary(row: Row) {
  const { body: _body, ...metadata } = material(row);
  return { ...citation(row), material: metadata, latestRevision: Number(row.latest) };
}

export class ItemContexts {
  constructor(
    private db: DatabaseSync,
    private work: WorkspaceAccess,
  ) {
    db.exec(`
      CREATE TABLE IF NOT EXISTS context_materials(id TEXT PRIMARY KEY, identity TEXT NOT NULL UNIQUE, latest INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS context_versions(material_id TEXT NOT NULL, rev INTEGER NOT NULL, metadata TEXT NOT NULL,
        PRIMARY KEY(material_id,rev));
      CREATE TABLE IF NOT EXISTS context_blobs(digest TEXT PRIMARY KEY, bytes BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS context_refs(seq INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, item_id TEXT NOT NULL,
        event_id TEXT, event_head INTEGER NOT NULL, time TEXT NOT NULL, material_id TEXT NOT NULL, rev INTEGER NOT NULL, slot TEXT,
        record TEXT NOT NULL, signature TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS context_ref_item ON context_refs(item_id,seq);
      CREATE INDEX IF NOT EXISTS context_ref_source ON context_refs(material_id,rev,seq);
      CREATE INDEX IF NOT EXISTS context_ref_event ON context_refs(item_id,event_id,seq);
      CREATE INDEX IF NOT EXISTS context_ref_highlight ON context_refs(item_id,slot,seq);
      CREATE INDEX IF NOT EXISTS context_events_item ON events(json_extract(request,'$.change.itemID'),seq);
    `);
  }

  attach(input: Attachment, now = Date.now()) {
    const prepared = input.material && prepareMaterial(input.material);
    const anchor = input.anchor ?? prepared?.anchor;
    const signature = digest(JSON.stringify({ ...input, material: prepared?.value, anchor }));
    return this.work.transaction(true, () => {
      const old = this.db.prepare("SELECT record,signature FROM context_refs WHERE id=?").get(input.requestID);
      if (old) {
        if (old.signature !== signature) throw new ApiError(409, "此请求 ID 已用于其他引用");
        return { created: false, reference: citation(old) };
      }
      this.requireItem(input.itemID);
      if (input.eventID) {
        const e = this.work.event(input.eventID);
        if (!e || e.change.operation === "defineType" || e.change.itemID !== input.itemID)
          throw new ApiError(422, "请选择属于此事项的工作记录");
      }
      const existing = input.materialID
        ? this.db.prepare("SELECT * FROM context_materials WHERE id=?").get(input.materialID)
        : prepared && this.db.prepare("SELECT * FROM context_materials WHERE identity=?").get(prepared.identity);
      const id = String(existing?.id ?? input.materialID ?? input.requestID);
      const latest = Number(existing?.latest ?? 0);
      let rev = input.revision ?? latest;
      if (prepared) {
        const previous = existing && this.version(id, latest);
        const metadata = JSON.stringify(prepared.value);
        if (input.expectedRevision !== undefined && input.expectedRevision !== latest)
          throw new ApiError(409, "材料已有更新，请读取最新版本后再提交");
        if (!previous || JSON.stringify(previous) !== metadata) {
          if (previous && (!input.materialID || input.expectedRevision !== latest))
            throw new ApiError(
              409,
              "同一材料已登记。引用已有版本或用 materialID 和 expectedRevision 发布新版。材料 ID 为 " + id,
            );
          if (
            previous &&
            (previous.kind !== prepared.value.kind ||
              (previous.kind === "link" && previous.url !== prepared.value.url))
          )
            throw new ApiError(422, "新版须沿用原材料类型和原文地址");
          if (!existing) {
            if (
              this.db
                .prepare("SELECT id FROM context_materials WHERE identity=? OR id=?")
                .get(prepared.identity, id)
            )
              throw new ApiError(409, "材料已登记，请引用已有材料 ID");
            this.db.prepare("INSERT INTO context_materials VALUES(?,?,1)").run(id, prepared.identity);
          } else this.db.prepare("UPDATE context_materials SET latest=? WHERE id=?").run(latest + 1, id);
          rev = latest + 1;
          if (prepared.blob)
            this.db
              .prepare("INSERT OR IGNORE INTO context_blobs VALUES(?,?)")
              .run(prepared.value.digest!, prepared.blob);
          this.db.prepare("INSERT INTO context_versions VALUES(?,?,?)").run(id, rev, metadata);
        }
      } else if (!existing || !this.version(id, rev)) throw new ApiError(404, "找不到此材料版本");
      const reference: Citation = {
        id: input.requestID,
        itemID: input.itemID,
        eventID: input.eventID,
        time: iso(now),
        actor: input.actor,
        source: input.source,
        session: input.session,
        materialID: id,
        revision: rev,
        purpose: input.purpose,
        note: input.note,
        slot: input.slot,
        locator: input.locator,
        anchor,
      };
      this.db
        .prepare(
          `INSERT INTO context_refs(id,item_id,event_id,time,material_id,rev,slot,record,signature,event_head)
        VALUES(?,?,?,?,?,?,?,?,?,(SELECT coalesce(max(seq),0) FROM events))`,
        )
        .run(
          reference.id,
          reference.itemID,
          reference.eventID ?? null,
          reference.time,
          id,
          rev,
          reference.slot ?? null,
          JSON.stringify(reference),
          signature,
        );
      return { created: true, reference };
    });
  }

  private requireItem(id: string) {
    const item = this.work.item(id);
    if (!item) throw new ApiError(404, "事项不存在");
    return item;
  }
  private version(id: string, rev: number) {
    const row = this.db
      .prepare("SELECT metadata FROM context_versions WHERE material_id=? AND rev=?")
      .get(id, rev);
    return row && material(row);
  }
  get(id: string) {
    const row = this.db.prepare("SELECT r.record,v.metadata,m.latest" + joined + "WHERE r.id=?").get(id);
    if (!row) throw new ApiError(404, "资料引用不存在");
    const ref = summary(row);
    const latest =
      ref.latestRevision > ref.revision &&
      this.db
        .prepare("SELECT id FROM context_refs WHERE material_id=? AND rev=? ORDER BY seq LIMIT 1")
        .get(ref.materialID, ref.latestRevision);
    return { ...ref, material: material(row), latestReferenceID: latest ? String(latest.id) : undefined };
  }
  bytes(id: string) {
    const { material } = this.get(id);
    if (!material.digest) throw new ApiError(404, "此材料没有上传文件");
    const row = this.db.prepare("SELECT bytes FROM context_blobs WHERE digest=?").get(material.digest);
    if (!row) throw new ApiError(500, "附件内容缺失");
    return { data: Buffer.from(row.bytes as Uint8Array), filename: material.filename! };
  }
  private refs(id: string, before?: number, eventID?: string) {
    const rows = this.db
      .prepare(
        "SELECT r.seq,r.record,json_remove(v.metadata,'$.body') AS metadata,m.latest" +
          joined +
          "WHERE r.item_id=? AND r.seq<? " +
          (eventID ? "AND r.event_id=? " : "") +
          "ORDER BY r.seq DESC LIMIT ?",
      )
      .all(id, before ?? Number.MAX_SAFE_INTEGER, ...(eventID ? [eventID] : []), pageSize + 1);
    const results = rows.slice(0, pageSize);
    return { items: results.map(summary), next: rows.length > pageSize ? String(results.at(-1)!.seq) : null };
  }
  references(id: string, before?: number, eventID?: string) {
    this.requireItem(id);
    return this.refs(id, before, eventID);
  }

  history(id: string, since?: string, before?: string) {
    this.requireItem(id);
    const rows = this.db
      .prepare(
        `SELECT * FROM (
      SELECT time || '|e|' || printf('%016d',seq) AS cursor, 'event' AS kind, time, id, request AS data
        FROM events WHERE json_extract(request,'$.change.itemID')=? AND json_extract(request,'$.change.operation')!='defineType' AND time>=?
      UNION ALL SELECT time || '|r|' || printf('%016d',seq), 'reference', time, id, record
        FROM context_refs WHERE item_id=? AND time>=?
    ) WHERE cursor<? ORDER BY cursor DESC LIMIT ?`,
      )
      .all(id, since ?? "", id, since ?? "", before ?? "~", pageSize + 1);
    const results = rows.slice(0, pageSize);
    const items = results.map((row) => {
      const common = { id: String(row.id), kind: String(row.kind), time: String(row.time) };
      if (row.kind === "reference") {
        const ref: Citation = JSON.parse(String(row.data));
        return {
          ...common,
          actor: ref.actor,
          source: ref.source,
          title: ref.purpose,
          text: ref.note,
          referenceID: ref.id,
          eventID: ref.eventID,
        };
      }
      const e: Entry = JSON.parse(String(row.data));
      return {
        ...common,
        actor: e.actor,
        source: e.source,
        title: e.change.operation,
        text: e.change.note ?? e.change.next ?? e.change.title,
        eventID: String(row.id),
      };
    });
    return { items, next: rows.length > pageSize ? String(results.at(-1)!.cursor) : null };
  }

  recall(id: string, since?: string) {
    return this.work.transaction(false, () => {
      const item = this.requireItem(id);
      const highlights = slots.map((slot) => {
        const row = this.db
          .prepare(
            "SELECT r.event_head,r.record,json_remove(v.metadata,'$.body') AS metadata,m.latest" +
              joined +
              "WHERE r.item_id=? AND r.slot=? ORDER BY r.seq DESC LIMIT 1",
          )
          .get(id, slot);
        if (slot === "next") {
          const e = this.db
            .prepare(
              `SELECT seq,id,time,request FROM events WHERE json_extract(request,'$.change.itemID')=?
            AND (json_type(request,'$.change.next') IS NOT NULL OR json_extract(request,'$.change.operation')='close')
            ORDER BY seq DESC LIMIT 1`,
            )
            .get(id);
          if (e && (item.closed || !row || Number(e.seq) > Number(row.event_head))) {
            const change = JSON.parse(String(e.request)).change;
            if (item.closed || change.next !== undefined) {
              const text = item.closed ? "已完成" : item.next || null;
              return { slot, text, time: e.time, eventID: e.id, sourceTitle: "工作记录" };
            }
          }
        }
        if (row) {
          const ref = summary(row);
          return {
            slot,
            text: ref.note,
            time: ref.time,
            referenceID: ref.id,
            eventID: ref.eventID,
            sourceTitle: ref.material.title,
          };
        }
        return { slot, text: null };
      });
      const total = this.db.prepare("SELECT count(*) AS n FROM context_refs WHERE item_id=?").get(id)!.n;
      return {
        item,
        highlights,
        referenceCount: Number(total),
        references: this.refs(id),
        timeline: this.history(id, since),
      };
    });
  }
  search(query: string) {
    return findContexts(this.db, query);
  }
}
