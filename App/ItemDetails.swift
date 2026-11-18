import RelayCore
import SwiftUI

struct ItemDetails: View {
  @EnvironmentObject private var model: WorkspaceModel
  @Environment(\.dynamicTypeSize) private var typeSize
  let item: Item
  let edit: (EditTarget) -> Void

  var body: some View {
    let state = model.state
    let events = state.history(item.id)
    let pending = state.outstandingWork(for: item)
    let pendingIDs = Set(pending.map(\.id))
    let gaps = state.gaps().filter { $0.itemID == item.id && !pendingIDs.contains($0.id) }
    RelayPage { width in
      VStack(alignment: .leading, spacing: 8) {
        if let parentID = item.parentID, let parent = state.items[parentID] {
          NavigationLink(value: parentID) {
            Label(parent.title, systemImage: parent.kind.icon)
              .font(.subheadline).foregroundStyle(RelayPalette.accent)
          }.buttonStyle(.plain)
        }
        Text(item.title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
        HStack(spacing: 7) {
          Text(item.kind.label).font(.subheadline).foregroundStyle(RelayPalette.secondary)
          StatusLabel(text: item.closed ? "已完成" : item.status, tone: item.kind.tone)
          if let category = item.category, !category.isEmpty {
            Text(category).font(.subheadline).foregroundStyle(RelayPalette.secondary)
          }
        }
      }
      if let completion = item.completion(in: events) {
        RelayPanel(spacing: 6) {
          PanelTitle("完成结果")
          Text(completion.note ?? "完成内容待补录")
          Text(RelayDate.long(completion.date)).font(.caption).foregroundStyle(
            RelayPalette.secondary)
        }
      }
      if !pending.isEmpty || !gaps.isEmpty {
        RelayPanel(spacing: 10) {
          PanelTitle("需要回看")
          ForEach(pending) { entry in
            if let source = state.items[entry.change.itemID] {
              if entry.id != pending.first?.id { Hairline() }
              VStack(alignment: .leading, spacing: 6) {
                if source.id != item.id {
                  NavigationLink(value: source.id) {
                    Label(source.title, systemImage: source.kind.icon)
                  }.buttonStyle(.plain).foregroundStyle(RelayPalette.accent)
                }
                let who = entry.change.recipient.map { $0 == "*" ? "全体成员" : $0 }
                Text(
                  [
                    entry.change.operation == .pause ? "卡住" : "等接手", who.map { "等" + $0 },
                    entry.change.note,
                  ].compactMap { $0 }.joined(separator: " · "))
                gapAction(entry, on: source)
              }
            }
          }
          ForEach(gaps) { gap in
            if !pending.isEmpty || gap.id != gaps.first?.id { Hairline() }
            let entry = events.first { $0.id == gap.id }
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 12) {
                gapNote(gap, entry: entry)
                Spacer(minLength: 12)
                gapAction(entry, on: item)
              }
              VStack(alignment: .leading, spacing: 10) {
                gapNote(gap, entry: entry)
                gapAction(entry, on: item)
              }
            }
          }
        }
      }
      if width >= 740 && !typeSize.isAccessibilitySize {
        HStack(alignment: .top, spacing: 16) {
          historyAndChildren(state: state, events: events)
          facts.frame(width: min(width * 0.33, 330))
        }
      } else {
        facts
        historyAndChildren(state: state, events: events)
      }
    }
    .navigationTitle(item.kind.label + "详情")
    .toolbar {
      Menu {
        Button("披露进展") { edit(EditTarget(item, .update)) }
        Button("约定回看") { edit(EditTarget(item, .remind)) }
        if item.kind == .idea { Button("纳入需求排期") { edit(EditTarget(item, .promote)) } }
        if item.kind == .direction {
          Button("新增需求") { edit(EditTarget(item, .create, .requirement)) }
        }
        if item.kind == .requirement { Button("拆出任务") { edit(EditTarget(item, .create, .task)) } }
      } label: {
        Label("事项操作", systemImage: "ellipsis.circle")
      }
    }
  }

  private func gapNote(_ gap: Gap, entry: Entry?) -> some View {
    HStack(alignment: .top, spacing: 10) {
      SymbolTile(symbol: "clock", tone: RelayPalette.amber)
      VStack(alignment: .leading, spacing: 4) {
        Text(gap.label).font(.headline)
        if !gap.reason.isEmpty && gap.reason != item.title {
          Text(gap.reason).font(.callout).foregroundStyle(RelayPalette.secondary)
        }
        if let entry {
          let due = entry.change.due ?? item.end ?? entry.time
          Text(entry.actor + " · " + RelayDate.short(due)).font(.caption)
            .foregroundStyle(RelayPalette.secondary)
        }
      }
    }.fixedSize(horizontal: false, vertical: true)
  }

  private func gapAction(_ entry: Entry?, on source: Item) -> some View {
    let op: WorkOperation
    switch entry?.change.operation {
    case .handoff: op = .acknowledge
    case .milestone: op = .result
    case .pause: op = .remind
    default: op = .update
    }
    return Button(op.label) {
      edit(
        EditTarget(source, op, reference: [.result, .acknowledge].contains(op) ? entry?.id : nil))
    }.buttonStyle(.bordered).fixedSize()
  }

  private var facts: some View {
    RelayPanel(spacing: 12) {
      PanelTitle("事项信息")
      if let next = item.next, !next.isEmpty {
        fact("下一步", value: next)
      }
      if let start = item.start, let end = item.end {
        fact("计划周期", value: "\(RelayDate.short(start)) – \(RelayDate.short(end))")
      }
      if !item.members.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("参与成员").font(.caption.weight(.medium)).foregroundStyle(RelayPalette.muted)
          ForEach(item.members, id: \.name) { member in
            HStack(spacing: 8) {
              MemberMark(name: member.name, size: 25)
              Text(member.name).font(.subheadline.weight(.semibold))
              if !member.role.isEmpty {
                Text(member.role).font(.subheadline).foregroundStyle(RelayPalette.secondary)
              }
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("事项 ID").font(.caption.weight(.medium)).foregroundStyle(RelayPalette.muted)
        Text(item.id).font(.caption.monospaced()).foregroundStyle(RelayPalette.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private func fact(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption.weight(.medium)).foregroundStyle(RelayPalette.muted)
      Text(value).font(.callout)
    }
  }

  private func historyAndChildren(state: Workspace, events: [Entry]) -> some View {
    let children = state.children(of: item.id)
    let milestones = events.filter { $0.change.operation == .milestone }.sorted {
      ($0.change.due ?? .distantFuture) < ($1.change.due ?? .distantFuture)
    }
    return VStack(alignment: .leading, spacing: 16) {
      if !children.isEmpty {
        RelayPanel(spacing: 3) {
          PanelTitle("下级事项").padding(.bottom, 4)
          ForEach(children) { child in
            if child.id != children.first?.id { Hairline() }
            ItemLink(item: child)
          }
        }
      }
      if !milestones.isEmpty {
        RelayPanel {
          PanelTitle("计划节点")
          ForEach(milestones) { e in
            HStack(alignment: .top, spacing: 8) {
              let done = state.resolved(e.id)
              Image(systemName: done ? "checkmark.circle.fill" : "diamond")
                .foregroundStyle(done ? RelayPalette.teal : RelayPalette.accent)
                .accessibilityLabel(done ? "已记录结果" : "待记录结果")
              VStack(alignment: .leading, spacing: 3) {
                Text(e.change.note ?? "").font(.subheadline.weight(.semibold))
                if let due = e.change.due {
                  Text(RelayDate.long(due)).font(.caption).foregroundStyle(RelayPalette.secondary)
                }
              }
            }
          }
        }
      }
      RelayPanel(spacing: 6) {
        PanelTitle("工作记录").padding(.bottom, 4)
        ForEach(events.reversed()) { e in
          if e.id != events.last?.id { Hairline() }
          HStack(alignment: .top, spacing: 10) {
            MemberMark(name: e.actor)
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 5) {
                Text(e.actor).font(.subheadline.weight(.semibold))
                Text(e.change.operation.label).font(.subheadline).foregroundStyle(
                  RelayPalette.secondary)
                if let recipient = e.change.recipient {
                  Text("→ \(recipient)").font(.subheadline.weight(.semibold))
                }
              }
              if let note = e.change.note { Text(note).font(.callout) }
              Text(
                [e.time.formatted(date: .abbreviated, time: .shortened), e.source, e.session]
                  .compactMap { $0 }.joined(separator: " · ")
              )
              .font(.caption).foregroundStyle(RelayPalette.muted).textSelection(.enabled)
            }
          }.padding(.vertical, 5).accessibilityElement(children: .combine)
        }
      }
    }
  }
}
