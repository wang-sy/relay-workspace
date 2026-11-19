import RelayCore
import SwiftUI

struct RequirementCards: View {
  let state: Workspace
  let requirements: [Item]
  let width: CGFloat
  @Environment(\.calendar) private var calendar
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var historyExpanded = false

  var body: some View {
    // A completion rolls into history at local midnight even with an unchanged HTTP snapshot.
    TimelineView(.everyMinute) { clock in
      let rows = Dictionary(
        uniqueKeysWithValues: state.requirementBoard(at: clock.date, calendar: calendar).map {
          ($0.id, $0)
        })
      let groups = lanes(rows)
      let today = requirements.filter { rows[$0.id]?.phase == .completedToday }
      let history = requirements.filter { $0.closed && rows[$0.id] == nil }
      VStack(alignment: .leading, spacing: 16) {
        if !groups.isEmpty {
          let count = typeSize.isAccessibilitySize ? 1 : max(1, min(4, Int((width + 14) / 295)))
          let columns = Array(
            repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
            count: min(groups.count, count))
          LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(groups) { lane in
              VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                  Circle().fill(lane.tone).frame(width: 8, height: 8).accessibilityHidden(true)
                  Text(state.label(.status, lane.status)).font(.headline).accessibilityAddTraits(
                    .isHeader)
                  Spacer()
                  Text("\(lane.items.count)").font(.caption.monospacedDigit()).foregroundStyle(
                    RelayPalette.muted
                  )
                  .accessibilityLabel("\(lane.items.count) 个需求")
                }.padding(.horizontal, 3).padding(.vertical, 4)
                ForEach(lane.items) { item in
                  card(item, row: rows[item.id])
                }
              }
              .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
              .background(RelayPalette.wash, in: RoundedRectangle(cornerRadius: 13))
            }
          }
        }
        if !today.isEmpty {
          RelayPanel(spacing: 8) {
            Label("今日完成", systemImage: "checkmark.circle").font(.headline)
              .foregroundStyle(RelayPalette.teal).accessibilityAddTraits(.isHeader)
            ForEach(today) { item in
              NavigationLink(value: item.id) {
                ViewThatFits(in: .horizontal) {
                  HStack(spacing: 10) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    Text(rows[item.id]?.summary ?? "").font(.subheadline).foregroundStyle(
                      RelayPalette.secondary)
                  }.fixedSize(horizontal: true, vertical: false)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    Text(rows[item.id]?.summary ?? "").font(.subheadline).foregroundStyle(
                      RelayPalette.secondary)
                  }
                }.padding(.vertical, 3)
              }.buttonStyle(RelayRowStyle())
            }
          }
        }
        if !history.isEmpty {
          DisclosureGroup("以往完成（\(history.count)）", isExpanded: $historyExpanded) {
            ForEach(history) { item in ItemLink(item: item) }
          }.font(.subheadline)
        }
      }
    }
  }

  private struct Lane: Identifiable {
    let status: String
    let items: [Item]
    let rank: Int
    var id: String { status }
    var tone: Color {
      rank == 0 ? RelayPalette.amber : (rank == 1 ? RelayPalette.accent : RelayPalette.blue)
    }
  }

  private func lanes(_ rows: [String: RequirementRow]) -> [Lane] {
    func order(_ item: Item) -> (Int, Date, String, String) {
      let row = rows[item.id]
      let rank = row?.phase == .blocked ? 0 : (row?.phase == .waiting ? 1 : 2)
      return (rank, row?.attention?.time ?? .distantFuture, item.title, item.id)
    }
    return Dictionary(grouping: requirements.filter { !$0.closed }, by: \.status).map {
      status, items in
      let sorted = items.sorted { order($0) < order($1) }
      return Lane(status: status, items: sorted, rank: sorted.first.map { order($0).0 } ?? 2)
    }.sorted { ($0.rank, $0.status) < ($1.rank, $1.status) }
  }

  private func card(_ item: Item, row: RequirementRow?) -> some View {
    NavigationLink(value: item.id) {
      VStack(alignment: .leading, spacing: 8) {
        if let direction = item.parentID.flatMap({ state.items[$0]?.title }) {
          Text(direction).font(.caption).foregroundStyle(RelayPalette.secondary)
        }
        Text(item.title).font(.headline).foregroundStyle(RelayPalette.primary)
          .fixedSize(horizontal: false, vertical: true)
        if !ItemKind.allCases.contains(item.kind) {
          Text(state.label(.item, item.kind.rawValue)).font(.caption).foregroundStyle(
            RelayPalette.secondary)
        }
        if let attention = row?.attention {
          let waiting = attention.change.operation == .handoff
          let recipient = attention.change.recipient.map { $0 == "*" ? "全体成员" : $0 }
          let label =
            waiting
            ? (recipient.map { "等 \($0) 接手" } ?? "等接手")
            : ("卡住" + (recipient.map { " · 等 \($0)" } ?? " · 等待对象待补"))
          Label(label, systemImage: waiting ? "person.crop.circle.badge.clock" : "pause.circle")
            .font(.subheadline.weight(.semibold)).foregroundStyle(
              waiting ? RelayPalette.accent : RelayPalette.amber)
          if let note = attention.change.note {
            Text(note).font(.callout).foregroundStyle(RelayPalette.secondary)
          }
        } else {
          if row == nil, let start = item.start {
            Label("\(RelayDate.short(start)) 开始", systemImage: "calendar").font(.caption)
              .foregroundStyle(RelayPalette.blue)
          }
          let prefix = item.status + " · "
          let summary = row?.summary ?? item.next ?? ""
          let detail = summary.hasPrefix(prefix) ? String(summary.dropFirst(prefix.count)) : summary
          if !detail.isEmpty && detail != item.status {
            Text(detail).font(.callout).foregroundStyle(RelayPalette.secondary)
          }
        }
        let members = item.members.map(\.name).joined(separator: "、")
        Label(members.isEmpty ? "未署名" : members, systemImage: "person")
          .font(.caption).foregroundStyle(RelayPalette.secondary).padding(.top, 2)
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(13)
      .background(RelayPalette.surface, in: RoundedRectangle(cornerRadius: 9))
      .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(RelayPalette.line, lineWidth: 0.8) }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
