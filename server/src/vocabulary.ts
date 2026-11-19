import { z } from "zod";

export const name = z.string().refine(s => !!s.trim() && Buffer.byteLength(s) <= 160, "Expected a name of up to 160 bytes");
export const baseKinds = ["direction", "requirement", "task", "idea"] as const;
export const operations = ["create", "update", "promote", "pause", "resume", "close",
  "milestone", "result", "handoff", "acknowledge", "remind"];
const itemID = name.optional();
export const sourceTrigger = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("event"), operation: name, itemID,
    delaySeconds: z.number().int().min(0).max(366 * 86400).default(0) }),
  z.strictObject({ kind: z.literal("at"), at: z.iso.datetime({ offset: true }), itemID }),
  z.strictObject({ kind: z.literal("cron"), expression: z.string().trim().min(1).max(120),
    timezone: z.string().trim().min(1).max(100), itemID }),
]);
export type SourceTrigger = z.infer<typeof sourceTrigger>;
export const builtInTriggers = ["event", "at", "cron"];
export const namedTrigger = z.strictObject({ kind: name.refine(s => !builtInTriggers.includes(s)), itemID });
export const fieldHint = z.strictObject({
  type: z.enum(["any", "string", "number", "boolean", "object", "array"]), label: name.optional(),
});
export const definitionSchema = z.strictObject({
  family: z.enum(["item", "event", "trigger", "category", "status", "role"]), label: name.optional(), description: z.string().optional(),
  base: z.enum(baseKinds).optional(), defaultStatus: name.optional(),
  fields: z.record(name, fieldHint).optional(), source: sourceTrigger.optional(),
}).refine(d => d.family === "item" || (d.base === undefined && d.defaultStatus === undefined),
  "Only item types have a base and default status")
  .refine(d => d.family === "trigger" ? !!d.source : !d.source, "Trigger templates need a scheduling source")
  .refine(d => d.family === "item" || d.family === "event" || !d.fields, "Field hints belong to items or events");
export type TypeDefinition = z.infer<typeof definitionSchema>;
export type TypeRecord = TypeDefinition & { id: string; revision: number };

// HTTP requests and function results have already gone through a JSON parser. Bound traversal
// before descending so deeply nested input cannot overflow the JS stack.
type JSONValue = null | boolean | string | number | JSONValue[] | { [key: string]: JSONValue };
function validValue(value: unknown, depth: number): value is JSONValue {
  if (depth > 16) return false;
  if (value === null || typeof value === "boolean" || typeof value === "string") return true;
  if (typeof value === "number") return Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value));
  if (Array.isArray(value)) return value.every(child => validValue(child, depth + 1));
  return typeof value === "object" && Object.values(value).every(child => validValue(child, depth + 1));
}
export const fieldMap = z.custom<Record<string, JSONValue>>(v => v !== null && typeof v === "object"
  && !Array.isArray(v) && Object.keys(v).every(k => name.safeParse(k).success)
  && validValue(v, 0) && Buffer.byteLength(JSON.stringify(v)) <= 64 * 1024, "Expected JSON fields up to 64 KiB and 16 levels");
export type FieldMap = z.infer<typeof fieldMap>;
export function mismatch(values: FieldMap | undefined, hints: TypeDefinition["fields"], patch: boolean) {
  for (const [key, value] of Object.entries(values ?? {})) {
    const expected = hints && Object.hasOwn(hints, key) ? hints[key]?.type : undefined;
    if (!expected || expected === "any" || (patch && value === null)) continue;
    const actual = value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
    if (actual !== expected) return "Field " + key + " expects " + expected;
  }
}
