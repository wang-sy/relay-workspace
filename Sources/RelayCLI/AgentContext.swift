import Foundation
import RelayCore
import UniformTypeIdentifiers

extension AgentTools {
  var contextServer: RemoteJournal {
    get throws {
      guard case .server(let server) = journal else {
        throw RelayError("共享资料需要团队服务，请用 --server 连接")
      }
      return server
    }
  }

  func attach(_ arguments: [String: Any], localFile: URL? = nil) async throws -> Data {
    let server = try contextServer
    var input = arguments
    var file = localFile
    if let relative = input.removeValue(forKey: "filePath") as? String {
      guard localFile == nil, !relative.hasPrefix("/"), !relative.isEmpty,
        let path = ProcessInfo.processInfo.environment["RELAY_ATTACHMENT_ROOT"], !path.isEmpty
      else {
        throw RelayError("MCP 本地文件使用 RELAY_ATTACHMENT_ROOT 下的相对路径，也可用 CLI 的 --file 或 material.data")
      }
      let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        .standardizedFileURL
      let resolved = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        .standardizedFileURL
      guard resolved.path.hasPrefix(root.path + "/") else { throw RelayError("附件超出已配置目录") }
      file = resolved
    }
    if let file {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      let limit = 12 * 1024 * 1024
      guard values.isRegularFile == true, let size = values.fileSize, size >= 0, size <= limit
      else {
        throw RelayError("请选择 12 MiB 以内的文件")
      }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      let bytes = try handle.read(upToCount: limit + 1) ?? Data()
      guard bytes.count == size else {
        throw RelayError("读取期间文件发生变化")
      }
      var material = input["material"] as? [String: Any] ?? [:]
      let mime =
        material["mime"] as? String ?? UTType(filenameExtension: file.pathExtension)?
        .preferredMIMEType ?? "application/octet-stream"
      material["mime"] = mime
      material["kind"] = material["kind"] ?? (mime.hasPrefix("image/") ? "image" : "file")
      material["filename"] = material["filename"] ?? file.lastPathComponent
      material["title"] = material["title"] ?? file.lastPathComponent
      material["data"] = bytes.base64EncodedString()
      input["material"] = material
    }
    if input.removeValue(forKey: "pinSource") as? Bool == true {
      guard var material = input["material"] as? [String: Any],
        material["kind"] as? String == "link",
        let raw = material["url"] as? String, let url = URL(string: raw), isLark(url),
        let requestID = input["requestID"] as? String, UUID(uuidString: requestID) != nil
      else { throw RelayError("锁定原文版本需要飞书链接与请求 UUID") }
      if material["sourceVersion"] == nil {
        if let saved = try? await server.reference(requestID),
          let version = saved.material.sourceVersion
        {
          material["sourceVersion"] = version
        } else {
          let raw = try await runLark([
            "docs", "+fetch", "--as", "user", "--doc", url.absoluteString, "--scope", "outline",
            "--max-depth", "1", "--jq", ".data.document.revision_id",
          ])
          guard
            let revision = Int(
              String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
            revision > 0
          else { throw RelayError("飞书未返回可引用的版本号") }
          material["sourceVersion"] = String(revision)
        }
        input["material"] = material
      }
    }
    input["actor"] = actor
    input["source"] = source
    return try await server.attachContext(JSONSerialization.data(withJSONObject: input))
  }

  func recall(_ args: [String: Any]) async throws -> Data {
    let server = try contextServer
    let encoder = Wire.encoder()
    let action = args["action"] as? String
    func required(_ key: String) throws -> String {
      guard let value = args[key] as? String, !value.isEmpty else { throw RelayError("缺少 " + key) }
      return value
    }
    let since = args["since"] as? String
    let before = args["before"] as? String
    switch action {
    case "search": return try await encoder.encode(server.findContext(required("query")))
    case "recall": return try await encoder.encode(server.recall(required("itemID"), since: since))
    case "list":
      return try await encoder.encode(
        server.references(required("itemID"), before: before, eventID: args["eventID"] as? String))
    case "history":
      return try await encoder.encode(
        server.contextHistory(required("itemID"), since: since, before: before))
    case "get": return try await encoder.encode(server.reference(required("referenceID")))
    case "source":
      let ref = try await server.reference(required("referenceID"))
      return try await readLarkSource(ref, keyword: args["keyword"] as? String)
    default: throw RelayError("使用 search、recall、list、history、get、file 或 source")
    }
  }

  func contextCommand(_ arguments: [String]) async throws -> Data {
    guard let action = arguments.first else {
      throw RelayError(
        "使用 relay context search | recall | attach | list | history | get | download | source")
    }
    var rest = Array(arguments.dropFirst())
    func opt(_ key: String) throws -> String? {
      guard let index = rest.firstIndex(of: key) else { return nil }
      guard index + 1 < rest.count else { throw RelayError(key + " 需要参数") }
      let value = rest[index + 1]
      rest.removeSubrange(index...index + 1)
      return value
    }
    switch action {
    case "attach":
      let file = try opt("--file")
      let pin = rest.contains("--pin-source")
      rest.removeAll { $0 == "--pin-source" }
      guard rest.isEmpty,
        let json = try JSONSerialization.jsonObject(
          with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any]
      else { throw RelayError("请从 stdin 传入引用 JSON，可加 --file PATH") }
      var input = json
      if pin { input["pinSource"] = true }
      return try await attach(input, localFile: file.map { URL(fileURLWithPath: $0) })
    case "download":
      guard rest.count == 2 else { throw RelayError("relay context download 引用ID 输出文件") }
      let server = try contextServer
      let ref = try await server.reference(rest[0])
      let bytes = try await server.fileBytes(ref)
      try bytes.write(to: URL(fileURLWithPath: rest[1]), options: .withoutOverwriting)
      return try JSONSerialization.data(withJSONObject: ["bytes": bytes.count, "path": rest[1]])
    case "search":
      guard !rest.isEmpty else { throw RelayError("提供要找回的线索") }
      return try await recall(["action": action, "query": rest.joined(separator: " ")])
    default:
      var payload: [String: Any] = ["action": action]
      for (flag, key) in [
        ("--since", "since"), ("--before", "before"), ("--keyword", "keyword"),
        ("--event", "eventID"),
      ] {
        if let value = try opt(flag) { payload[key] = value }
      }
      guard rest.count == 1 else { throw RelayError("请提供一个事项 ID 或引用 ID") }
      payload[["get", "source"].contains(action) ? "referenceID" : "itemID"] = rest[0]
      return try await recall(payload)
    }
  }
}

// A protected document is read on the agent's Mac as its signed-in Lark user.
// Only the requested response returns over stdio. It is never sent back to Relay.
private func readLarkSource(_ ref: ContextReference, keyword: String?) async throws -> Data {
  guard let url = ref.originalURL, isLark(url) else {
    throw RelayError("此引用可从原链接查看。按身份读取正文支持飞书 docx 或 wiki 链接。")
  }
  var args = [
    "docs", "+fetch", "--as", "user", "--doc", url.absoluteString, "--doc-format", "markdown",
  ]
  if let rev = ref.material.sourceVersion, let n = Int(rev), n > 0 {
    args += ["--revision-id", String(n)]
  }
  if let keyword, !keyword.isEmpty {
    args += ["--scope", "keyword", "--keyword", keyword]
  } else if let anchor = ref.anchor, !anchor.hasPrefix("share-"),
    anchor.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil
  {
    args += ["--scope", "range", "--start-block-id", anchor, "--end-block-id", anchor]
  } else if ref.anchor == nil {
    args += ["--scope", "outline", "--max-depth", "3"]
  }
  let result = try await runLark(args)
  guard let data = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
    data["ok"] as? Bool != false
  else { throw RelayError("飞书未返回有效内容") }
  return result
}

private func isLark(_ url: URL) -> Bool {
  guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
    let host = url.host?.lowercased()
  else { return false }
  return ["feishu.cn", "larksuite.com", "doubao.com"].contains(where: {
    host == $0 || host.hasSuffix("." + $0)
  })
    && url.path.range(of: #"^/(docx|wiki)/[A-Za-z0-9]+/?$"#, options: .regularExpression) != nil
}

private func runLark(_ args: [String]) async throws -> Data {
  return try await Task.detached {
    let env = ProcessInfo.processInfo.environment
    let paths =
      (env["PATH"] ?? "").split(separator: ":").map(String.init) + [
        "/opt/homebrew/bin", "/usr/local/bin",
      ]
    guard
      let binary = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("lark-cli") }).first(
        where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    else { throw RelayError("请在本机安装并登录 lark-cli，或用原链接查看飞书文档") }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = binary
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: deadline)
    defer { deadline.cancel() }
    var result = Data()
    while let chunk = try pipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
      result.append(chunk)
      if result.count > 192 * 1024 {
        if process.isRunning { process.terminate() }
        try? pipe.fileHandleForReading.close()
        throw RelayError("原文较长，请用 keyword 或段落定位缩小范围")
      }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw RelayError("飞书未返回可读正文。请检查本机用户登录、文档权限、版本和定位。")
    }
    return result
  }.value
}
