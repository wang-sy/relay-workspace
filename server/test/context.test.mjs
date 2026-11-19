import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { JournalStore } from "../dist/store.js";
import { attachment } from "../dist/context-contract.js";
import { memberKeys, relayServer } from "../dist/http.js";

const time = Date.UTC(2026, 10, 1);
const note = { kind: "note", title: "实地记录", body: "地库中断网后先记录样本。" };
const changes = (store, change, now = time) =>
  store.append({ requestID: randomUUID(), actor: "River", source: "Codex", change }, now).entry;
const request = (fields) =>
  attachment.parse({ requestID: randomUUID(), actor: "River", source: "Codex", itemID: "idea", ...fields });

test("context citations are pinned, shared across items, atomic on retry and survive promotion and restart", () => {
  const dir = mkdtempSync(join(tmpdir(), "relay-context-")),
    path = join(dir, "db");
  let store = new JournalStore(path);
  try {
    const e = changes(store, { operation: "create", itemID: "idea", kind: "idea", title: "巡检交接" });
    changes(store, { operation: "create", itemID: "direction", kind: "direction", title: "现场" });
    const first = request({ material: note, eventID: e.id, slot: "decision", note: "先保存在设备上。" });
    const receipt = store.contexts.attach(first, time);
    assert.equal(store.contexts.attach(first, time + 1).created, false);
    assert.deepEqual(store.contexts.get(receipt.reference.id).material, note);
    assert.throws(() => store.contexts.attach({ ...first, note: "不同" }), /请求 ID/);
    const { materialID } = receipt.reference;
    assert.throws(
      () => store.contexts.attach(request({ itemID: "direction", eventID: e.id, materialID })),
      /属于此事项/,
    );
    const other = store.contexts.attach(
      request({ itemID: "direction", materialID, purpose: "另一处引用", locator: "第二段" }),
      time,
    );
    assert.equal(other.reference.revision, 1);
    const newer = request({
      materialID,
      expectedRevision: 1,
      material: { ...note, body: "恢复网络后保存回执。" },
    });
    store.contexts.attach(newer, time + 10000);
    assert.equal(store.contexts.get(first.requestID).material.body, note.body);
    assert.equal(store.contexts.get(other.reference.id).latestRevision, 2);
    assert.equal(store.contexts.get(other.reference.id).latestReferenceID, newer.requestID);
    assert.deepEqual(
      store.contexts.references("idea", undefined, e.id).items.map((x) => x.id),
      [first.requestID],
    );
    assert.throws(() => store.contexts.attach({ ...newer, requestID: randomUUID() }), /已有更新/);
    assert.throws(() => store.contexts.attach(request({ materialID, revision: 42 })), /找不到/);
    changes(store, {
      operation: "promote",
      itemID: "idea",
      parentID: "direction",
      start: "2026-11-01T00:00:00Z",
      end: "2026-11-20T00:00:00Z",
    });
    store.close();
    store = new JournalStore(path);
    const report = store.contexts.recall("idea", "2026-11-01T00:00:05Z");
    assert.equal(report.referenceCount, 2);
    assert.equal(report.item.kind, "requirement");
    assert.equal(report.highlights[0].referenceID, first.requestID);
    assert.equal(report.highlights.find((h) => h.slot === "evidence").text, null);
    assert.deepEqual(
      report.timeline.items.map((m) => m.id),
      [newer.requestID],
    );
    assert.deepEqual(
      new Set(store.contexts.search("之前地库断网的样本").map((hit) => hit.itemID)),
      new Set(["idea", "direction"]),
    );
    assert.equal(store.contexts.search("先保存在设备上")[0].itemID, "idea");
  } finally {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("journal updates supersede an old next step and cursors cover every entry sharing a timestamp", () => {
  const store = new JournalStore(":memory:");
  try {
    changes(store, { operation: "create", itemID: "idea", kind: "idea", title: "handoff" });
    const ref = store.contexts.attach(request({ material: note, slot: "next", note: "旧步骤" }), time).reference;
    const next = changes(store, { operation: "update", itemID: "idea", next: "新步骤" }, time);
    const highlight = store.contexts.recall("idea").highlights.find((h) => h.slot === "next");
    assert.equal(highlight.text, "新步骤");
    assert.equal(highlight.eventID, next.id);
    for (let i = 0; i < 53; i++)
      store.contexts.attach(request({ materialID: ref.materialID, note: "回顾 " + i }), time);
    for (const [list, total] of [
      [(cursor) => store.contexts.history("idea", undefined, cursor), 56],
      [(cursor) => store.contexts.references("idea", cursor && Number(cursor)), 54],
    ]) {
      let cursor;
      const ids = [];
      do {
        const page = list(cursor);
        ids.push(...page.items.map((x) => x.id));
        cursor = page.next;
      } while (cursor);
      assert.equal(ids.length, total);
      assert.equal(new Set(ids).size, total);
    }
    const url = "https://example.feishu.cn/docx/Example";
    const r1 = store.contexts.attach(
      request({ material: { kind: "link", title: "原文", url: url + "#block1", sourceVersion: "3" } }),
    ).reference;
    const r2 = store.contexts.attach(
      request({ material: { kind: "link", title: "原文", url: url + "#block2", sourceVersion: "3" } }),
    ).reference;
    assert.equal(r1.materialID, r2.materialID);
    assert.equal(r2.anchor, "block2");
    assert.throws(() =>
      attachment.parse({
        ...request({ material: note }),
        material: { kind: "link", title: "Doc", url, body: "受限正文" },
      }),
    );
    assert.throws(() =>
      store.contexts.attach(request({ material: { kind: "link", title: "Doc", url: "file:///private" } })),
    );
  } finally {
    store.close();
  }
});

test("viewer reads exact file bytes; invalid uploads, unauthenticated downloads and viewer writes are rejected", async (t) => {
  const db = new JournalStore(":memory:"),
    agent = randomUUID(),
    viewer = randomUUID();
  const server = relayServer(db, "127.0.0.1", memberKeys(JSON.stringify({ Jun: { agent, viewer } })));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    await new Promise((resolve) => server.close(resolve));
    db.close();
  });
  changes(db, { operation: "create", itemID: "idea", kind: "idea", title: "导出" });
  const base = "http://127.0.0.1:" + server.address().port + "/v1/context/";
  const headers = (k) => ({
    Authorization: "Bearer " + k,
    "Content-Type": "application/json",
    "X-Relay-Client": "agent",
  });
  const ref = request({
    material: {
      kind: "file",
      title: "输出",
      filename: "样本.txt",
      mime: "text/plain",
      data: Buffer.from("精确的原始附件").toString("base64"),
    },
  });
  const post = (body, k) =>
    fetch(base + "references", { method: "POST", headers: headers(k), body: JSON.stringify(body) });
  assert.equal((await post(ref, viewer)).status, 403);
  assert.equal((await post({ ...ref, material: { ...ref.material, data: "%%%" } }, agent)).status, 422);
  assert.equal(
    (await post({ ...ref, material: { ...ref.material, filename: "../elsewhere" } }, agent)).status,
    422,
  );
  assert.equal(db.contexts.recall("idea").referenceCount, 0);
  const accepted = await post(ref, agent);
  assert.equal(accepted.status, 201);
  assert.equal((await accepted.json()).actor, "Jun");
  assert.equal((await post(ref, agent)).status, 200);
  const url = base + "references/" + ref.requestID + "/file";
  assert.equal((await fetch(url)).status, 401);
  const file = await fetch(url, { headers: headers(viewer) });
  assert.equal(file.headers.get("content-type"), "application/octet-stream");
  assert.equal(await file.text(), "精确的原始附件");
  assert.equal(
    (await fetch(base + "recall?itemID=idea&since=nonsense", { headers: headers(viewer) })).status,
    422,
  );
  assert.equal((await fetch(base + "history?itemID=idea&before=oops", { headers: headers(viewer) })).status, 422);
});
