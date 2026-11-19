import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { JournalStore } from "../dist/store.js";
import { definitionSchema, nextDue } from "../dist/function-contract.js";
import { runCode, validateCode } from "../dist/function-runtime.js";
import { memberKeys, relayServer } from "../dist/http.js";

const now = Date.parse("2026-01-08T12:00:00Z");
const write = change => ({ requestID: randomUUID(), actor: "River", source: "test", change });
const idea = { operation:"create", kind:"idea", itemID:"demo", title:"Release review" };
const pause = { operation:"pause", itemID:"demo", recipient:"Jun" };
const afterPause = definitionSchema.parse({
  name: "Pause review", trigger: {kind:"event", operation:"pause", delaySeconds:3 * 86400},
  code: "if (!ctx.item || ctx.item.pauseID !== ctx.event.id) return []; return [{operation:'remind', itemID:ctx.item.id, reference:ctx.event.id, recipient:ctx.actor, due:ctx.now, note:'Still paused'}];",
});
const instant = {kind:"at", at:new Date(now).toISOString(), itemID:"demo"};
function at(code) { return definitionSchema.parse({name:"Once", trigger:instant, code}); }

test("delayed code survives restart, reads the current pause and commits a reminder only once", async t => {
  const directory = mkdtempSync(join(tmpdir(),"relay-functions-"));
  const path = join(directory,"db");
  let store = new JournalStore(path);
  t.after(() => { store.close(); rmSync(directory,{recursive:true,force:true}); });
  store.append(write(idea), now);
  store.functions.deploy("review",0,afterPause,"River",now);
  const change = write(pause);
  const original = store.append(change, now).entry;
  store.append(change, now);
  store.close();
  store = new JournalStore(path);
  const other = new JournalStore(path);
  try {
    const due = now + 3 * 86400000;
    await store.functions.tick(() => due - 1);
    assert.equal(store.functions.get("review").runs[0].status,"queued");
    await Promise.all([store.functions.tick(() => due),other.functions.tick(() => due)]);
    const [run] = store.functions.get("review").runs;
    assert.equal(run.status,"succeeded");
    assert.equal(run.attempts,1);
    const reminders = store.snapshot(null).body.workspace.entries.filter(e => e.change.operation === "remind");
    assert.equal(reminders.length,1);
    assert.equal(reminders[0].session,run.id);
    assert.equal(reminders[0].actor,"River");
    assert.equal(reminders[0].change.reference,original.id);
    store.append(write(pause),due);
    store.append(write({operation:"resume",itemID:"demo"}),due + 1000);
    await other.functions.tick(() => due + 3 * 86400000);
    assert.equal(store.functions.get("review").runs[0].status,"skipped");
    assert.equal(store.snapshot(null).body.workspace.entries.filter(e => e.change.operation === "remind").length,1);
  } finally { other.close(); }
});

test("cron uses the requested zone and coalesces missed slots; at fires just once", async () => {
  const store = new JournalStore(":memory:");
  try {
    const trigger = {kind:"cron",expression:"0 9 * * 1-5",timezone:"Asia/Shanghai"};
    const first = Date.parse("2026-01-09T01:00:00Z");
    const restarted = Date.parse("2026-01-13T06:30:00Z");
    assert.equal(nextDue(trigger,now),first);
    assert.throws(() => nextDue({...trigger, timezone:"not-a-zone"},now));
    assert.throws(() => nextDue({...trigger, expression:"* * * * * *"},now));
    store.append(write(idea),now);
    const definition = definitionSchema.parse({name:"Daily check",trigger,
      code:"return ctx.items.map(i => ({operation:'update',itemID:i.id,note:'Checked'}))"});
    store.functions.deploy("cron",0,definition,"River",now);
    await store.functions.tick(() => restarted);
    await store.functions.tick(() => restarted);
    const cron = store.functions.get("cron");
    assert.equal(cron.runs.length,1);
    assert.equal(Date.parse(cron.runs[0].scheduledAt),first);
    assert.equal(cron.runs[0].writes,1);
    assert.equal(Date.parse(cron.nextAt),Date.parse("2026-01-14T01:00:00Z"));
    store.functions.deploy("once",0,at("return []"),"River",now);
    await store.functions.tick(() => restarted);
    await store.functions.tick(() => restarted + 1000);
    assert.equal(store.functions.get("once").runs.length,1);
    assert.equal(store.functions.get("once").nextAt,null);
  } finally { store.close(); }
});

test("invalid output rolls back all writes and function outputs do not recursively trigger functions", async () => {
  const store = new JournalStore(":memory:");
  try {
    store.append(write(idea),now);
    const change = "{operation:'update',itemID:'demo',note:'handled'}";
    const rule = definitionSchema.parse({name:"Observe",trigger:{kind:"event",operation:"update"},code:"return [" + change + "];"});
    store.functions.deploy("observe",0,rule,"River",now);
    store.functions.deploy("bad",0,at("return [" + change + ",{operation:'update',itemID:'missing',note:'invalid'}]"),"River",now);
    await store.functions.tick(() => now);
    assert.match(store.functions.get("bad").runs[0].error,/Unknown work item/);
    assert.equal(store.snapshot(null).body.workspace.entries.length,1);
    store.append(write({operation:"update",itemID:"demo",note:"manual"}),now);
    await store.functions.tick(() => now);
    await store.functions.tick(() => now);
    assert.equal(store.functions.get("observe").runs.length,1);
    assert.equal(store.snapshot(null).body.workspace.entries.length,3);
  } finally { store.close(); }
});

test("a stale worker and a replaced definition cannot commit; changed input is reread", async () => {
  const store = new JournalStore(":memory:");
  try {
    store.append(write(idea),now);
    const definition = at("return [{operation:'update',itemID:ctx.item.id,note:ctx.item.status}]");
    store.functions.deploy("once",0,definition,"River",now);
    let release;
    const gate = new Promise(resolve => { release=resolve; });
    const stalled = store.functions.tick(() => now, async () => { await gate; return [{operation:"update",itemID:"demo",note:"stale"}]; });
    await store.functions.tick(() => now+16000);
    release();
    await stalled;
    assert.equal(store.functions.get("once").runs[0].attempts,2);
    assert.equal(store.snapshot(null).body.workspace.entries.at(-1).change.note,"待推进");
    store.functions.deploy("changed",0,definition,"River",now);
    await store.functions.tick(() => now, async () => {
      store.append(write({operation:"update",itemID:"demo",status:"updated"}),now);
      return [{operation:"update",itemID:"demo",note:"outdated"}];
    });
    assert.equal(store.functions.get("changed").runs[0].status,"queued");
    await store.functions.tick(() => now+3000);
    assert.equal(store.snapshot(null).body.workspace.entries.at(-1).change.note,"updated");
    store.functions.deploy("cancel",0,definition,"River",now);
    await store.functions.tick(() => now, async () => {
      store.functions.setEnabled("cancel",1,false,"Jun",now);
      return [{operation:"update",itemID:"demo",note:"cancelled"}];
    });
    const cancelled=store.functions.get("cancel");
    assert.equal(cancelled.runs[0].status,"cancelled");
    assert.equal(cancelled.actor,"River");
    assert.equal(cancelled.updatedBy,"Jun");
    assert.equal(store.snapshot(null).body.workspace.entries.at(-1).change.note,"updated");
  } finally { store.close(); }
});

test("member authentication binds hosted code, supports versioned retries and rejects invalid source", async t => {
  const store = new JournalStore(":memory:");
  const token = randomUUID();
  const server = relayServer(store,"127.0.0.1",memberKeys(JSON.stringify({River:token})));
  await new Promise(resolve => server.listen(0,"127.0.0.1",resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); store.close(); });
  const base = "http://127.0.0.1:"+server.address().port+"/v1/functions";
  const put = body => fetch(base+"/review",{method:"PUT",headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},body:JSON.stringify(body)});
  const body = {...afterPause,actor:"spoof",expectedRevision:0};
  assert.equal((await fetch(base)).status,401);
  assert.equal((await put({...body,code:"return (",})).status,422);
  assert.equal((await (await put(body)).json()).actor,"River");
  assert.equal((await (await put(body)).json()).revision,1);
  assert.equal((await put({...body,name:"stale edit"})).status,409);
});

test("functions run without host globals and time-limited failures leave the runner available", async () => {
  const context = {functionID:"test",revision:1,now:new Date(now).toISOString(),scheduledAt:new Date(now).toISOString(),actor:"River",item:null,event:null};
  assert.deepEqual(await runCode("if ([typeof process,typeof fetch,typeof require].some(v=>v!=='undefined')) throw Error('host globals'); return [];",context),[]);
  await assert.rejects(runCode("while (true) {}",context));
  await assert.rejects(runCode("return [{}]",context),/Invalid Relay change/);
  await validateCode("return [];");
});
