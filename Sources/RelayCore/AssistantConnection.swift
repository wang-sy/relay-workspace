#if os(macOS)
  import Foundation

  public enum LocalAssistant: String, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude Code"

    fileprivate var program: String { self == .codex ? "codex" : "claude" }
  }

  public enum AssistantRegistration: Equatable, Sendable { case added, alreadyAdded }

  /// The member token stays in the keychain. The client registers only how to run Relay.
  public struct AssistantConnection: Equatable, Sendable {
    public let relay: URL
    public let arguments: [String]
    public let actor: String

    public init(relay: URL, server: String, keychain: Bool, actor: String) {
      self.relay = relay
      self.arguments = ["--server", server] + (keychain ? ["--keychain"] : []) + ["mcp"]
      self.actor = actor
    }

    public init(relay: URL, folder: URL, actor: String) {
      self.relay = relay
      self.arguments = ["--workspace", folder.path, "mcp"]
      self.actor = actor
    }

    private struct Transport: Codable {
      let type: String?
      let command: String?
      let args: [String]?
      let env: [String: String]?
    }

    private func transport(for client: LocalAssistant) -> Transport {
      Transport(
        type: "stdio", command: relay.path, args: arguments,
        env: ["RELAY_ACTOR": actor, "RELAY_AGENT": client.rawValue])
    }

    private func matches(_ saved: Transport, client: LocalAssistant) -> Bool {
      var expected = transport(for: client).env
      // Earlier versions recorded all assistants under the default "Local Agent" source.
      if saved.env?["RELAY_AGENT"] == nil { expected?.removeValue(forKey: "RELAY_AGENT") }
      return (saved.type == nil || saved.type == "stdio") && saved.command == relay.path
        && saved.args == arguments && saved.env == expected
    }

    func addArguments(for client: LocalAssistant) throws -> [String] {
      switch client {
      case .codex:
        return [
          "mcp", "add", "relay", "--env", "RELAY_ACTOR=" + actor,
          "--env", "RELAY_AGENT=" + client.rawValue, "--", relay.path,
        ] + arguments
      case .claude:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(transport(for: client)), as: UTF8.self)
        return ["mcp", "add-json", "--scope", "user", "relay", json]
      }
    }

    public func terminalCommand(for client: LocalAssistant) throws -> String {
      let safe = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_.,:=-")
      return try ([client.program] + addArguments(for: client)).map { word in
        if !word.isEmpty && word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
      }.joined(separator: " ")
    }

    public func register(with client: LocalAssistant) async throws -> AssistantRegistration {
      let environment = ProcessInfo.processInfo.environment
      let home = FileManager.default.homeDirectoryForCurrentUser
      var folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
      folders += [
        "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
        "/usr/bin", "/bin",
      ]
      let path = folders.filter { $0.hasPrefix("/") }.joined(separator: ":")
      var executables = path.split(separator: ":").map {
        URL(fileURLWithPath: String($0)).appendingPathComponent(client.program)
      }
      if client == .codex {
        executables.append(URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"))
        executables.append(
          URL(
            fileURLWithPath:
              "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
          ))
      }
      guard
        let executable = executables.first(where: {
          FileManager.default.isExecutableFile(atPath: $0.path)
        })
      else { throw RelayError("未找到 \(client.rawValue) 命令行工具。如果你已能在终端使用它，请展开「手动设置」。") }
      var childEnvironment = environment
      childEnvironment["PATH"] = path
      return try await register(with: client, executable: executable, environment: childEnvironment)
    }

    func register(with client: LocalAssistant, executable: URL, environment: [String: String])
      async throws
      -> AssistantRegistration
    {
      guard FileManager.default.isExecutableFile(atPath: relay.path) else {
        throw RelayError("找不到 Relay 自带的助手工具。请从完整的 Mac 应用中打开工作空间。")
      }
      return try await Task.detached(priority: .userInitiated) {
        let conflict = RelayError("\(client.rawValue) 已有其他名为 relay 的配置，或该连接已停用。请在助手中移除旧配置后再添加。")
        if client == .codex {
          let existing = try Self.run(executable, ["mcp", "get", "relay", "--json"], environment)
          if existing.status == 0 {
            struct Entry: Decodable {
              let enabled: Bool?
              let transport: Transport
            }
            guard let entry = try? JSONDecoder().decode(Entry.self, from: existing.output),
              entry.enabled != false, matches(entry.transport, client: client)
            else { throw conflict }
            return .alreadyAdded
          }
          guard existing.message.contains("No MCP server named 'relay' found") else {
            throw RelayError("无法读取 Codex 的 relay 配置。请检查 Codex 是否可以正常启动。")
          }
        }
        let result = try Self.run(executable, addArguments(for: client), environment)
        if result.status == 0 { return .added }
        if client == .claude && result.message.contains("already exists in user config") {
          // Only inspect the named user entry. 'claude mcp get' can start the configured server.
          struct Servers: Decodable { let relay: Transport? }
          struct Config: Decodable { let mcpServers: Servers? }
          let directory =
            environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
          let file = directory.appendingPathComponent(".claude.json")
          if let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode(Config.self, from: data).mcpServers?.relay,
            matches(saved, client: client)
          {
            return .alreadyAdded
          }
          throw conflict
        }
        throw RelayError("\(client.rawValue) 未能保存配置。可以展开「手动设置」在终端完成。")
      }.value
    }

    private struct CommandResult {
      let status: Int32
      let output: Data
      var message: String { String(decoding: output, as: UTF8.self) }
    }

    private static func run(_ executable: URL, _ args: [String], _ environment: [String: String])
      throws -> CommandResult
    {
      let process = Process()
      process.executableURL = executable
      process.arguments = args
      process.environment = environment
      process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
      process.standardInput = FileHandle.nullDevice
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      do { try process.run() } catch { throw RelayError("无法启动助手命令行工具，请检查它是否已安装。") }
      let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
      let killHung = DispatchWorkItem {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: stop)
      DispatchQueue.global().asyncAfter(deadline: .now() + 17, execute: killHung)
      defer {
        stop.cancel()
        killHung.cancel()
      }
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      if process.terminationReason == .uncaughtSignal { throw RelayError("助手未能完成设置，请稍后重试。") }
      return CommandResult(status: process.terminationStatus, output: output)
    }
  }
#endif
