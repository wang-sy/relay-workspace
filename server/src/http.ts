import { createHash } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { z } from "zod";
import { ApiError, writeSchema } from "./domain.js";
import type { JournalStore } from "./store.js";
import { deploymentSchema, functionID, switchSchema } from "./function-contract.js";
import { validateCode } from "./function-runtime.js";

const loopbacks = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);
const hash = (value: string) => createHash("sha256").update(value).digest("hex");

type MemberAccess = { actor: string; scope: "viewer" | "agent" };
type MemberKeys = Map<string, MemberAccess>;

export function memberKeys(json?: string): MemberKeys {
  if (!json) return new Map();
  let config: unknown;
  try { config = JSON.parse(json); } catch { throw new Error("Invalid RELAY_MEMBERS_JSON"); }
  const token = z.string().min(24).regex(/^\S+$/);
  const credentials = z.union([token, z.object({ viewer: token, agent: token }).strict()]);
  const parsed = z.record(z.string().trim().min(1), credentials).safeParse(config);
  if (!parsed.success || !Object.keys(parsed.data).length) throw new Error("Invalid RELAY_MEMBERS_JSON");
  const keys: MemberKeys = new Map();
  function register(token: string, access: MemberAccess) {
    const fingerprint = hash(token);
    if (keys.has(fingerprint)) throw new Error("Each credential needs a distinct token");
    keys.set(fingerprint, access);
  }
  for (const [actor, value] of Object.entries(parsed.data)) {
    if (typeof value === "string") register(value, { actor, scope: "agent" });
    else {
      register(value.viewer, { actor, scope: "viewer" });
      register(value.agent, { actor, scope: "agent" });
    }
  }
  return keys;
}

function bearer(request: IncomingMessage): string | undefined {
  return /^Bearer ([^\s]+)$/i.exec(request.headers.authorization ?? "")?.[1];
}

function authorize(request: IncomingMessage, keys: MemberKeys): MemberAccess | null {
  if (keys.size) {
    const token = bearer(request);
    const member = token && keys.get(hash(token));
    if (!member) throw new ApiError(401, "A valid Relay member token is required");
    return member;
  }
  // Restrict the unconfigured demo to clients addressing the local service directly.
  if (!/^(\[::1\]|127\.0\.0\.1|localhost)(:\d+)?$/i.test(request.headers.host ?? "") || request.headers.origin) {
    throw new ApiError(403, "Local demo requests must address loopback");
  }
  return null;
}

async function readBody(request: IncomingMessage): Promise<unknown> {
  if (request.headers["content-type"]?.split(";")[0]?.trim() !== "application/json") {
    throw new ApiError(415, "Expected application/json");
  }
  const chunks: Buffer[] = [];
  let bytes = 0;
  if (Number(request.headers["content-length"]) > 256 * 1024) throw new ApiError(413, "Write exceeds 256 KiB");
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytes += data.length;
    if (bytes > 256 * 1024) {
      request.resume();
      throw new ApiError(413, "Write exceeds 256 KiB");
    }
    chunks.push(data);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw new ApiError(400, "Invalid JSON"); }
}

function json(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  response.end(JSON.stringify(body));
}

export function relayServer(store: JournalStore, host: string, keys: MemberKeys, localAgentToken?: string) {
  const localAgentKey = localAgentToken && hash(localAgentToken);
  if (!keys.size && !loopbacks.has(host)) throw new Error("Configure member tokens before listening outside loopback");
  return createServer({ requestTimeout: 15000, headersTimeout: 10000 }, async (request, response) => {
    try {
      const path = request.url?.split("?")[0];
      if (path === "/healthz" && request.method === "GET") return json(response, 200, { status: "ok" });
      const access = authorize(request, keys);
      const viewer = access?.actor ?? null;
      if (request.method !== "GET" && request.method !== "HEAD") {
        if (access?.scope === "viewer") throw new ApiError(403, "此令牌仅供查看。请为助手配置 Agent 令牌。");
        if (request.headers["x-relay-client"] !== "agent") throw new ApiError(403, "请通过新版 Relay CLI 或 MCP 更新看板。");
        if (!access && (!localAgentKey || hash(bearer(request) ?? "") !== localAgentKey)) {
          throw new ApiError(403, "缺少本机 Agent 凭据。请在运行服务的账户下使用 Relay CLI 或 MCP。");
        }
      }
      if (path === "/v1/functions" && request.method === "GET") return json(response, 200, store.functions.list());
      const match = /^\/v1\/functions\/([^/]+)$/.exec(path ?? "");
      if (match) {
        const key = functionID.safeParse(match[1]);
        if (!key.success) throw new ApiError(422, "Invalid function ID");
        const id = key.data;
        if (request.method === "GET") return json(response, 200, store.functions.get(id));
        if (request.method === "PUT" || request.method === "PATCH") {
          const body = await readBody(request);
          const attributed = viewer && body && typeof body === "object" && !Array.isArray(body) ? { ...body, actor: viewer } : body;
          if (request.method === "PATCH") {
            const data = switchSchema.parse(attributed);
            return json(response, 200, store.functions.setEnabled(id, data.expectedRevision, data.enabled, data.actor));
          }
          const { actor, expectedRevision, ...definition } = deploymentSchema.parse(attributed);
          await validateCode(definition.code);
          return json(response, 200, store.functions.deploy(id, expectedRevision, definition, actor));
        }
      }
      if (path === "/v1/workspace" && request.method === "GET") {
        const snapshot = store.snapshot(viewer, request.headers["if-none-match"], request.headers["x-relay-types"] === "open");
        if (access) response.setHeader("X-Relay-Access", access.scope);
        response.setHeader("Vary", "X-Relay-Types, Authorization");
        response.setHeader("ETag", snapshot.etag);
        if (!snapshot.body) {
          response.writeHead(304, { "Cache-Control": "no-store" }); response.end(); return;
        }
        return json(response, 200, snapshot.body);
      }
      if (path === "/v1/events" && request.method === "POST") {
        const body = await readBody(request);
        const attributed = viewer && body && typeof body === "object" && !Array.isArray(body)
          ? { ...body, actor: viewer } : body;
        const parsed = writeSchema.safeParse(attributed);
        if (!parsed.success) {
          const issue = parsed.error.issues[0];
          throw new ApiError(422, "Invalid write at " + (issue?.path.join(".") || "request"));
        }
        const result = store.append(parsed.data);
        return json(response, result.created ? 201 : 200, result.entry);
      }
      throw new ApiError(404, "Route not found");
    } catch (error) {
      if (error instanceof z.ZodError) return json(response, 422, { error: "Invalid function field: " + (error.issues[0]?.path.join(".") || "request") });
      if (error instanceof ApiError) return json(response, error.status, { error: error.message });
      console.error("Relay could not complete a storage operation.");
      return json(response, 500, { error: "Workspace storage is unavailable" });
    }
  });
}
