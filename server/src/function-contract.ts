import { CronExpressionParser } from "cron-parser";
import { z } from "zod";
import { ApiError, changeSchema, type Entry, type Item } from "./domain.js";
import { namedTrigger, sourceTrigger, type SourceTrigger } from "./vocabulary.js";

export const functionID = z.string().regex(/^[a-z0-9][a-z0-9_-]{0,63}$/);
export const triggerSchema = z.union([sourceTrigger, namedTrigger]);
export const definitionSchema = z.strictObject({
  name: z.string().trim().min(1).max(120), trigger: triggerSchema,
  code: z.string().min(1).refine(code => !!code.trim() && Buffer.byteLength(code) <= 32768),
  enabled: z.boolean().default(true),
});
const attribution = { actor: z.string().trim().min(1).max(200), expectedRevision: z.number().int().min(0) };
export const deploymentSchema = definitionSchema.extend(attribution);
export const switchSchema = z.strictObject({ ...attribution, enabled: z.boolean() });
export const changesSchema = z.array(changeSchema).max(8);

export type Definition = z.infer<typeof definitionSchema>;
export type Trigger = Definition["trigger"];
export type FunctionContext = {
  functionID: string; revision: number; actor: string; now: string; scheduledAt: string;
  item: Item | null; event: Entry | null; items?: Item[];
};
export const iso = (time: number) => new Date(time).toISOString().replace(/\.\d{3}Z$/, "Z");

export function nextDue(trigger: SourceTrigger, now: number): number | null {
  if (trigger.kind === "event") return null;
  if (trigger.kind === "at") return Date.parse(trigger.at);
  try {
    if (trigger.expression.split(/\s+/).length !== 5) throw new Error();
    new Intl.DateTimeFormat("en", { timeZone: trigger.timezone });
    return CronExpressionParser.parse(trigger.expression, {
      currentDate: new Date(now), tz: trigger.timezone,
    }).next().getTime();
  } catch {
    throw new ApiError(422, "Provide a five-field cron expression and a valid IANA time zone");
  }
}
