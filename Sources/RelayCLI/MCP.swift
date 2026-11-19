import Foundation
import RelayCore

private typealias Object = [String: Any]
private func prop(_ text: String) -> Object { ["type": "string", "description": text] }
private let changeFields: Object = [
  "operation": ["type": "string", "enum": WorkOperation.allCases.map(\.rawValue)],
  "itemID": prop("Stable work item ID. Look up an existing item before creating a new one."),
  "kind": ["type": "string", "enum": ItemKind.allCases.map(\.rawValue)],
  "parentID": prop(
    "Direction ID for a requirement or optional exploration link; requirement ID for a task."),
  "title": prop("Title for create, or an updated title."),
  "status": prop("Free text. Suggested values: planned, active, waiting, delivered."),
  "category": prop("Exploration category path, e.g. Engineering / Productivity."),
  "note": prop(
    "Record the outcome when closing a requirement. For a pause or handoff, state what is needed."),
  "next": prop("Next action someone can pick up."),
  "members": [
    "type": "array",
    "items": [
      "type": "object", "required": ["name", "role"],
      "properties": [
        "name": prop("Member label"), "role": prop("Role on this specific item, free text"),
      ],
    ],
  ],
  "start": prop("ISO 8601 timestamp. Required on a scheduled requirement."),
  "end": prop("ISO 8601 timestamp. Required on a scheduled requirement."),
  "due": prop("ISO 8601 timestamp for milestone or remind."),
  "recipient": prop(
    "Member needed to unblock a pause, or the recipient of a handoff or reminder. * addresses everyone."
  ),
  "affectsRequirement": [
    "type": "boolean",
    "description":
      "On a task pause or handoff, set true if it affects the parent requirement's next step, false for task-only work.",
  ],
  "reference": prop(
    "Event UUID for acknowledge/result, or the current pause UUID for a conditional reminder."),
]
private let descriptors: [Object] = [
  [
    "name": "relay_read",
    "description": "Read the current team requirement board, full journal or potential omissions.",
    "inputSchema": [
      "type": "object",
      "properties": ["scope": ["type": "string", "enum": ["workspace", "board", "gaps"]]],
      "additionalProperties": false,
    ],
  ],
  [
    "name": "relay_apply",
    "description":
      "Append one attributed change. Reuse the requestID when retrying the same change.",
    "inputSchema": [
      "type": "object", "required": ["requestID", "change"],
      "properties": [
        "requestID": prop("Unique UUID for this request."),
        "session": prop("Optional local agent session label."),
        "change": [
          "type": "object", "required": ["operation", "itemID"], "properties": changeFields,
          "additionalProperties": false,
        ],
      ], "additionalProperties": false,
    ],
  ],
]

private let functionTool: Object = [
  "name": "relay_functions",
  "description":
    "Manage JavaScript functions hosted on the Relay server. list or get first. get returns code, revision and recent runs. deploy uses expectedRevision 0 for creation, the current revision for replacement. Jobs survive client disconnects.",
  "inputSchema": [
    "type": "object", "required": ["action"], "additionalProperties": false,
    "properties": [
      "action": ["type": "string", "enum": ["list", "get", "deploy", "enable", "disable"]],
      "id": prop("Stable lowercase function ID for all actions except list."),
      "expectedRevision": [
        "type": "integer", "minimum": 0, "description": "Required for mutations.",
      ],
      "name": prop("Display name, required for deploy."),
      "enabled": ["type": "boolean", "description": "Set false to save a paused definition."],
      "trigger": [
        "type": "object", "required": ["kind"], "additionalProperties": false,
        "properties": [
          "kind": ["type": "string", "enum": ["event", "at", "cron"]],
          "operation": ["type": "string", "enum": WorkOperation.allCases.map(\.rawValue)],
          "itemID": prop("Optional target. Event triggers match all items if omitted."),
          "delaySeconds": [
            "type": "integer", "minimum": 0, "description": "Optional delay following an event.",
          ],
          "at": prop("ISO 8601 timestamp with timezone, required for at."),
          "expression": prop("Five-field cron expression, required for cron."),
          "timezone": prop("IANA timezone, required for cron."),
        ],
      ],
      "code": prop(
        "Synchronous JavaScript function body. ctx has current item, original event, now, scheduledAt, actor, functionID, revision, and items for unscoped timers. Return [] to skip or up to 8 standard relay_apply change objects. For remind include itemID, due, recipient and note. For delayed pauses check ctx.item?.pauseID === ctx.event?.id first. Relay commits actions together. No Node or network access."
      ),
    ],
  ],
]

func serveMCP(_ tools: AgentTools) async {
  var available = descriptors
  if case .server = tools.journal { available.append(functionTool) }
  func reply(_ id: Any, _ key: String, _ payload: Any) {
    let message: Object = ["jsonrpc": "2.0", "id": id, key: payload]
    if var data = try? JSONSerialization.data(withJSONObject: message) {
      data.append(10)
      FileHandle.standardOutput.write(data)
    }
  }
  let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  var initialized = false
  while let line = readLine() {
    guard !line.isEmpty else { continue }
    let value: Any
    do { value = try JSONSerialization.jsonObject(with: Data(line.utf8)) } catch {
      reply(NSNull(), "error", ["code": -32700, "message": "Parse error"])
      continue
    }
    guard let request = value as? Object, request["jsonrpc"] as? String == "2.0",
      let method = request["method"] as? String
    else {
      reply(NSNull(), "error", ["code": -32600, "message": "Invalid request"])
      continue
    }
    guard let id = request["id"] else { continue }
    let p = request["params"] as? Object ?? [:]
    switch method {
    case "initialize":
      let version = p["protocolVersion"] as? String ?? ""
      initialized = true
      reply(
        id, "result",
        [
          "protocolVersion": versions.contains(version) ? version : versions[0],
          "capabilities": ["tools": Object()],
          "serverInfo": ["name": "relay-workspace", "version": "0.1.0"],
        ])
    case "ping": reply(id, "result", Object())
    case "tools/list" where initialized: reply(id, "result", ["tools": available])
    case "tools/call" where initialized:
      let args = p["arguments"] as? Object ?? [:]
      do {
        let data: Data
        switch p["name"] as? String {
        case "relay_read": data = try await tools.read(args["scope"] as? String ?? "workspace")
        case "relay_apply":
          data = try await tools.write(JSONSerialization.data(withJSONObject: args))
        case "relay_functions":
          guard let action = args["action"] as? String else {
            throw RelayError("Provide a function action")
          }
          data = try await tools.functions(action, args)
        default:
          reply(id, "error", ["code": -32602, "message": "Unknown tool"])
          continue
        }
        reply(
          id, "result",
          ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]])
      } catch {
        reply(
          id, "result",
          ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
      }
    default:
      reply(
        id, "error", ["code": -32601, "message": "Unsupported method or session not initialized"])
    }
  }
}
