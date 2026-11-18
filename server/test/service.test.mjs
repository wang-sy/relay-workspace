import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { memberKeys, relayServer } from "../dist/http.js";
import { JournalStore } from "../dist/store.js";
import { entrySchema } from "../dist/domain.js";

function write(change) { return { requestID: randomUUID(), actor: "device", source: "test", change }; }

test("HTTP accepts one write on retry, binds the author and preserves it across restart", async t => {
  const dir = mkdtempSync(join(tmpdir(), "relay-test-"));
  const path = join(dir, "relay.sqlite");
  const store = new JournalStore(path);
  const token = randomUUID();
  const server = relayServer(store, "127.0.0.1", memberKeys(JSON.stringify({ "River": token })));
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    await new Promise(resolve => server.close(resolve));
    store.close();
    rmSync(dir, { recursive: true });
  });
  const base = "http://127.0.0.1:" + server.address().port + "/v1/";
  const headers = { Authorization: "Bearer " + token, "Content-Type": "application/json" };
  const post = body => fetch(base + "events", { method: "POST", headers, body: JSON.stringify(body) });
  assert.equal((await fetch(base + "workspace")).status, 401);
  const empty = await fetch(base + "workspace", { headers });
  const emptyTag = empty.headers.get("etag");
  const create = write({ operation: "create", itemID: "idea", kind: "idea", title: "One" });
  const retries = await Promise.all([post(create), post(create)]);
  assert.deepEqual(retries.map(r => r.status).sort(), [200, 201]);
  const [a, b] = await Promise.all(retries.map(r => r.json()));
  assert.deepEqual(a, b);
  assert.equal(a.actor, "River");
  assert.equal(a.sequence, 1);
  assert.equal((await post({ ...create, change: { ...create.change, title: "Different" } })).status, 409);
  assert.equal((await post(write({ operation: "create", itemID: "bad", kind: "task", title: "Orphan" }))).status, 422);
  const result = await fetch(base + "workspace", { headers: { ...headers, "If-None-Match": emptyTag } });
  assert.equal(result.status, 200);
  assert.deepEqual((await result.json()).workspace.entries, [a]);
  assert.equal((await fetch(base + "workspace", { headers: { ...headers, "If-None-Match": result.headers.get("etag") } })).status, 304);
  const reopened = new JournalStore(path);
  try {
    assert.equal(reopened.snapshot("River").body.workspace.items.idea.title, "One");
    assert.equal(reopened.snapshot("River").body.workspace.entries.length, 1);
  } finally { reopened.close(); }
});

test("scheduling, roles and handoff references use the same item and pause", () => {
  const store = new JournalStore(":memory:");
  try {
    const apply = change => store.append(write(change)).entry;
    apply({ operation: "create", kind: "direction", itemID: "d", title: "方向" });
    apply({ operation: "create", kind: "idea", itemID: "r", title: "提案", category: "产品" });
    const dates = { start: "2030-03-01T00:00:00Z", end: "2030-03-08T00:00:00Z" };
    assert.throws(() => apply({ operation: "promote", itemID: "r", parentID: "d" }));
    apply({ operation: "promote", itemID: "r", parentID: "d", ...dates, status: "自由状态" });
    apply({ operation: "create", kind: "task", itemID: "t", parentID: "r", title: "任务", members: [{ name: "Jun", role: "开发" }] });
    apply({ operation: "update", itemID: "t", members: [{ name: "Jun", role: "验收" }] });
    const milestone = apply({ operation: "milestone", itemID: "r", due: dates.end, note: "节点" });
    assert.throws(() => apply({ operation: "result", itemID: "t", reference: milestone.id, note: "错项" }));
    apply({ operation: "result", itemID: "r", reference: milestone.id, note: "已交付" });
    const handoff = apply({ operation: "handoff", itemID: "t", recipient: "River", note: "请回看" });
    apply({ operation: "acknowledge", itemID: "t", reference: handoff.id, note: "收到" });
    const pause = apply({ operation: "pause", itemID: "t" });
    const remind = { operation: "remind", itemID: "t", due: dates.end, reference: pause.id, note: "回看", recipient: "*" };
    apply(remind);
    apply({ operation: "resume", itemID: "t" });
    assert.throws(() => apply(remind));
    apply({ operation: "close", itemID: "t" });
    const { items } = store.snapshot(null).body.workspace;
    assert.deepEqual(items.t.members, [{ name: "Jun", role: "验收" }]);
    assert.equal(items.r.status, "自由状态"); assert.equal(items.t.closed, true);
    assert.equal(items.r.kind, "requirement");
  } finally { store.close(); }
});

test("an invalid import rolls back the entire batch and remote binding needs credentials", () => {
  const store = new JournalStore(":memory:");
  try {
    assert.throws(() => relayServer(store, "0.0.0.0", new Map()), /member tokens/);
    const entry = (kind, itemID) => entrySchema.parse({ version: 1, sequence: 1, time: "2030-01-01T00:00:00Z",
      actor: "River", source: "example", id: randomUUID(), change: { operation: "create", itemID, kind, title: itemID } });
    const original = entry("idea", "one");
    assert.throws(() => store.import([original, entry("task", "orphan")]));
    assert.deepEqual(store.snapshot(null).body.workspace.entries, []);
    store.import([original]);
    assert.deepEqual(store.snapshot(null).body.workspace.entries, [original]);
    assert.throws(() => store.import([original]), /empty/);
  } finally { store.close(); }
});
