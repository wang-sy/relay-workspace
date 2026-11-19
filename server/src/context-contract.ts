import { createHash } from "node:crypto";
import { z } from "zod";
import { ApiError } from "./domain.js";

export const maxFileBytes = 12 * 1024 * 1024;
export const maxContextRequest = Math.ceil(maxFileBytes / 3) * 4 + 192 * 1024;
const short = z.string().trim().min(1).max(240);
const guid = z.guid().transform((v) => v.toLowerCase());
export const slots = ["decision", "evidence", "next"] as const;
const common = { title: short, sourceVersion: short.optional() };
const file = {
  ...common,
  filename: short,
  mime: z
    .string()
    .regex(/^[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*$/i)
    .max(120),
  data: z.string().max(Math.ceil(maxFileBytes / 3) * 4),
};
const material = z.discriminatedUnion("kind", [
  z.strictObject({ ...common, kind: z.literal("note"), body: z.string().trim().min(1).max(65536) }),
  z.strictObject({ ...common, kind: z.literal("link"), url: z.string().url().max(4096) }),
  z.strictObject({ ...file, kind: z.literal("image") }),
  z.strictObject({ ...file, kind: z.literal("file") }),
]);
export const attachment = z
  .strictObject({
    requestID: guid,
    itemID: z.string().min(1).max(160),
    eventID: guid.optional(),
    actor: short,
    source: short,
    session: short.optional(),
    purpose: short.default("参考资料"),
    note: z.string().trim().min(1).max(3000).optional(),
    slot: z.enum(slots).optional(),
    locator: short.optional(),
    anchor: z.string().trim().min(1).max(512).optional(),
    materialID: guid.optional(),
    revision: z.number().int().positive().optional(),
    expectedRevision: z.number().int().nonnegative().optional(),
    material: material.optional(),
  })
  .superRefine((v, ctx) => {
    if (
      (!v.material && !v.materialID) ||
      (v.material && v.revision !== undefined) ||
      (!v.material && v.expectedRevision !== undefined)
    )
      ctx.addIssue({ code: "custom", message: "Supply material, or materialID and an optional pinned revision" });
    if (v.slot && !v.note) ctx.addIssue({ code: "custom", message: "A summary slot needs a team-visible note" });
  });
export type Attachment = z.infer<typeof attachment>;
export type Material = {
  kind: "note" | "link" | "image" | "file";
  title: string;
  sourceVersion?: string;
  url?: string;
  body?: string;
  filename?: string;
  mime?: string;
  digest?: string;
  bytes?: number;
};
export type Citation = {
  id: string;
  itemID: string;
  eventID?: string;
  actor: string;
  source: string;
  session?: string;
  time: string;
  materialID: string;
  revision: number;
  purpose: string;
  slot?: (typeof slots)[number];
  note?: string;
  locator?: string;
  anchor?: string;
};
export const digest = (data: string | Buffer) => createHash("sha256").update(data).digest("hex");
export function prepareMaterial(v: NonNullable<Attachment["material"]>): {
  value: Material;
  identity: string;
  blob?: Buffer;
  anchor?: string;
} {
  if (v.kind === "link") {
    const url = new URL(v.url);
    if (url.protocol !== "https:" || url.username || url.password)
      throw new ApiError(422, "使用没有内嵌凭据的 HTTPS 原文地址");
    const anchor = url.hash.slice(1) || undefined;
    if (anchor && anchor.length > 512) throw new ApiError(422, "链接定位过长");
    url.hash = "";
    return { value: { ...v, url: url.href }, identity: "link:" + url.href, anchor };
  }
  if (v.kind === "note") return { value: v, identity: "note:" + digest(v.body) };
  const blob = Buffer.from(v.data, "base64");
  if ((v.kind === "image" && !blob.length) || blob.length > maxFileBytes || blob.toString("base64") !== v.data)
    throw new ApiError(422, "附件应为标准 Base64，最大 12 MiB");
  if (/[\\/\x00-\x1f\x7f]/.test(v.filename) || v.filename === "." || v.filename === "..")
    throw new ApiError(422, "请使用不含路径的文件名");
  if (v.kind === "image" && !v.mime.startsWith("image/")) throw new ApiError(422, "图片需要 image MIME 类型");
  const { data: _data, ...metadata } = v;
  const sha = digest(blob);
  return { value: { ...metadata, digest: sha, bytes: blob.length }, identity: v.kind + ":" + sha, blob };
}
