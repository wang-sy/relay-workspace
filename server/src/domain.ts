import { z } from "zod";

export class ApiError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

const text = z.string().refine(value => value.trim().length > 0, "Must not be blank");
const id = text.refine(value => Buffer.byteLength(value, "utf8") <= 160, "Item ID exceeds 160 bytes");
const uuid = z.guid().transform(value => value.toLowerCase());
const timestamp = z.iso.datetime({ offset: true }).refine(value => Number.isFinite(Date.parse(value)))
  .transform(value => new Date(value).toISOString().replace(/\.\d{3}Z$/, "Z"));
const kinds = z.enum(["direction", "requirement", "task", "idea"]);
const member = z.strictObject({ name: text, role: z.string() });
export const changeSchema = z.strictObject({
  operation: z.enum(["create", "update", "promote", "pause", "resume", "close", "milestone",
    "result", "handoff", "acknowledge", "remind"]),
  itemID: id,
  kind: kinds.optional(),
  title: text.optional(),
  parentID: id.optional(),
  status: text.optional(),
  category: z.string().optional(),
  note: z.string().optional(),
  next: z.string().optional(),
  members: z.array(member).optional(),
  start: timestamp.optional(),
  end: timestamp.optional(),
  due: timestamp.optional(),
  recipient: z.string().optional(),
  reference: uuid.optional(),
  affectsRequirement: z.boolean().optional(),
});

export const writeSchema = z.strictObject({
  requestID: uuid, actor: text, source: text, session: z.string().optional(), change: changeSchema,
});

export const entrySchema = z.strictObject({
  version: z.literal(1), id: uuid, sequence: z.number().int().positive(),
  time: timestamp, actor: text, source: text, session: z.string().optional(), change: changeSchema,
});

export type Write = z.infer<typeof writeSchema>;
export type Entry = z.infer<typeof entrySchema>;
export interface Item {
  id: string;
  kind: z.infer<typeof kinds>;
  title: string;
  status: string;
  members: z.infer<typeof member>[];
  closed: boolean;
  parentID?: string;
  category?: string;
  next?: string;
  start?: string;
  end?: string;
  pauseID?: string;
}

function requireChange(value: unknown, message: string): asserts value {
  if (!value) throw new ApiError(422, message);
}

// Called inside the same transaction that allocates the sequence and commits the event.
export function project(write: Write, getItem: (id: string) => Item | undefined,
                        getEntry: (id: string) => Entry | undefined): Item {
  const c = write.change;
  const previous = getItem(c.itemID);
  let item: Item;
  if (c.operation === "create") {
    if (previous) throw new ApiError(409, "Item already exists");
    requireChange(c.kind && c.title, "create needs kind and title");
    item = { id: c.itemID, kind: c.kind, title: c.title, status: "待推进", members: [], closed: false };
  } else {
    requireChange(previous, "Unknown work item");
    item = previous;
  }
  if (c.operation === "promote") {
    requireChange(item.kind === "idea", "Only an exploration can be promoted");
    item.kind = "requirement";
  }
  for (const key of ["parentID", "title", "status", "category", "next", "start", "end"] as const) {
    if (c[key] !== undefined) item[key] = c[key];
  }
  const parent = item.parentID ? getItem(item.parentID) : undefined;
  switch (item.kind) {
    case "direction": requireChange(!item.parentID, "A direction cannot have a parent"); break;
    case "idea": requireChange(!item.parentID || parent?.kind === "direction", "An exploration can link to a direction"); break;
    case "requirement":
      requireChange(parent?.kind === "direction", "A requirement needs a direction");
      requireChange(item.start && item.end, "A requirement needs start and end");
      break;
    case "task": requireChange(parent?.kind === "requirement", "A task needs a requirement"); break;
  }
  requireChange(!item.start || !item.end || item.start <= item.end, "End precedes start");
  for (const member of c.members ?? []) {
    item.members = item.members.filter(existing => existing.name !== member.name);
    item.members.push(member);
  }
  switch (c.operation) {
    case "pause": item.pauseID = write.requestID; item.closed = false; break;
    case "resume":
    case "close": delete item.pauseID; item.closed = c.operation === "close"; break;
    case "milestone": requireChange(c.due && c.note?.trim(), "A milestone needs due and note"); break;
    case "handoff": requireChange(c.recipient?.trim() && c.note?.trim(), "A handoff needs a recipient and note"); break;
    case "result":
    case "acknowledge": {
      const original = c.reference ? getEntry(c.reference) : undefined;
      const expected = c.operation === "result" ? "milestone" : "handoff";
      requireChange(original?.change.operation === expected && original.change.itemID === item.id,
                    "Reference a matching event on this item");
      requireChange(c.note?.trim(), "Record the outcome in note");
      break;
    }
    case "remind":
      requireChange(c.due && c.recipient?.trim() && c.note?.trim(), "A reminder needs due, recipient and note");
      requireChange(!c.reference || c.reference === item.pauseID, "Reference the current pause");
      break;
  }
  return item;
}
