import Foundation

public struct Member: Codable, Hashable, Sendable {
  public var name: String
  public var role: String
  public init(_ name: String, _ role: String) {
    self.name = name
    self.role = role
  }
}

/// One portable agent write. Missing optional fields preserve existing facts.
public struct Change: Codable, Equatable, Sendable {
  public var operation: WorkOperation
  public var itemID: String
  public var kind: ItemKind?
  public var fields: [String: JSONValue]?
  public var payload: [String: JSONValue]?
  public var definition: TypeDefinition?
  public var expectedRevision: Int?
  public var title: String?
  public var parentID: String?
  public var status: String?
  public var category: String?
  public var note: String?
  public var next: String?
  public var members: [Member]?
  public var start: Date?
  public var end: Date?
  public var due: Date?
  public var recipient: String?
  public var reference: UUID?
  public var affectsRequirement: Bool?

  public init(_ operation: WorkOperation, _ itemID: String) {
    self.operation = operation
    self.itemID = itemID
  }
}

public struct Entry: Codable, Identifiable, Equatable, Sendable {
  public let version: Int
  public let id: UUID
  public let sequence: Int
  public let time: Date
  public let actor: String
  public let source: String
  public let session: String?
  public let change: Change
  public init(
    id: UUID, sequence: Int, time: Date, actor: String, source: String, session: String?,
    change: Change
  ) {
    self.version = 1
    self.id = id
    self.sequence = sequence
    self.time = time
    self.actor = actor
    self.source = source
    self.session = session
    self.change = change
  }
}

public struct Item: Codable, Identifiable, Sendable {
  public let id: String
  public var kind: ItemKind
  public var baseKind: ItemKind?
  public var behavior: ItemKind { baseKind ?? kind }
  public var appearsOnBoard: Bool {
    behavior == .requirement || !ItemKind.allCases.contains(behavior)
  }
  public var fields: [String: JSONValue]?
  public var parentID: String?
  public var title: String
  public var status: String
  public var category: String?
  public var next: String?
  public var members: [Member]
  public var start: Date?
  public var end: Date?
  public var pauseID: UUID?
  public var closed = false
}

public struct Gap: Codable, Identifiable, Sendable {
  public let id: UUID
  public let itemID: String
  public let label: String
  public let reason: String
}

public struct RelayError: LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public enum Wire {
  public static func encoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting =
      pretty
      ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

public struct Workspace: Codable, Sendable {
  public private(set) var items: [String: Item] = [:]
  public private(set) var entries: [Entry] = []
  public private(set) var definitions: [String: RegisteredType]?
  public private(set) var conflicts: [String] = []
  public init() {}
  public func children(of id: String) -> [Item] {
    items.values.filter { $0.parentID == id }.sorted { $0.title < $1.title }
  }
  public func history(_ id: String) -> [Entry] {
    entries.filter { $0.change.itemID == id && $0.change.operation != .defineType }
  }
  public func resolved(_ id: UUID) -> Bool {
    entries.contains {
      $0.change.reference == id && [.result, .acknowledge].contains($0.change.operation)
    }
  }
  public func reminderIsCurrent(_ e: Entry) -> Bool {
    guard e.change.operation == .remind, let item = items[e.change.itemID] else { return false }
    guard let pause = e.change.reference else { return true }
    return item.pauseID == pause && !item.closed
  }
  public func gaps(at now: Date = Date()) -> [Gap] {
    var gaps: [Gap] = []
    for e in entries {
      let c = e.change
      guard let item = items[c.itemID], !item.closed, item.behavior != .idea else { continue }
      var label: String?
      switch c.operation {
      case .create
      where item.behavior == .requirement
        && (item.end ?? .distantFuture) < Calendar.current.startOfDay(for: now):
        label = "计划结束日已过"
      case .pause where item.pauseID == e.id && now.timeIntervalSince(e.time) >= 3 * 86400:
        let scheduled = entries.contains {
          $0.change.itemID == item.id && $0.change.operation == .remind
            && $0.change.reference == e.id && ($0.change.due ?? .distantPast) > now
        }
        if !scheduled { label = "暂停后待回看" }
      case .milestone where (c.due ?? .distantFuture) <= now && !resolved(e.id):
        label = "计划节点缺结果"
      case .handoff where now.timeIntervalSince(e.time) >= 86400 && !resolved(e.id):
        label = "交付尚无回应"
      default: break
      }
      if let label {
        gaps.append(Gap(id: e.id, itemID: item.id, label: label, reason: c.note ?? item.title))
      }
    }
    return gaps
  }

  public mutating func apply(_ e: Entry) throws {
    let c = e.change
    func require(_ ok: Bool, _ msg: String) throws { if !ok { throw RelayError(msg) } }
    func present(_ s: String?) -> Bool {
      !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    try require(e.version == 1 && e.sequence > 0, "Unsupported event format")
    try require(
      present(c.itemID) && c.itemID.utf8.count <= 160 && present(e.actor),
      "An item ID and actor are required")
    try require(
      validName(c.operation.rawValue) && (c.kind.map { validName($0.rawValue) } ?? true),
      "Invalid type name")
    if c.operation == .defineType {
      guard let d = c.definition, let expected = c.expectedRevision, expected >= 0,
        expected < Int.max
      else {
        throw RelayError("defineType needs a definition and expectedRevision")
      }
      var declaration = Change(.defineType, c.itemID)
      declaration.definition = d
      declaration.expectedRevision = expected
      try require(c == declaration, "Unexpected fields on defineType")
      let previous = typeRecord(d.family, c.itemID)
      try require((previous?.revision ?? 0) == expected, "Read the current type revision first")
      try d.validate(id: c.itemID)
      if d.family == .item
        && (previous?.definition.base?.rawValue ?? c.itemID) != (d.base?.rawValue ?? c.itemID)
      {
        try require(
          !entries.contains {
            $0.change.operation == .create && $0.change.kind?.rawValue == c.itemID
          },
          "This item type is in use with a different base")
      }
      if definitions == nil { definitions = [:] }
      definitions?[d.family.rawValue + ":" + c.itemID] = RegisteredType(
        id: c.itemID, revision: expected + 1, definition: d)
      entries.append(e)
      return
    }
    try require(
      c.definition == nil && c.expectedRevision == nil, "Type declarations need defineType")
    try validateFields(
      c.payload, hints: typeRecord(.event, c.operation.rawValue)?.definition.fields, patch: false)
    if let title = c.title { try require(present(title), "Title cannot be empty") }
    if let status = c.status { try require(present(status), "Status cannot be empty") }
    for member in c.members ?? [] { try require(present(member.name), "A member name is required") }
    var item: Item
    if c.operation == .create {
      guard let kind = c.kind, let title = c.title, present(title) else {
        throw RelayError("create needs kind and title")
      }
      try require(items[c.itemID] == nil, "Item already exists: \(c.itemID)")
      let template = typeRecord(.item, kind.rawValue)?.definition
      item = Item(
        id: c.itemID, kind: kind, baseKind: template?.base == kind ? nil : template?.base,
        parentID: c.parentID, title: title, status: c.status ?? template?.defaultStatus ?? "待推进",
        members: [])
    } else {
      guard let existing = items[c.itemID] else { throw RelayError("Unknown item: \(c.itemID)") }
      item = existing
    }
    if c.operation == .promote {
      try require(item.behavior == .idea, "Only an exploration can be scheduled as a requirement")
      item.kind = .requirement
      item.baseKind = nil
    }
    if let fields = c.fields {
      try validateFields(
        fields, hints: typeRecord(.item, item.kind.rawValue)?.definition.fields, patch: true)
      var merged = item.fields ?? [:]
      for (key, value) in fields { merged[key] = value == .null ? nil : value }
      try validateFields(merged, hints: nil, patch: true)
      item.fields = merged
    }
    if let parent = c.parentID { item.parentID = parent }
    switch item.behavior {
    case .direction: try require(item.parentID == nil, "A direction has no parent")
    case .requirement:
      try require(
        item.parentID.flatMap { items[$0]?.behavior } == .direction,
        "A requirement needs a direction")
    case .task:
      try require(
        item.parentID.flatMap { items[$0]?.behavior } == .requirement, "A task needs a requirement")
    case .idea:
      if let parent = item.parentID {
        try require(items[parent]?.behavior == .direction, "An exploration can link to a direction")
      }
    default:
      if let parent = item.parentID { try require(items[parent] != nil, "Unknown parent") }
    }
    if var parent = c.parentID {
      var visited: Set<String> = [item.id]
      while true {
        try require(visited.insert(parent).inserted, "Items cannot form a cycle")
        guard let next = items[parent]?.parentID else { break }
        parent = next
      }
    }
    item.title = c.title ?? item.title
    item.status = c.status ?? item.status
    item.category = c.category ?? item.category
    item.next = c.next ?? item.next
    item.start = c.start ?? item.start
    item.end = c.end ?? item.end
    if let start = item.start, let end = item.end {
      try require(start <= end, "End precedes start")
    }
    if item.behavior == .requirement {
      try require(
        item.start != nil && item.end != nil, "A scheduled requirement needs start and end")
    }
    for member in c.members ?? [] {
      item.members.removeAll { $0.name == member.name }
      item.members.append(member)
    }
    switch c.operation {
    case .pause:
      item.pauseID = e.id
      item.closed = false
    case .resume:
      item.pauseID = nil
      item.closed = false
    case .close:
      item.pauseID = nil
      item.closed = true
    case .milestone: try require(c.due != nil && present(c.note), "A milestone needs due and note")
    case .handoff:
      try require(present(c.recipient) && present(c.note), "A handoff needs recipient and note")
    case .acknowledge, .result:
      let expected: WorkOperation = c.operation == .acknowledge ? .handoff : .milestone
      try require(
        entries.contains {
          $0.id == c.reference && $0.change.operation == expected && $0.change.itemID == c.itemID
        }, "Reference a matching event on this item")
      try require(present(c.note), "Record the outcome in note")
    case .remind:
      try require(
        c.due != nil && present(c.recipient) && present(c.note),
        "A reminder needs due, recipient and note")
      if let ref = c.reference {
        try require(ref == item.pauseID, "Conditional reminder must reference the current pause")
      }
    default: break
    }
    items[item.id] = item
    entries.append(e)
  }

  mutating func replay(_ e: Entry) {
    do { try apply(e) } catch {
      conflicts.append("\(e.id.uuidString): \(error.localizedDescription)")
    }
  }
}
