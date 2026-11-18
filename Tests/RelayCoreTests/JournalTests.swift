import XCTest

@testable import RelayCore

final class JournalTests: XCTestCase {
  func testPauseIsIndependentOfFreeTextAndRecipient() throws {
    let now = Date()
    var state = Workspace()
    for e in Example.entries(at: now) { try state.apply(e) }
    XCTAssertEqual(state.gaps(at: now).count, 3)
    let pause = try XCTUnwrap(state.items["TASK-01"]?.pauseID)
    var reminder = Change(.remind, "TASK-01")
    reminder.reference = pause
    reminder.due = now.addingTimeInterval(3 * 86400)
    reminder.recipient = "River"
    reminder.note = "回看许可"
    let entry = Entry(
      id: UUID(), sequence: 100, time: now, actor: "River", source: "test", session: nil,
      change: reminder)
    try state.apply(entry)
    XCTAssertTrue(state.reminderIsCurrent(entry))
    XCTAssertEqual(state.gaps(at: now).count, 2)
    var update = Change(.resume, "TASK-01")
    update.status = "准备拉取新样本"
    try state.apply(
      Entry(
        id: UUID(), sequence: 101, time: now, actor: "another-member", source: "test", session: nil,
        change: update))
    XCTAssertFalse(state.reminderIsCurrent(entry))
    XCTAssertEqual(state.items["TASK-01"]?.status, update.status)
  }

  func testRetryAndInvalidParentLeaveNoPartialWrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = Journal(root)
    let id = UUID()
    var valid = Change(.create, "d")
    valid.kind = .direction
    valid.title = "Begin"
    _ = try journal.append(valid, id: id, actor: "a", source: "test")
    _ = try journal.append(valid, id: id, actor: "a", source: "test")
    var different = valid
    different.title = "Changed"
    XCTAssertThrowsError(try journal.append(different, id: id, actor: "a", source: "test"))
    var invalid = Change(.create, "t")
    invalid.kind = .task
    invalid.title = "Bad parent"
    invalid.parentID = "d"
    XCTAssertThrowsError(try journal.append(invalid, actor: "a", source: "test"))
    XCTAssertEqual(try journal.read().entries.count, 1)
  }

  func testPromotionKeepsHistoryAndRolesFollowTheItem() throws {
    var state = Workspace()
    for e in Example.entries(at: Date()) { try state.apply(e) }
    var c = Change(.promote, "IDEA-01")
    c.parentID = "DIR-01"
    c.start = Date()
    c.end = Date().addingTimeInterval(86400)
    c.members = [Member("Jun", "采访")]
    try state.apply(
      Entry(
        id: UUID(), sequence: 100, time: Date(), actor: "Mira", source: "test", session: nil,
        change: c))
    XCTAssertEqual(state.items["IDEA-01"]?.kind, .requirement)
    XCTAssertEqual(state.items["IDEA-01"]?.members.first?.role, "采访")
    XCTAssertEqual(state.history("IDEA-01").count, 2)
    let later = Date().addingTimeInterval(4 * 86400)
    XCTAssertTrue(
      state.gaps(at: later).contains { $0.itemID == "IDEA-01" && $0.label == "计划结束日已过" })

  }
}
