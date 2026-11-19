import XCTest

@testable import RelayCore

final class RequirementBoardTests: XCTestCase {
  // 23:59:59 in Shanghai. UTC is still the same day two seconds later.
  private let now = ISO8601DateFormatter().date(from: "2026-11-18T15:59:59Z")!
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }

  @discardableResult private func apply(
    _ state: inout Workspace, _ change: Change, at time: Date? = nil
  ) throws -> UUID {
    let event = Entry(
      id: UUID(), sequence: state.entries.count + 1, time: time ?? now,
      actor: "reporter", source: "test", session: nil, change: change)
    try state.apply(event)
    return event.id
  }

  private func create(_ id: String, _ kind: ItemKind, _ parent: String? = nil) -> Change {
    var c = Change(.create, id)
    c.kind = kind
    c.title = id
    c.parentID = parent
    if kind == .requirement {
      c.members = [Member("owner", "自由角色")]
      c.status = "联调中"
      c.start = now.addingTimeInterval(-86400)
      c.end = now.addingTimeInterval(86400)
    }
    return c
  }

  func testSignalsRollUpOnceAndClearImmediatelyOnTheirOwnItem() throws {
    var state = Workspace()
    for c in [
      create("d", .direction), create("r", .requirement, "d"), create("t", .task, "r"),
      create("a", .requirement, "d"), create("i", .idea),
    ] { try apply(&state, c) }
    var pause = Change(.pause, "t")
    pause.affectsRequirement = false
    pause.note = "本地调整"
    try apply(&state, pause)
    XCTAssertEqual(state.requirementBoard(at: now).map(\.phase), [.active, .active])
    var handoff = Change(.handoff, "t")
    handoff.recipient = "receiver"
    handoff.note = "验收失败重试"
    let id = try apply(&state, handoff)  // An existing journal need not have affectsRequirement.
    var rows = state.requirementBoard(at: now)
    XCTAssertEqual(rows.map(\.id), ["r", "a"])
    XCTAssertEqual(rows.first?.direction, "d")
    XCTAssertEqual(rows.first?.members.map(\.name), ["owner"])
    XCTAssertEqual(rows.first?.phase, .waiting)
    XCTAssertEqual(rows.first?.summary, "等receiver · 验收失败重试")
    XCTAssertEqual(rows.first?.attention?.id, id)
    var direct = Change(.pause, "r")
    direct.note = "确认字段"
    direct.recipient = "partner"
    try apply(&state, direct)
    XCTAssertEqual(state.requirementBoard(at: now).first?.phase, .blocked)
    try apply(&state, Change(.resume, "r"))
    XCTAssertEqual(state.requirementBoard(at: now).first?.attention?.id, id)
    var ack = Change(.acknowledge, "t")
    ack.reference = id
    ack.note = "验收通过"
    try apply(&state, ack)
    rows = state.requirementBoard(at: now)
    XCTAssertEqual(rows.map(\.id), ["a", "r"])
    XCTAssertTrue(rows.allSatisfy { $0.phase == .active })
    XCTAssertEqual(state.outstandingWork(for: try XCTUnwrap(state.items["t"])).count, 1)
  }

  func testPersonalScopeKeepsParentsAndDropsAnsweredRequests() throws {
    var state = Workspace()
    var idea = create("idea", .idea)
    idea.members = [Member("River", "调研")]
    for change in [
      create("d", .direction), create("r", .requirement, "d"),
      create("other", .requirement, "d"), create("t", .task, "r"), idea,
    ] {
      try apply(&state, change)
    }
    var handoff = Change(.handoff, "t")
    handoff.affectsRequirement = false
    handoff.recipient = "River"
    handoff.note = "请确认样例"
    let request = try apply(&state, handoff)
    XCTAssertEqual(state.itemIDs(relatedTo: "River"), ["d", "r", "t", "idea"])
    XCTAssertEqual(state.itemIDs(relatedTo: "owner"), ["d", "r", "other"])
    XCTAssertTrue(state.itemIDs(relatedTo: "").isEmpty)
    var reply = Change(.acknowledge, "t")
    reply.reference = request
    reply.note = "已确认"
    try apply(&state, reply)
    XCTAssertEqual(state.itemIDs(relatedTo: "River"), ["idea"])
  }

  func testCloseUsesLocalCalendarDayAndRealOutcomeAndCanReopen() throws {
    var state = Workspace()
    try apply(&state, create("d", .direction))
    try apply(&state, create("r", .requirement, "d"))
    try apply(&state, create("z", .requirement, "d"))
    var close = Change(.close, "r")
    close.note = "支持失败重试，已上线"
    try apply(&state, close)
    let before = state.requirementBoard(at: now, calendar: calendar)
    XCTAssertEqual(before.map(\.id), ["z", "r"])
    XCTAssertEqual(before.last?.phase, .completedToday)
    XCTAssertEqual(before.last?.summary, close.note)
    let tomorrow = now.addingTimeInterval(2)
    XCTAssertEqual(state.requirementBoard(at: tomorrow, calendar: calendar).map(\.id), ["z"])
    var utc = calendar
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    XCTAssertEqual(state.requirementBoard(at: tomorrow, calendar: utc).last?.id, "r")
    var detail = Change(.update, "r")
    detail.note = "补充发布记录"
    try apply(&state, detail, at: tomorrow)
    try apply(&state, close, at: tomorrow)
    XCTAssertEqual(state.requirementBoard(at: tomorrow, calendar: calendar).map(\.id), ["z"])
    XCTAssertEqual(state.items["r"]?.completion(in: state.history("r"))?.date, now)
    try apply(&state, Change(.resume, "r"), at: tomorrow)
    XCTAssertEqual(state.requirementBoard(at: tomorrow, calendar: calendar).first?.phase, .active)
    try apply(&state, close, at: tomorrow)
    XCTAssertEqual(
      state.requirementBoard(at: tomorrow, calendar: calendar).last?.completedAt, tomorrow)
  }

  func testFuturePlanAndHistoricalClosureWithoutOutcome() throws {
    var state = Workspace()
    try apply(&state, create("d", .direction))
    var future = create("r", .requirement, "d")
    future.status = "自由文本状态"
    future.start = now.addingTimeInterval(86400)
    try apply(&state, future)
    XCTAssertTrue(state.requirementBoard(at: now, calendar: calendar).isEmpty)
    var progress = Change(.update, "r")
    progress.note = "已提前联调"
    try apply(&state, progress)
    XCTAssertEqual(
      state.requirementBoard(at: now, calendar: calendar).first?.summary,
      "自由文本状态 · 已提前联调")
    try apply(&state, Change(.close, "r"))
    XCTAssertEqual(state.requirementBoard(at: now, calendar: calendar).last?.summary, "完成内容待补录")
  }
}
