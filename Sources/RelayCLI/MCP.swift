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
  "note": prop("A concrete conclusion, planned milestone, handoff or reminder message."),
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
  "recipient": prop("Member label for handoff or remind. * addresses all members."),
  "reference": prop(
    "Event UUID for acknowledge/result, or the current pause UUID for a conditional reminder."),
]
private let descriptors: [Object] = [
  [
    "name": "relay_read",
    "description": "Read the shared work journal, or inspect potential omissions.",
    "inputSchema": [
      "type": "object",
      "properties": ["scope": ["type": "string", "enum": ["workspace", "gaps"]]],
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

func serveMCP(_ tools: AgentTools) async {
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
    case "tools/list" where initialized: reply(id, "result", ["tools": descriptors])
    case "tools/call" where initialized:
      let args = p["arguments"] as? Object ?? [:]
      do {
        let data: Data
        switch p["name"] as? String {
        case "relay_read": data = try await tools.read(args["scope"] as? String ?? "workspace")
        case "relay_apply":
          data = try await tools.write(JSONSerialization.data(withJSONObject: args))
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
