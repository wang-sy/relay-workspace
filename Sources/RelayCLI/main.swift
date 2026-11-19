import Foundation
import RelayCore

struct WriteRequest: Decodable {
  let requestID: UUID
  let session: String?
  let change: Change
}

struct AgentTools {
  let journal: WorkspaceJournal
  let actor: String
  let source: String

  func read(_ scope: String) async throws -> Data {
    guard let workspace = try await journal.read().workspace else {
      throw RelayError("Missing workspace snapshot")
    }
    switch scope {
    case "workspace": return try Wire.encoder().encode(workspace)
    case "board": return try Wire.encoder().encode(workspace.requirementBoard())
    case "gaps": return try Wire.encoder().encode(workspace.gaps())
    case "types": return try Wire.encoder().encode(workspace.typeCatalog())
    default: throw RelayError("scope must be workspace, board, gaps or types")
    }
  }

  func write(_ data: Data) async throws -> Data {
    let request = try Wire.decoder().decode(WriteRequest.self, from: data)
    let entry = try await journal.append(
      request.change, id: request.requestID, actor: actor, source: source, session: request.session)
    return try Wire.encoder().encode(entry)
  }

  func functions(_ action: String, _ arguments: [String: Any] = [:]) async throws -> Data {
    guard case .server(let service) = journal else { throw RelayError("托管函数需要连接 Relay 服务") }
    let encoder = Wire.encoder()
    if action == "list" { return try await encoder.encode(service.functions()) }
    guard let id = arguments["id"] as? String else { throw RelayError("Provide a function id") }
    switch action {
    case "get":
      return try await encoder.encode(service.function(id))
    case "deploy":
      var payload = arguments
      payload.removeValue(forKey: "action")
      payload.removeValue(forKey: "id")
      payload["actor"] = actor
      let data = try JSONSerialization.data(withJSONObject: payload)
      return try await encoder.encode(service.deployFunction(id, body: data))
    case "enable", "disable":
      guard let revision = arguments["expectedRevision"] as? Int else {
        throw RelayError("Provide the current expectedRevision")
      }
      return try await encoder.encode(
        service.setFunctionEnabled(
          id, revision: revision, enabled: action == "enable", actor: actor))
    default: throw RelayError("Use list, get, deploy, enable or disable")
    }
  }

  func functionCommand(_ arguments: [String]) async throws -> Data {
    switch (arguments.first ?? "list", arguments.count) {
    case ("list", 0), ("list", 1): return try await functions("list")
    case ("get", 2): return try await functions("get", ["id": arguments[1]])
    case ("deploy", 1):
      guard
        let body = try JSONSerialization.jsonObject(
          with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any]
      else { throw RelayError("Read the function definition as a JSON object from stdin") }
      return try await functions("deploy", body)
    case ("enable", 3), ("disable", 3):
      guard let revision = Int(arguments[2]) else { throw RelayError("Revision must be a number") }
      return try await functions(arguments[0], ["id": arguments[1], "expectedRevision": revision])
    default:
      throw RelayError(
        "relay functions list | get ID | deploy < definition.json | enable ID REV | disable ID REV")
    }
  }
}

let help = """
  relay [--server URL [--keychain] | --workspace DIRECTORY] read | board | gaps | types | apply | sample | functions | context | mcp

  board prints the team's requirement list. read and gaps print the workspace or omissions as JSON.
  apply reads one JSON write from stdin. mcp serves tools over stdio.
  types lists observed vocabulary and versioned templates. Use apply with defineType to publish a template.
  functions list | get ID | deploy < definition.json | enable ID REV | disable ID REV
  context search QUERY | recall ITEM [--since ISO] | attach [--file PATH] [--pin-source] < reference.json
  context list ITEM [--event EVENT] [--before CURSOR] | history ITEM [--since ISO] [--before CURSOR] | get REF | download REF OUTPUT | source REF [--keyword WORD]
  Hosted functions run in the service. get includes the JavaScript source and recent executions.
  Default server: http://127.0.0.1:8731. RELAY_SERVER_URL and RELAY_TOKEN configure a service.
  --keychain uses the token saved by the native app for this exact server URL.
  --workspace or RELAY_WORKSPACE selects a file journal; sample is only available for file journals.
  RELAY_ACTOR and RELAY_AGENT set the attribution. Member tokens determine the author on a protected service.
  """

private func option(_ name: String, in args: inout [String]) throws -> String? {
  guard let i = args.firstIndex(of: name) else { return nil }
  guard args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") else {
    throw RelayError(name + " needs a value")
  }
  let value = args[i + 1]
  args.removeSubrange(i...i + 1)
  return value
}

do {
  var args = Array(CommandLine.arguments.dropFirst())
  let env = ProcessInfo.processInfo.environment
  let serverFlag = try option("--server", in: &args)
  let folderFlag = try option("--workspace", in: &args)
  let keychain = args.contains("--keychain")
  if keychain { args.removeAll { $0 == "--keychain" } }
  let command = args.first ?? "help"
  guard ["functions", "context"].contains(command) || args.count <= 1 else {
    throw RelayError(help)
  }
  if ["help", "-h", "--help"].contains(command) {
    print(help)
    exit(0)
  }
  guard serverFlag == nil || folderFlag == nil else {
    throw RelayError("Choose --server or --workspace")
  }
  let folder = folderFlag ?? (serverFlag == nil ? env["RELAY_WORKSPACE"] : nil)
  let journal: WorkspaceJournal
  if let folder {
    guard !keychain else { throw RelayError("--keychain requires a server") }
    journal = .folder(Journal(URL(fileURLWithPath: folder, isDirectory: true)))
  } else {
    let address = serverFlag ?? env["RELAY_SERVER_URL"] ?? RemoteJournal.defaultAddress
    var token = env["RELAY_TOKEN"]
    if keychain, token == nil {
      token = try ServerCredentials.read(RemoteJournal.endpoint(address))
    }
    journal = .server(try RemoteJournal(address: address, token: token))
  }
  let tools = AgentTools(
    journal: journal, actor: env["RELAY_ACTOR"] ?? NSUserName(),
    source: env["RELAY_AGENT"] ?? "Local Agent")
  let data: Data
  switch command {
  case "read", "board", "gaps", "types":
    data = try await tools.read(command == "read" ? "workspace" : command)
  case "apply": data = try await tools.write(FileHandle.standardInput.readDataToEndOfFile())
  case "context": data = try await tools.contextCommand(Array(args.dropFirst()))
  case "functions": data = try await tools.functionCommand(Array(args.dropFirst()))
  case "sample":
    guard case .folder(let local) = journal else {
      throw RelayError("sample needs --workspace DIRECTORY")
    }
    try local.installExampleIfEmpty()
    data = try await tools.read("workspace")
  case "mcp":
    await serveMCP(tools)
    exit(0)
  default: throw RelayError(help)
  }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
} catch {
  FileHandle.standardError.write(Data(("relay: " + error.localizedDescription + "\n").utf8))
  exit(1)
}
