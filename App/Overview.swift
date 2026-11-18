import RelayCore
import SwiftUI

enum OverviewList: Hashable {
  case followUps, activity
}

struct Overview: View {
  @Environment(\.dynamicTypeSize) private var typeSize
  let state: Workspace
  let items: [Item]

  var body: some View {
    let now = Date.now
    let gaps = state.gaps(at: now)
    let latest = state.entries.sorted { ($0.time, $0.sequence) > ($1.time, $1.sequence) }
    let requirements = items.filter { $0.kind == .requirement }.sorted {
      ($0.start ?? .distantFuture, $0.title, $0.id) < ($1.start ?? .distantFuture, $1.title, $1.id)
    }
    RelayPage { width in
      OverviewBrief(
        items: items, entries: latest, gapCount: Set(gaps.map(\.itemID)).count,
        now: now, width: width)
      if width >= 710 && !typeSize.isAccessibilitySize {
        HStack(alignment: .top, spacing: 16) {
          followUps(gaps, state: state)
            .frame(width: (width - 16) * 0.55)
          activity(latest, state: state)
        }
        RequirementSchedule(items: requirements, entries: state.entries, width: width, today: now)
      } else {
        followUps(gaps, state: state)
        RequirementSchedule(items: requirements, entries: state.entries, width: width, today: now)
        activity(latest, state: state)
      }
    }
  }

  private func followUps(_ gaps: [Gap], state: Workspace) -> some View {
    let byID = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.id, $0) })
    return RelayPanel(spacing: 3) {
      HStack {
        PanelTitle("跟进清单")
        Spacer()
        if gaps.count > 3 { allLink(.followUps, label: "全部 \(gaps.count) 条") }
      }.padding(.bottom, 5)
      if gaps.isEmpty { QuietMessage(symbol: "checkmark.circle", text: "目前没有需要回看的事项") }
      ForEach(gaps.prefix(3)) { gap in
        if gap.id != gaps.first?.id { Hairline() }
        if let item = state.items[gap.itemID] {
          NavigationLink(value: item.id) {
            FollowUpRow(gap: gap, item: item, entry: byID[gap.id])
          }.buttonStyle(RelayRowStyle())
        }
      }
    }
  }

  private func activity(_ entries: [Entry], state: Workspace) -> some View {
    RelayPanel(spacing: 3) {
      HStack {
        PanelTitle("团队动态")
        Spacer()
        if entries.count > 3 { allLink(.activity, label: "查看全部") }
      }.padding(.bottom, 5)
      if entries.isEmpty { QuietMessage(symbol: "text.bubble", text: "还没有工作记录") }
      ForEach(entries.prefix(3)) { e in
        if e.id != entries.first?.id { Hairline() }
        NavigationLink(value: e.change.itemID) {
          ActivityRow(entry: e, item: state.items[e.change.itemID])
        }.buttonStyle(RelayRowStyle())
      }
    }
  }

  private func allLink(_ value: OverviewList, label: String) -> some View {
    NavigationLink(value: value) {
      HStack(spacing: 3) {
        Text(label)
        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
      }.font(.caption.weight(.medium)).foregroundStyle(RelayPalette.accent)
        .padding(.vertical, 4).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

private struct OverviewBrief: View {
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 46
  let items: [Item]
  let entries: [Entry]
  let gapCount: Int
  let now: Date
  let width: CGFloat

  var body: some View {
    let days = (-6...0).map { RelayDate.adding($0, to: RelayDate.calendar.startOfDay(for: now)) }
    let grouped = Dictionary(grouping: entries.filter { $0.time >= days[0] && $0.time <= now }) {
      RelayDate.calendar.startOfDay(for: $0.time)
    }
    let counts = days.map { grouped[$0]?.count ?? 0 }
    let wide = width >= 610 && !typeSize.isAccessibilitySize
    Group {
      if wide {
        HStack(spacing: 20) {
          summary
          Spacer(minLength: 4)
          BriefChart(days: days, counts: counts).frame(width: min(295, width * 0.34))
        }
      } else {
        VStack(alignment: .leading, spacing: 18) {
          summary
          BriefChart(days: days, counts: counts)
        }
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, wide ? 24 : 18).padding(.vertical, wide ? 18 : 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 17)
        .fill(
          LinearGradient(
            colors: [RelayPalette.rgb(0x222735), RelayPalette.rgb(0x373956)],
            startPoint: .leading, endPoint: .trailing))
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(RelayDate.long(now)).font(.subheadline.weight(.medium)).foregroundStyle(
        .white.opacity(0.78))
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(gapCount)").font(.system(size: numberSize, weight: .semibold, design: .rounded))
          .monospacedDigit().foregroundStyle(RelayPalette.rgb(0xD5D0FF))
        Text("项工作待回看").font(.title.weight(.semibold))
      }.accessibilityElement(children: .combine)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 9) {
          metric(.direction, "个方向")
          Circle().fill(.white.opacity(0.45)).frame(width: 3, height: 3)
          metric(.requirement, "项需求")
          Circle().fill(.white.opacity(0.45)).frame(width: 3, height: 3)
          metric(.idea, "个探索")
        }
        VStack(alignment: .leading) {
          metric(.direction, "个方向")
          metric(.requirement, "项需求")
          metric(.idea, "个探索")
        }
      }.font(.subheadline).foregroundStyle(.white.opacity(0.83))
    }.accessibilityElement(children: .contain)
  }

  private func metric(_ kind: ItemKind, _ suffix: String) -> Text {
    Text("\(items.filter { $0.kind == kind }.count) \(suffix)")
  }
}

private struct BriefChart: View {
  let days: [Date]
  let counts: [Int]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("近 7 天动态").font(.subheadline.weight(.semibold))
        Spacer()
        Text("\(counts.reduce(0, +)) 条记录").font(.caption).foregroundStyle(.white.opacity(0.82))
      }
      HStack(spacing: 4) {
        ForEach(days.indices, id: \.self) { index in
          let value = counts[index]
          let ratio = CGFloat(value) / CGFloat(max(1, counts.max() ?? 1))
          VStack(spacing: 4) {
            VStack(spacing: 2) {
              if value > 0 {
                Text("\(value)").font(.caption2.monospacedDigit()).foregroundStyle(
                  .white.opacity(0.84))
                RoundedRectangle(cornerRadius: 2)
                  .fill(index == days.count - 1 ? .white : RelayPalette.rgb(0xB6B4F4))
                  .frame(width: 14, height: max(2, 26 * ratio))
              }
            }.frame(height: 41, alignment: .bottom)
            Text(
              index == days.count - 1
                ? "今" : String(RelayDate.calendar.component(.day, from: days[index]))
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(index == days.count - 1 ? 1 : 0.72))
          }
          .frame(maxWidth: .infinity)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(RelayDate.short(days[index]))，\(value) 条记录")
          .help("\(RelayDate.short(days[index])) · \(value) 条记录")
        }
      }.background(alignment: .top) {
        Rectangle().fill(.white.opacity(0.20)).frame(height: 0.7).offset(y: 41)
          .accessibilityHidden(true)
      }
    }
    .padding(.leading, 1)
    .accessibilityElement(children: .contain)
  }
}

struct FollowUpRow: View {
  let gap: Gap
  let item: Item
  let entry: Entry?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      SymbolTile(symbol: symbol, tone: tone)
      VStack(alignment: .leading, spacing: 4) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 7) {
            reason
            context
          }
          VStack(alignment: .leading, spacing: 3) {
            reason
            context
          }
        }
        Text(item.title).font(.headline).foregroundStyle(RelayPalette.primary)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        if !gap.reason.isEmpty && gap.reason != item.title {
          Text(gap.reason).font(.subheadline).foregroundStyle(RelayPalette.secondary)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
        .foregroundStyle(RelayPalette.muted).padding(.top, 11).accessibilityHidden(true)
    }.padding(.vertical, 7).padding(.horizontal, 2)
  }

  private var reason: some View {
    Text(gap.label).font(.caption.weight(.semibold)).foregroundStyle(tone)
  }

  private var context: some View {
    Text(Self.context(item: item, entry: entry)).font(.caption).foregroundStyle(
      RelayPalette.secondary)
  }

  private var symbol: String {
    switch entry?.change.operation {
    case .pause: return "pause.fill"
    case .handoff: return "arrowshape.turn.up.right.fill"
    case .milestone: return "diamond.inset.filled"
    default: return "calendar.badge.exclamationmark"
    }
  }

  private var tone: Color {
    switch entry?.change.operation {
    case .handoff: return RelayPalette.accent
    case .milestone: return RelayPalette.teal
    default: return RelayPalette.amber
    }
  }

  static func context(item: Item, entry: Entry?) -> String {
    guard let entry else { return "" }
    let timing: String
    let elapsed = max(0, Int(Date.now.timeIntervalSince(entry.time) / 86_400))
    switch entry.change.operation {
    case .pause: timing = "已暂停 \(elapsed) 天"
    case .handoff: timing = "已等待 \(elapsed) 天"
    case .milestone: timing = "原定 " + RelayDate.short(entry.change.due ?? entry.time)
    case .create: timing = "原定结束 " + RelayDate.short(item.end ?? entry.time)
    default: timing = RelayDate.age(entry.time)
    }
    let who = [entry.actor, entry.change.recipient].compactMap { $0 }.joined(separator: " → ")
    return "\(who) · \(timing)"
  }
}

struct ActivityRow: View {
  let entry: Entry
  let item: Item?
  var noteLines: Int? = 2

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      MemberMark(name: entry.actor, size: 28)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(entry.actor).font(.subheadline.weight(.semibold)).foregroundStyle(
            RelayPalette.primary)
          Text(
            entry.change.operation == .create
              ? "新增" + (item?.kind.label ?? "事项") : entry.change.operation.label
          )
          .font(.caption).foregroundStyle(RelayPalette.secondary)
          Spacer(minLength: 0)
          Text(RelayDate.age(entry.time)).font(.caption).foregroundStyle(RelayPalette.muted)
        }
        Text(item?.title ?? entry.change.itemID).font(.subheadline).foregroundStyle(
          RelayPalette.primary
        )
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        if let note = entry.change.note, !note.isEmpty, note != item?.title {
          Text(note).font(.subheadline).foregroundStyle(RelayPalette.secondary)
            .lineLimit(noteLines).fixedSize(horizontal: false, vertical: true)
        }
      }
    }.padding(.vertical, 7).padding(.horizontal, 2)
  }
}

struct OverviewListPage: View {
  @EnvironmentObject private var model: WorkspaceModel
  let list: OverviewList

  var body: some View {
    let state = model.state
    RelayPage { _ in
      RelayPanel(spacing: 3) {
        switch list {
        case .activity:
          let entries = state.entries.sorted { ($0.time, $0.sequence) > ($1.time, $1.sequence) }
          ForEach(entries) { entry in
            if entry.id != entries.first?.id { Hairline() }
            NavigationLink(value: entry.change.itemID) {
              ActivityRow(entry: entry, item: state.items[entry.change.itemID], noteLines: nil)
            }.buttonStyle(RelayRowStyle())
          }
          if entries.isEmpty { QuietMessage(symbol: "text.bubble", text: "还没有工作记录") }
        case .followUps:
          let gaps = state.gaps()
          let byID = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.id, $0) })
          ForEach(gaps) { gap in
            if gap.id != gaps.first?.id { Hairline() }
            if let item = state.items[gap.itemID] {
              NavigationLink(value: item.id) {
                FollowUpRow(gap: gap, item: item, entry: byID[gap.id])
              }.buttonStyle(RelayRowStyle())
            }
          }
          if gaps.isEmpty { QuietMessage(symbol: "checkmark.circle", text: "目前没有需要回看的事项") }
        }
      }
    }.navigationTitle(list == .activity ? "全部团队动态" : "全部待回看记录")
  }
}
