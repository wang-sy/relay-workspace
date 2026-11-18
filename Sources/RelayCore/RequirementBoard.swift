import Foundation

/// One requirement on the team's board. The attention event retains the source task and recipient.
public struct RequirementRow: Encodable, Identifiable, Sendable {
  public enum Phase: String, Encodable, Sendable {
    case blocked, waiting, active, completedToday

    fileprivate var rank: Int {
      switch self {
      case .blocked, .waiting: return 0
      case .active: return 1
      case .completedToday: return 2
      }
    }
  }

  public let id: String
  public let title: String
  public let direction: String?
  public let members: [Member]
  public let phase: Phase
  public let summary: String
  public let attention: Entry?
  public let completedAt: Date?
}

extension Workspace {
  public func requirementBoard(at now: Date = .now, calendar: Calendar = .autoupdatingCurrent)
    -> [RequirementRow]
  {
    let index = RequirementIndex(self)
    return items.values.filter { $0.kind == .requirement }.compactMap { item in
      index.row(
        for: item, direction: item.parentID.flatMap { items[$0]?.title },
        now: now, calendar: calendar)
    }.sorted { a, b in
      if a.phase.rank != b.phase.rank { return a.phase.rank < b.phase.rank }
      if let x = a.attention, let y = b.attention, x.time != y.time { return x.time < y.time }
      if let x = a.completedAt, let y = b.completedAt, x != y { return x > y }
      return (a.title, a.id) < (b.title, b.id)
    }
  }

  /// Used by a requirement's drill-down as well as the board, including same-day handoffs.
  public func outstandingWork(for item: Item) -> [Entry] {
    RequirementIndex(self).pending(for: item)
  }
}

private struct RequirementIndex {
  let events: [String: [Entry]]
  let tasks: [String: [Item]]

  init(_ workspace: Workspace) {
    events = Dictionary(grouping: workspace.entries, by: { $0.change.itemID })
    tasks = Dictionary(
      grouping: workspace.items.values.filter { $0.kind == .task },
      by: { $0.parentID ?? "" })
  }

  func pending(for item: Item) -> [Entry] {
    guard !item.closed else { return [] }
    let sources = [item] + (tasks[item.id] ?? [])
    var pending = [Entry]()
    for source in sources where !source.closed {
      var acknowledged = Set<UUID>()
      for entry in (events[source.id] ?? []).reversed() {
        let change = entry.change
        // Closing the item ends its previous handoff cycle, even when it subsequently reopens.
        if change.operation == .close { break }
        if change.operation == .acknowledge, let ref = change.reference {
          acknowledged.insert(ref)
        }
        if source.id != item.id && change.affectsRequirement == false { continue }
        if (change.operation == .handoff && !acknowledged.contains(entry.id))
          || (change.operation == .pause && source.pauseID == entry.id)
        {
          pending.append(entry)
        }
      }
    }
    func priority(_ entry: Entry) -> Int {
      if entry.change.itemID == item.id { return 0 }
      return entry.change.affectsRequirement == true ? 1 : 2
    }
    return pending.sorted { a, b in
      // Prefer a directly reported dependency, then an explicitly flagged task. Within each
      // group show a named dependency first, then the one that has waited longest.
      let left = (
        priority(a), clean(a.change.recipient) == nil ? 1 : 0, a.time, a.sequence, a.id.uuidString
      )
      let right = (
        priority(b), clean(b.change.recipient) == nil ? 1 : 0, b.time, b.sequence, b.id.uuidString
      )
      return left < right
    }
  }

  func row(for item: Item, direction: String?, now: Date, calendar: Calendar) -> RequirementRow? {
    let history = events[item.id] ?? []
    func row(
      _ phase: RequirementRow.Phase, _ summary: String,
      attention: Entry? = nil, completedAt: Date? = nil
    ) -> RequirementRow {
      RequirementRow(
        id: item.id, title: item.title, direction: direction, members: item.members,
        phase: phase, summary: summary, attention: attention, completedAt: completedAt)
    }

    if item.closed {
      guard let completion = item.completion(in: history),
        calendar.isDate(completion.date, inSameDayAs: now)
      else { return nil }
      return row(.completedToday, completion.note ?? "完成内容待补录", completedAt: completion.date)
    }

    if let entry = pending(for: item).first {
      let c = entry.change
      let phase: RequirementRow.Phase = c.operation == .handoff ? .waiting : .blocked
      let recipient = clean(c.recipient).map { $0 == "*" ? "全体成员" : $0 }
      let note = clean(c.note) ?? "卡点原因待补录"
      let summary = [recipient.map { "等" + $0 }, note].compactMap { $0 }.joined(separator: " · ")
      return row(phase, summary, attention: entry)
    }

    if let start = item.start,
      calendar.compare(start, to: now, toGranularity: .day) == .orderedDescending
    {
      let hasStarted = ([item] + (tasks[item.id] ?? [])).contains { source in
        (events[source.id] ?? []).contains {
          [.resume, .result, .acknowledge, .handoff, .pause].contains($0.change.operation)
            || ($0.change.operation == .update && clean($0.change.note) != nil)
        }
      }
      if !hasStarted { return nil }
    }

    let resolved = Set(
      history.compactMap { $0.change.operation == .result ? $0.change.reference : nil })
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
    let milestone = history.filter {
      $0.change.operation == .milestone && !resolved.contains($0.id)
        && ($0.change.due ?? .distantFuture) < weekEnd
    }.min { ($0.change.due ?? .distantFuture) < ($1.change.due ?? .distantFuture) }
    let progress: String?
    if let milestone, let due = milestone.change.due, let note = clean(milestone.change.note) {
      let day = "\(calendar.component(.month, from: due))/\(calendar.component(.day, from: due))"
      progress = due < now ? "\(day) 待记录结果 · \(note)" : "\(day) \(note)"
    } else {
      let latest = history.last {
        [.create, .promote, .resume, .update, .result, .acknowledge].contains($0.change.operation)
          && [clean($0.change.note), clean($0.change.next), clean($0.change.status)].contains {
            $0 != nil
          }
      }
      progress = clean(latest?.change.note) ?? clean(item.next)
    }
    let summary = [item.status, progress == item.status ? nil : progress].compactMap { $0 }
      .joined(separator: " · ")
    return row(.active, summary)
  }

}
extension Item {
  public func completion(in history: [Entry]) -> (date: Date, note: String?)? {
    guard closed else { return nil }
    // Later edits and repeated reports may clarify the outcome without moving the closure date.
    var closedAt: Date?
    var outcome: String?
    for entry in history.reversed() where entry.change.itemID == id {
      if [.resume, .pause].contains(entry.change.operation) { break }
      if entry.change.operation == .close {
        closedAt = entry.time
        if outcome == nil { outcome = clean(entry.change.note) }
      }
    }
    return closedAt.map { ($0, outcome) }
  }
}

private func clean(_ text: String?) -> String? {
  let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
  return value?.isEmpty == false ? value : nil
}
