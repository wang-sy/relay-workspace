import RelayCore
import SwiftUI

struct Editor: View {
  @EnvironmentObject var model: WorkspaceModel
  @Environment(\.dismiss) var dismiss
  let target: EditTarget
  @State private var operation: WorkOperation
  @State private var kind: ItemKind
  @State private var parent = ""
  @State private var title = ""
  @State private var status: String
  @State private var note = ""
  @State private var next: String
  @State private var category: String
  @State private var member = ""
  @State private var role = ""
  @State private var recipient = ""
  @State private var start: Date
  @State private var end: Date
  @State private var due = Date().addingTimeInterval(3 * 86400)
  @State private var conditional = false
  @State private var reference: UUID?
  @State private var error: String?
  @State private var saving = false
  @State private var itemID = UUID().uuidString.lowercased()
  @State private var requestID = UUID()
  init(target: EditTarget) {
    self.target = target
    _operation = State(initialValue: target.operation)
    _kind = State(initialValue: target.kind)
    _reference = State(initialValue: target.reference)
    let existing = target.operation == .create ? nil : target.item
    _status = State(initialValue: existing?.status ?? "待推进")
    _next = State(initialValue: existing?.next ?? "")
    _category = State(initialValue: existing?.category ?? "")
    _start = State(initialValue: existing?.start ?? Date())
    _end = State(initialValue: existing?.end ?? Date().addingTimeInterval(7 * 86400))
  }
  private var candidates: [Item] {
    let expected: ItemKind = kind == .task && operation == .create ? .requirement : .direction
    return model.state.items.values.filter { $0.kind == expected }.sorted { $0.title < $1.title }
  }
  private var references: [Entry] {
    guard let item = target.item else { return [] }
    let expected: WorkOperation = operation == .result ? .milestone : .handoff
    return model.state.history(item.id).filter {
      $0.change.operation == expected && !model.state.resolved($0.id)
    }
  }
  var body: some View {
    NavigationStack {
      Form {
        if operation == .create {
          Picker("类型", selection: $kind) {
            ForEach(ItemKind.allCases, id: \.self) {
              Text($0 == .idea ? "探索 / 待办" : $0.label).tag($0)
            }
          }
          TextField("事项标题", text: $title)
        } else if let item = target.item {
          LabeledContent("事项", value: item.title)
          if [.update, .pause, .resume, .close, .milestone, .result, .handoff, .acknowledge]
            .contains(operation)
          {
            Picker("发生了什么", selection: $operation) {
              ForEach(
                [
                  WorkOperation.update, .pause, .resume, .milestone, .result, .handoff,
                  .acknowledge,
                  .close,
                ], id: \.self
              ) { Text($0.label).tag($0) }
            }
          }
        }
        if operation == .promote || operation == .create && kind != .direction {
          Picker("上级事项", selection: $parent) {
            Text(kind == .idea && operation == .create ? "暂不关联" : "选择上级").tag("")
            ForEach(candidates) { Text($0.title).tag($0.id) }
          }
        }
        if operation != .remind {
          TextField("状态（可自由填写）", text: $status)
          if kind == .idea || target.item?.kind == .idea { TextField("分类路径", text: $category) }
          TextField("下一步", text: $next)
          TextField("新增或更新参与成员", text: $member)
          if !member.isEmpty { TextField("此人在本事项中的角色", text: $role) }
        }
        if operation == .promote || operation == .create && kind == .requirement
          || operation == .update && target.item?.kind == .requirement
        {
          DatePicker("计划开始", selection: $start, displayedComponents: .date)
          DatePicker("计划结束", selection: $end, displayedComponents: .date)
        }
        if [.milestone, .remind].contains(operation) { DatePicker("约定时间", selection: $due) }
        if [.handoff, .remind].contains(operation) { TextField("接收成员（* 表示全体）", text: $recipient) }
        if operation == .remind && target.item?.pauseID != nil {
          Toggle("届时仍是这次暂停才提醒", isOn: $conditional)
        }
        if [.acknowledge, .result].contains(operation) {
          Picker("关联原始记录", selection: $reference) {
            Text("请选择").tag(nil as UUID?)
            ForEach(references) { e in Text(e.change.note ?? e.id.uuidString).tag(Optional(e.id)) }
          }
        }
        TextField(operation == .remind ? "到时提醒什么" : "记录内容", text: $note, axis: .vertical).lineLimit(
          2...5)
        if let error { Text(error).foregroundStyle(.red) }
      }.formStyle(.grouped)
        .navigationTitle(operation.label)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { Task { await save() } }.disabled(saving)
          }
        }
    }
    #if os(macOS)
      .frame(minWidth: 480, minHeight: 450)
    #endif
    .onAppear {
      parent = target.operation == .create ? target.item?.id ?? "" : target.item?.parentID ?? ""
      recipient = model.currentActor
      conditional = target.item?.pauseID != nil
    }
    .onChange(of: kind) { _, _ in
      parent = candidates.contains(where: { $0.id == parent }) ? parent : ""
    }
    .onChange(of: operation) { _, _ in reference = nil }
  }
  @MainActor private func save() async {
    saving = true
    defer { saving = false }
    var c = Change(operation, operation == .create ? itemID : target.item?.id ?? "")
    if operation == .create {
      c.kind = kind
      c.title = title
    }
    if operation == .create || operation == .promote { c.parentID = parent.isEmpty ? nil : parent }
    c.note = note.isEmpty ? nil : note
    if operation != .remind {
      c.status = status
      c.next = next
      c.category = category.isEmpty ? nil : category
      if !member.isEmpty { c.members = [Member(member, role)] }
    }
    if operation == .promote || operation == .create && kind == .requirement
      || operation == .update && target.item?.kind == .requirement
    {
      c.start = start
      c.end = end
    }
    if [.remind, .milestone].contains(operation) { c.due = due }
    if [.remind, .handoff].contains(operation) { c.recipient = recipient }
    if operation == .remind && conditional { c.reference = target.item?.pauseID }
    if [.result, .acknowledge].contains(operation) { c.reference = reference }
    do {
      try await model.submit(c, id: requestID)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
