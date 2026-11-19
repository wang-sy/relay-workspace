import type { DatabaseSync } from "node:sqlite";

// Include short Chinese word pairs so a remembered fragment also matches a longer sentence.
const segmenter = new Intl.Segmenter("zh", { granularity: "word" });
const stop = new Set(
  "之前 那个 那条 当时 后来 什么 为什么 我们 怎么 一个 一下 相关 关于 事情 需求 想法 上次 的 是 在 了 和 我 找 我想 请 帮我 the was and that about".split(
    " ",
  ),
);
const normalize = (s: string) => s.normalize("NFKC").toLowerCase().trim();
function terms(query: string) {
  const words = new Map<string, number>();
  for (const part of segmenter.segment(query)) {
    const word = part.segment;
    if (part.isWordLike && !stop.has(word)) words.set(word, word.length > 1 ? 4 : 1);
  }
  for (const [run] of query.matchAll(/\p{Script=Han}{2,}/gu)) {
    const chars = [...run];
    for (let n = 1; n < chars.length; n++) {
      const pair = chars[n - 1]! + chars[n]!;
      if (!stop.has(pair) && !words.has(pair)) words.set(pair, 1);
    }
  }
  const all = [...words];
  const phrases = all.filter(([term]) => [...term].length > 1);
  return (phrases.length ? phrases : all).slice(0, 80);
}
export function findContexts(db: DatabaseSync, raw: string) {
  const query = normalize(raw),
    words = terms(query);
  type Hit = {
    itemID: string;
    title: string;
    kind: string;
    match: string;
    referenceID?: string;
    eventID?: string;
    score: number;
  };
  const best = new Map<string, Hit>();
  const rows = db.prepare(`SELECT i.id AS item_id,json_extract(i.value,'$.title') AS title,
    json_extract(i.value,'$.kind') AS kind, e.* FROM (
      SELECT id AS owner,'item' AS origin,id AS link,
        coalesce(json_extract(value,'$.title'),'') || ' ' || coalesce(json_extract(value,'$.next'),'') || ' ' ||
        coalesce(json_extract(value,'$.category'),'') || ' ' || id AS content FROM items
      UNION ALL SELECT json_extract(request,'$.change.itemID'),'event',id,
        coalesce(json_extract(request,'$.change.note'),'') || ' ' || coalesce(json_extract(request,'$.change.next'),'')
        FROM events WHERE json_extract(request,'$.change.operation')!='defineType'
      UNION ALL SELECT r.item_id,'reference',r.id,
        json_extract(v.metadata,'$.title') || ' ' || coalesce(json_extract(r.record,'$.note'),'') || ' ' ||
        json_extract(r.record,'$.purpose') || ' ' || coalesce(json_extract(r.record,'$.locator'),'') || ' ' ||
        coalesce(json_extract(v.metadata,'$.body'),'') FROM context_refs r JOIN context_versions v
        ON v.material_id=r.material_id AND v.rev=r.rev
    ) e JOIN items i ON i.id=e.owner`);
  for (const row of rows.iterate()) {
    const rawText = String(row.content),
      content = normalize(rawText);
    let score = content.includes(query) ? 25 : 0;
    let first = content.indexOf(query);
    for (const [word, weight] of words) {
      const pos = content.indexOf(word);
      if (pos >= 0) {
        score += weight;
        if (first < 0) first = pos;
      }
    }
    if (!score) continue;
    if (row.origin === "item") score *= 1.15;
    const itemID = String(row.item_id);
    if ((best.get(itemID)?.score ?? 0) >= score) continue;
    const start = Math.max(0, first - 30);
    best.set(itemID, {
      itemID,
      title: String(row.title),
      kind: String(row.kind),
      score,
      match: (start ? "…" : "") + rawText.slice(start, start + 180).trim(),
      referenceID: row.origin === "reference" ? String(row.link) : undefined,
      eventID: row.origin === "event" ? String(row.link) : undefined,
    });
  }
  return [...best.values()].sort((a, b) => b.score - a.score || a.itemID.localeCompare(b.itemID)).slice(0, 20);
}
