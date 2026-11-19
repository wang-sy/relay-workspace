import Foundation

/// Item and event names travel as strings, including names introduced by other clients.
public struct ItemKind: RawRepresentable, Hashable, Codable, CaseIterable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public static let direction = Self(rawValue: "direction")
  public static let requirement = Self(rawValue: "requirement")
  public static let task = Self(rawValue: "task")
  public static let idea = Self(rawValue: "idea")
  public static let allCases = [direction, requirement, task, idea]
}

public struct WorkOperation: RawRepresentable, Hashable, Codable, CaseIterable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public static let create = Self(rawValue: "create"), update = Self(rawValue: "update")
  public static let promote = Self(rawValue: "promote"), pause = Self(rawValue: "pause")
  public static let resume = Self(rawValue: "resume"), close = Self(rawValue: "close")
  public static let milestone = Self(rawValue: "milestone"), result = Self(rawValue: "result")
  public static let handoff = Self(rawValue: "handoff"), acknowledge = Self(rawValue: "acknowledge")
  public static let remind = Self(rawValue: "remind"), defineType = Self(rawValue: "defineType")
  public static let allCases = [
    create, update, promote, pause, resume, close, milestone, result, handoff, acknowledge, remind,
    defineType,
  ]
}

public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    guard decoder.codingPath.count < 40 else { throw RelayError("JSON nesting limit exceeded") }
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
  public var display: String {
    switch self {
    case .string(let value): return value
    case .bool(let value): return value ? "true" : "false"
    default:
      return (try? Wire.encoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
  }
  var typeName: String {
    switch self {
    case .null: return "null"
    case .bool: return "boolean"
    case .number: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }
  func valid(depth: Int) -> Bool {
    guard depth <= 16 else { return false }
    switch self {
    case .object(let values): return values.values.allSatisfy { $0.valid(depth: depth + 1) }
    case .array(let values): return values.allSatisfy { $0.valid(depth: depth + 1) }
    case .number(let n): return n.isFinite && (n.rounded() != n || abs(n) <= 9_007_199_254_740_991)
    default: return true
    }
  }
}

public struct FieldHint: Codable, Equatable, Sendable {
  public enum ValueType: String, Codable, Sendable {
    case any, string, number, boolean, object, array
  }
  public var type: ValueType
  public var label: String?
}

public struct TypeDefinition: Codable, Equatable, Sendable {
  public enum Family: String, Codable, Sendable {
    case item, event, trigger, category, status, role
  }
  public var family: Family
  public var label: String?
  public var description: String?
  public var base: ItemKind?
  public var defaultStatus: String?
  public var fields: [String: FieldHint]?
  public var source: HostedFunction.Trigger?
}

public struct RegisteredType: Codable, Sendable {
  public let id: String
  public let revision: Int
  public let definition: TypeDefinition
}

extension TypeDefinition {
  func validate(id: String) throws {
    if family == .event && id == WorkOperation.defineType.rawValue {
      throw RelayError("defineType is reserved for declarations")
    }
    guard label.map(validName) ?? true, defaultStatus.map(validName) ?? true,
      (fields ?? [:]).allSatisfy({ validName($0.key) && ($0.value.label.map(validName) ?? true) }),
      family == .item || (base == nil && defaultStatus == nil),
      family == .item || family == .event || fields == nil,
      family == .trigger ? source != nil : source == nil
    else { throw RelayError("Invalid type definition") }
    if let base {
      guard ItemKind.allCases.contains(base),
        !ItemKind.allCases.contains(where: { $0.rawValue == id }) || id == base.rawValue
      else { throw RelayError("Invalid built-in base") }
    }
    guard let s = source else { return }
    guard !["event", "cron", "at"].contains(id), s.itemID.map(validName) ?? true else {
      throw RelayError("Invalid trigger name or target")
    }
    let valid: Bool
    switch s.kind {
    case "event":
      valid =
        s.operation.map(validName) == true && (0...31_622_400).contains(s.delaySeconds ?? 0)
        && s.expression == nil && s.timezone == nil && s.at == nil
    case "at":
      let iso = ISO8601DateFormatter()
      let at = s.at ?? ""
      let date = iso.date(from: at)
      iso.formatOptions.insert(.withFractionalSeconds)
      valid =
        (date ?? iso.date(from: at)) != nil && s.operation == nil && s.delaySeconds == nil
        && s.expression == nil && s.timezone == nil
    case "cron":
      valid =
        s.expression?.split(whereSeparator: { $0.isWhitespace }).count == 5
        && s.timezone.flatMap(TimeZone.init(identifier:)) != nil && s.operation == nil
        && s.delaySeconds == nil && s.at == nil
    default: valid = false
    }
    if !valid { throw RelayError("Invalid scheduling source") }
  }
}

func validName(_ s: String) -> Bool {
  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.utf8.count <= 160
}
func validateFields(_ fields: [String: JSONValue]?, hints: [String: FieldHint]?, patch: Bool) throws
{
  guard let fields else { return }
  let value = JSONValue.object(fields)
  guard fields.keys.allSatisfy(validName), value.valid(depth: 0),
    try Wire.encoder().encode(value).count <= 64 * 1024
  else { throw RelayError("Invalid fields, depth or size") }
  for (key, value) in fields {
    if let hint = hints?[key], hint.type != .any, !(patch && value == .null),
      hint.type.rawValue != value.typeName
    {
      throw RelayError("Field \(key) expects \(hint.type.rawValue)")
    }
  }
}

extension Workspace {
  public func typeRecord(_ family: TypeDefinition.Family, _ id: String) -> RegisteredType? {
    definitions?[family.rawValue + ":" + id]
  }

  public struct TypeCatalog: Encodable {
    public let items, events, triggers, statuses, roles, categories: [String]
    public let itemFields, eventFields: [String: [String]]
    public let definitions: [RegisteredType]
  }

  public func typeCatalog() -> TypeCatalog {
    let declared = (definitions ?? [:]).values.sorted {
      ($0.definition.family.rawValue, $0.id) < ($1.definition.family.rawValue, $1.id)
    }
    func names(_ family: TypeDefinition.Family, _ defaults: [String], _ used: [String] = [])
      -> [String]
    {
      Set(defaults + used + declared.filter { $0.definition.family == family }.map(\.id)).sorted()
    }
    var itemFields = [String: Set<String>]()
    var eventFields = [String: Set<String>]()
    var itemKinds = [String: String]()
    var roles = Set<String>()
    var statuses = Set<String>()
    var categories = Set<String>()
    for e in entries where e.change.operation != .defineType {
      let c = e.change
      if c.operation == .create { itemKinds[c.itemID] = c.kind?.rawValue }
      if c.operation == .promote { itemKinds[c.itemID] = ItemKind.requirement.rawValue }
      if let kind = itemKinds[c.itemID], let fields = c.fields {
        itemFields[kind, default: []].formUnion(fields.keys)
      }
      if let payload = c.payload {
        eventFields[c.operation.rawValue, default: []].formUnion(payload.keys)
      }
      roles.formUnion((c.members ?? []).map(\.role).filter { !$0.isEmpty })
      if let s = c.status { statuses.insert(s) }
      if let path = c.category, !path.isEmpty { categories.insert(path) }
    }
    statuses.formUnion(items.values.map(\.status))
    let events = names(
      .event, WorkOperation.allCases.filter { $0 != .defineType }.map(\.rawValue),
      entries.filter { $0.change.operation != .defineType }.map { $0.change.operation.rawValue })
    return TypeCatalog(
      items: names(
        .item, ItemKind.allCases.map(\.rawValue), entries.compactMap { $0.change.kind?.rawValue }),
      events: events, triggers: names(.trigger, ["event", "at", "cron"]),
      statuses: names(.status, Array(statuses)),
      roles: names(.role, Array(roles)), categories: names(.category, Array(categories)),
      itemFields: itemFields.mapValues { $0.sorted() },
      eventFields: eventFields.mapValues { $0.sorted() }, definitions: declared)
  }
}
