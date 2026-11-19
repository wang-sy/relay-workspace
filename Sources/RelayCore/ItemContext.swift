import CryptoKit
import Foundation

public struct ContextMaterial: Codable, Sendable {
  public let kind: String
  public let title: String
  public let sourceVersion, url, body, filename, mime, digest: String?
  public let bytes: Int?
}

public struct ContextReference: Codable, Identifiable, Sendable {
  public let id, itemID, materialID, purpose, actor, source: String
  public let time: Date
  public let revision, latestRevision: Int
  public let eventID, note, session, slot, locator, anchor, latestReferenceID: String?
  public let material: ContextMaterial

  public var originalURL: URL? {
    guard let address = material.url, var parts = URLComponents(string: address),
      parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil
    else { return nil }
    if let anchor { parts.fragment = anchor.removingPercentEncoding ?? anchor }
    return parts.url
  }
}

public struct ContextHighlight: Codable, Identifiable, Sendable {
  public let slot: String
  public var id: String { slot }
  public let text, sourceTitle, referenceID, eventID: String?
  public let time: Date?
}

public struct ContextMoment: Codable, Identifiable, Sendable {
  public let id, kind, title, actor, source: String
  public let time: Date
  public let text, referenceID, eventID: String?
}

public struct ContextPage<Element: Codable & Sendable>: Codable, Sendable {
  public let items: [Element]
  public let next: String?
}

public struct ItemRecall: Codable, Sendable {
  public let item: Item
  public let highlights: [ContextHighlight]
  public let referenceCount: Int
  public let references: ContextPage<ContextReference>
  public let timeline: ContextPage<ContextMoment>
}

public struct ContextMatch: Codable, Identifiable, Sendable {
  public let itemID, title, kind, match: String
  public let referenceID, eventID: String?
  public var id: String { itemID }
}

/// Read capabilities used by all three native clients.
public protocol ContextReading: Sendable {
  var url: URL { get }
  func recall(_ item: String, since: String?) async throws -> ItemRecall
  func findContext(_ query: String) async throws -> [ContextMatch]
  func reference(_ id: String) async throws -> ContextReference
  func references(_ item: String, before: String?, eventID: String?) async throws -> ContextPage<
    ContextReference
  >
  func contextHistory(_ item: String, since: String?, before: String?) async throws -> ContextPage<
    ContextMoment
  >
  func fileBytes(_ reference: ContextReference) async throws -> Data
}

extension RemoteJournal: ContextReading {
  public func recall(_ item: String, since: String? = nil) async throws -> ItemRecall {
    try await contextRead("recall", ["itemID": item, "since": since])
  }
  public func findContext(_ query: String) async throws -> [ContextMatch] {
    try await contextRead("search", ["q": query])
  }
  public func references(_ item: String, before: String? = nil, eventID: String? = nil) async throws
    -> ContextPage<ContextReference>
  {
    try await contextRead("references", ["itemID": item, "before": before, "eventID": eventID])
  }
  public func contextHistory(_ item: String, since: String? = nil, before: String? = nil)
    async throws -> ContextPage<ContextMoment>
  {
    try await contextRead("history", ["itemID": item, "since": since, "before": before])
  }
  public func reference(_ id: String) async throws -> ContextReference {
    guard let uuid = UUID(uuidString: id) else { throw RelayError("资料引用 ID 无效") }
    return try await contextRead("references/" + uuid.uuidString.lowercased(), [:])
  }
  public func fileBytes(_ reference: ContextReference) async throws -> Data {
    guard let uuid = UUID(uuidString: reference.id), let digest = reference.material.digest,
      let size = reference.material.bytes, size >= 0, size <= 12 * 1024 * 1024
    else { throw RelayError("此引用没有可下载的附件") }
    let (data, _) = try await send(
      request("context/references/" + uuid.uuidString.lowercased() + "/file"), accepting: [200])
    guard data.count == size,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest
    else { throw RelayError("附件内容与该版本的校验值不符") }
    return data
  }
  private func contextRead<T: Decodable>(_ path: String, _ query: [String: String?]) async throws
    -> T
  {
    var req = request("context/" + path)
    guard let url = req.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw RelayError("服务地址无效") }
    let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
    if !items.isEmpty {
      parts.queryItems = items
      parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(
        of: "+", with: "%2B")
    }
    req.url = parts.url
    let (data, _) = try await send(req, accepting: [200])
    return try Wire.decoder().decode(T.self, from: data)
  }
  public func attachContext(_ data: Data) async throws -> Data {
    var req = try agentRequest("context/references")
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    return try await send(req, accepting: [200, 201]).0
  }
}
