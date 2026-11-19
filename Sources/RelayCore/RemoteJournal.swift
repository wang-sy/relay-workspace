import Foundation
import Security

public struct JournalUpdate: Sendable {
  public let workspace: Workspace?
  public let viewer: String?
  public let etag: String?
}

public enum WorkspaceJournal: Sendable {
  case folder(Journal)
  case server(RemoteJournal)

  public func read(ifNoneMatch etag: String? = nil) async throws -> JournalUpdate {
    switch self {
    case .folder(let journal):
      let state = try await Task.detached(priority: .utility) { try journal.read() }.value
      return JournalUpdate(workspace: state, viewer: nil, etag: nil)
    case .server(let server): return try await server.read(ifNoneMatch: etag)
    }
  }

  public func append(
    _ change: Change, id: UUID, actor: String, source: String, session: String? = nil
  )
    async throws -> Entry
  {
    switch self {
    case .folder(let journal):
      return try await Task.detached {
        try journal.append(change, id: id, actor: actor, source: source, session: session)
      }.value
    case .server(let service):
      return try await service.append(
        change, id: id, actor: actor, source: source, session: session)
    }
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public struct RemoteJournal: Sendable {
  public static let defaultAddress = "http://127.0.0.1:8731"
  public let url: URL
  private let token: String?
  private static let transport: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 20
    return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
  }()

  public static func endpoint(_ address: String) throws -> URL {
    guard var c = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = c.host?.lowercased(), !host.isEmpty,
      let scheme = c.scheme?.lowercased(), c.user == nil, c.password == nil,
      c.query == nil, c.fragment == nil,
      scheme == "https"
        || (scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host))
    else { throw RelayError("请输入 HTTPS 服务地址。本机服务也可使用 http://127.0.0.1:8731。") }
    c.scheme = scheme
    c.host = host
    while c.percentEncodedPath.hasSuffix("/") { c.percentEncodedPath.removeLast() }
    guard let url = c.url else { throw RelayError("无效的服务地址") }
    return url
  }

  public init(address: String, token: String? = nil) throws {
    url = try Self.endpoint(address)
    self.token = token?.isEmpty == false ? token : nil
  }

  private struct Snapshot: Decodable {
    let workspace: Workspace
    let viewer: String?
  }
  private struct Issue: Decodable { let error: String }
  private struct Write: Encodable {
    let requestID: UUID
    let actor: String
    let source: String
    let session: String?
    let change: Change
  }

  private func request(_ path: String) -> URLRequest {
    var request = URLRequest(url: url.appendingPathComponent("v1").appendingPathComponent(path))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    return request
  }

  private func send(_ request: URLRequest, accepting codes: [Int]) async throws -> (
    Data, HTTPURLResponse
  ) {
    let (data, response) = try await Self.transport.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw RelayError("服务响应无效") }
    guard codes.contains(http.statusCode) else {
      if http.statusCode == 401 { throw RelayError("服务未接受此成员令牌，请检查连接设置。") }
      let reason = (try? JSONDecoder().decode(Issue.self, from: data))?.error ?? "服务请求失败"
      throw RelayError("HTTP \(http.statusCode) · \(reason)")
    }
    return (data, http)
  }

  public func read(ifNoneMatch tag: String? = nil) async throws -> JournalUpdate {
    var req = request("workspace")
    if let tag { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
    let (data, response) = try await send(req, accepting: tag == nil ? [200] : [200, 304])
    let etag = response.value(forHTTPHeaderField: "ETag")
    if response.statusCode == 304 {
      return JournalUpdate(workspace: nil, viewer: nil, etag: etag ?? tag)
    }
    let result = try Wire.decoder().decode(Snapshot.self, from: data)
    return JournalUpdate(workspace: result.workspace, viewer: result.viewer, etag: etag)
  }

  public func append(
    _ change: Change, id: UUID, actor: String, source: String, session: String? = nil
  )
    async throws -> Entry
  {
    var req = request("events")
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try Wire.encoder().encode(
      Write(requestID: id, actor: actor, source: source, session: session, change: change))
    let (data, _) = try await send(req, accepting: [200, 201])
    return try Wire.decoder().decode(Entry.self, from: data)
  }

  public func functions() async throws -> [HostedFunction] {
    let (data, _) = try await send(request("functions"), accepting: [200])
    return try Wire.decoder().decode([HostedFunction].self, from: data)
  }

  private func functionRequest(_ id: String, method: String, body: Data? = nil) async throws
    -> HostedFunction
  {
    guard id.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil
    else { throw RelayError("函数 ID 可使用小写字母、数字、连字符和下划线") }
    var req = request("functions/" + id)
    req.httpMethod = method
    if let body {
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, _) = try await send(req, accepting: [200])
    return try Wire.decoder().decode(HostedFunction.self, from: data)
  }

  public func function(_ id: String) async throws -> HostedFunction {
    try await functionRequest(id, method: "GET")
  }

  public func deployFunction(_ id: String, body: Data) async throws -> HostedFunction {
    try await functionRequest(id, method: "PUT", body: body)
  }

  public func setFunctionEnabled(_ id: String, revision: Int, enabled: Bool, actor: String)
    async throws -> HostedFunction
  {
    let body: [String: Any] = ["expectedRevision": revision, "enabled": enabled, "actor": actor]
    return try await functionRequest(
      id, method: "PATCH", body: JSONSerialization.data(withJSONObject: body))
  }
}

public enum ServerCredentials {
  private static func key(_ url: URL) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "io.github.wang-sy.RelayWorkspace.server",
      kSecAttrAccount as String: url.absoluteString,
    ]
  }

  public static func read(_ url: URL) throws -> String? {
    var query = key(url)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
      let token = String(data: data, encoding: .utf8)
    else { throw RelayError("无法读取此服务的钥匙串条目 (\(status))") }
    return token
  }

  public static func save(_ token: String, for url: URL) throws {
    let query = key(url)
    let data = Data(token.utf8)
    var status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var added = query
      added[kSecValueData as String] = data
      #if os(iOS)
        added[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      #endif
      status = SecItemAdd(added as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw RelayError("无法保存此服务的钥匙串条目 (\(status))") }
  }
}
