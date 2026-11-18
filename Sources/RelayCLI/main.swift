import Foundation
import RelayCore

struct WriteRequest: Decodable {
  let requestID: UUID
  let session: String?
  let change: Change
}

struct AgentTools {
  let journal: Journal
  let actor: String
  let source: String

  func read(_ scope: String) throws -> Data {
    let workspace = try journal.read()
    switch scope {
    case "workspace": return try Wire.encoder().encode(workspace)
    case "gaps": return try Wire.encoder().encode(workspace.gaps())
    default: throw RelayError("scope must be workspace or gaps")
    }
  }
  func write(_ data: Data) throws -> Data {
    let request = try Wire.decoder().decode(WriteRequest.self, from: data)
    let e = try journal.append(
      request.change, id: request.requestID, actor: actor, source: source, session: request.session)
    return try Wire.encoder().encode(e)
  }
}

let help = """
  relay [--workspace DIRECTORY] read | gaps | apply | sample | mcp

  read and gaps print JSON. apply reads one JSON request from stdin.
  sample installs the example in an empty workspace. mcp serves tools over stdio.
  RELAY_WORKSPACE, RELAY_ACTOR and RELAY_AGENT set the default folder and attribution.
  """
do {
  var args = Array(CommandLine.arguments.dropFirst())
  var folder = ProcessInfo.processInfo.environment["RELAY_WORKSPACE"]
  if let i = args.firstIndex(of: "--workspace") {
    guard args.indices.contains(i + 1) else { throw RelayError("--workspace needs a directory") }
    folder = args[i + 1]
    args.removeSubrange(i...i + 1)
  }
  let command = args.first ?? "help"
  guard args.count <= 1 else { throw RelayError(help) }
  let tools = AgentTools(
    journal: folder.map { Journal(URL(fileURLWithPath: $0, isDirectory: true)) } ?? .local,
    actor: ProcessInfo.processInfo.environment["RELAY_ACTOR"] ?? NSUserName(),
    source: ProcessInfo.processInfo.environment["RELAY_AGENT"] ?? "Local Agent")
  let data: Data
  switch command {
  case "help", "-h", "--help":
    print(help)
    exit(0)
  case "read", "gaps": data = try tools.read(command == "read" ? "workspace" : "gaps")
  case "apply": data = try tools.write(FileHandle.standardInput.readDataToEndOfFile())
  case "sample":
    try tools.journal.installExampleIfEmpty()
    data = try tools.read("workspace")
  case "mcp":
    serveMCP(tools)
    exit(0)
  default: throw RelayError(help)
  }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
} catch {
  FileHandle.standardError.write(Data(("relay: " + error.localizedDescription + "\n").utf8))
  exit(1)
}
