#if os(macOS)
  import Foundation
  import XCTest

  @testable import RelayCore

  final class AssistantConnectionTests: XCTestCase {
    private let tool = URL(
      fileURLWithPath: "/Applications/Relay Workspace.app/Contents/MacOS/relay")
    private let member = "O'Brien $team"

    func testBothClientsReceiveTheExactServiceAndMemberWithoutASecret() throws {
      let settings = AssistantConnection(
        relay: tool, server: "https://relay.example/team", keychain: true, actor: member)
      let args = ["--server", "https://relay.example/team", "--keychain", "mcp"]
      XCTAssertEqual(
        try settings.addArguments(for: .codex),
        [
          "mcp", "add", "relay", "--env", "RELAY_ACTOR=" + member, "--env", "RELAY_AGENT=Codex",
          "--", tool.path,
        ] + args)
      let claude = try settings.addArguments(for: .claude)
      XCTAssertEqual(Array(claude.dropLast()), ["mcp", "add-json", "--scope", "user", "relay"])
      let json = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(claude.last).utf8))
          as? [String: Any])
      XCTAssertEqual(json["command"] as? String, tool.path)
      XCTAssertEqual(json["args"] as? [String], args)
      XCTAssertEqual(
        json["env"] as? [String: String], ["RELAY_ACTOR": member, "RELAY_AGENT": "Claude Code"])
    }

    func testCopiedCommandPreservesArgumentsThroughAShell() throws {
      let folder = URL(fileURLWithPath: "/tmp/Relay's shared records")
      let settings = AssistantConnection(relay: tool, folder: folder, actor: member)
      for client in LocalAssistant.allCases {
        let command = try settings.terminalCommand(for: client)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Substitute argument printing for the client, without running either external program.
        shell.arguments = ["-c", #"set -- "# + command + #"; shift; printf '%s\0' "$@""#]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertEqual(
          bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) },
          try settings.addArguments(for: client))
      }
    }

    func testForeignOrUnreadableCodexEntryIsNeverOverwritten() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let fixture = root.appendingPathComponent("codex")
      let marker = root.appendingPathComponent("called-add")
      try """
      #!/bin/sh
      if [ "$2" = add ]; then /usr/bin/touch "$MARKER"; exit 0; fi
      echo "$EXISTING"
      exit "$STATUS"
      """.write(to: fixture, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
      let settings = AssistantConnection(relay: fixture, folder: root, actor: member)
      for (status, existing) in [
        ("0", #"{"enabled":true,"transport":{"type":"stdio","command":"/another/relay"}}"#),
        ("0", "unreadable response"), ("1", "permission denied"),
      ] {
        do {
          _ = try await settings.register(
            with: .codex, executable: fixture,
            environment: ["STATUS": status, "EXISTING": existing, "MARKER": marker.path])
          XCTFail("Unexpectedly accepted an unknown Codex entry")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)) }
      }
    }
  }
#endif
