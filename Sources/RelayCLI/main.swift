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
    case "gaps": return try Wire.encoder().encode(workspace.gaps())
    default: throw RelayError("scope must be workspace or gaps")
    }
  }

  func write(_ data: Data) async throws -> Data {
    let request = try Wire.decoder().decode(WriteRequest.self, from: data)
    let entry = try await journal.append(
      request.change, id: request.requestID, actor: actor, source: source, session: request.session)
    return try Wire.encoder().encode(entry)
  }
}

let help = """
  relay [--server URL [--keychain] | --workspace DIRECTORY] read | gaps | apply | sample | mcp

  read and gaps print JSON. apply reads one JSON write from stdin. mcp serves tools over stdio.
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
  guard args.count <= 1 else { throw RelayError(help) }
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
  case "read", "gaps": data = try await tools.read(command == "read" ? "workspace" : "gaps")
  case "apply": data = try await tools.write(FileHandle.standardInput.readDataToEndOfFile())
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
