import RelayCore
import SwiftUI

struct RequirementSchedule: View {
  @Environment(\.dynamicTypeSize) private var typeSize
  @Binding var offset: Int
  let items: [Item]
  let entries: [Entry]
  let width: CGFloat
  let today: Date

  var body: some View {
    let calendar = RelayDate.calendar
    let currentWeek =
      calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? calendar.startOfDay(for: today)
    let start = RelayDate.adding(offset * 7, to: currentWeek)
    let days = (0..<7).map { RelayDate.adding($0, to: start) }
    let nextWeek = RelayDate.adding(7, to: start)
    let weekItems = items.filter {
      ($0.start ?? .distantFuture) < nextWeek && ($0.end ?? .distantPast) >= start
    }
    let milestones = Dictionary(
      grouping: entries.filter {
        guard $0.change.operation == .milestone, let due = $0.change.due else { return false }
        return due >= start && due < nextWeek
      }
    ) {
      $0.change.itemID
    }
    let showsMilestones = weekItems.contains { milestones[$0.id] != nil }
    let compact = width < 620 || typeSize.isAccessibilitySize
    let labelWidth = min(260, max(180, width * 0.28))
    RelayPanel(spacing: 9) {
      ViewThatFits(in: .horizontal) {
        HStack {
          title(legend: showsMilestones)
          Spacer(minLength: 12)
          controls(days)
        }
        VStack(alignment: .leading, spacing: 6) {
          title(legend: showsMilestones)
          controls(days)
        }
      }
      HStack(spacing: 12) {
        if !compact {
          Text("需求").font(.caption.weight(.medium)).foregroundStyle(RelayPalette.muted)
            .frame(width: labelWidth, alignment: .leading)
            .accessibilityHidden(true)
        }
        HStack(spacing: 0) {
          ForEach(days, id: \.self) { date in
            let isToday = calendar.isDate(date, inSameDayAs: today)
            Text(dateLabel(date, today: isToday))
              .font(.caption.weight(isToday ? .bold : .regular)).monospacedDigit()
              .foregroundStyle(isToday ? RelayPalette.accent : RelayPalette.muted)
              .frame(maxWidth: .infinity)
          }
        }
      }.padding(.vertical, 3)
      Hairline()
      if weekItems.isEmpty {
        QuietMessage(symbol: "calendar", text: "这一周没有排定的需求")
        if let nearest = items.compactMap({ item -> Date? in
          guard let from = item.start, let to = item.end else { return nil }
          return to < start ? to : from
        }).min(by: { abs($0.timeIntervalSince(start)) < abs($1.timeIntervalSince(start)) }),
          let week = calendar.dateInterval(of: .weekOfYear, for: nearest)?.start
        {
          Button("查看最近的排期") {
            offset = (calendar.dateComponents([.day], from: currentWeek, to: week).day ?? 0) / 7
          }
        }
      }
      ForEach(weekItems) { item in
        let marks = milestones[item.id] ?? []
        NavigationLink(value: item.id) {
          if compact {
            VStack(alignment: .leading, spacing: 5) {
              itemLabel(item)
              WeekTrack(days: days, item: item, milestones: marks, today: today, tone: tint(item))
            }
          } else {
            HStack(spacing: 12) {
              itemLabel(item).frame(width: labelWidth, alignment: .leading)
              WeekTrack(days: days, item: item, milestones: marks, today: today, tone: tint(item))
            }
          }
        }.buttonStyle(RelayRowStyle())
      }
    }
  }

  private func title(legend: Bool) -> some View {
    HStack(spacing: 11) {
      PanelTitle("需求排期")
      if legend {
        Label("计划节点", systemImage: "diamond.fill")
          .font(.caption).foregroundStyle(RelayPalette.muted)
      }
    }
  }

  private func dateLabel(_ day: Date, today: Bool) -> String {
    if today { return "今天" }
    let c = RelayDate.calendar
    return String(c.component(.day, from: day)) + "日"
  }

  private func controls(_ days: [Date]) -> some View {
    HStack(spacing: 8) {
      if offset != 0 {
        Button("回本周") { offset = 0 }.font(.caption).buttonStyle(.plain).foregroundStyle(
          RelayPalette.accent)
      }
      Text("\(RelayDate.short(days[0])) – \(RelayDate.short(days[6]))")
        .font(.subheadline.monospacedDigit()).foregroundStyle(RelayPalette.secondary)
        .accessibilityLabel("显示的一周，\(RelayDate.long(days[0]))至\(RelayDate.long(days[6]))")
      HStack(spacing: 1) {
        weekButton(-1, label: "上一周", symbol: "chevron.left")
        weekButton(1, label: "下一周", symbol: "chevron.right")
      }.background(RelayPalette.wash, in: RoundedRectangle(cornerRadius: 6))
    }
  }

  private func weekButton(_ change: Int, label: String, symbol: String) -> some View {
    Button {
      offset += change
    } label: {
      Image(systemName: symbol).font(.caption.weight(.semibold))
        #if os(iOS)
          .frame(minWidth: 44, minHeight: 44)
        #else
          .frame(minWidth: 28, minHeight: 25)
        #endif
        .contentShape(Rectangle())
    }.buttonStyle(.plain).foregroundStyle(RelayPalette.secondary)
      .accessibilityLabel(label).help(label)
  }

  private func itemLabel(_ item: Item) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(RelayPalette.primary)
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
      let dates = [item.start, item.end].compactMap { $0 }.map(RelayDate.short).joined(
        separator: " – ")
      let members = item.members.map(\.name).joined(separator: "、")
      Text([dates, members, item.status].filter { !$0.isEmpty }.joined(separator: " · "))
        .font(.caption).foregroundStyle(RelayPalette.secondary)
    }.padding(.vertical, 2)
  }

  private func tint(_ item: Item) -> Color {
    let index = item.id.utf8.reduce(0) { ($0 + Int($1)) % 2 }
    return index == 0 ? RelayPalette.accent : RelayPalette.teal
  }
}

private struct WeekTrack: View {
  let days: [Date]
  let item: Item
  let milestones: [Entry]
  let today: Date
  let tone: Color

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width / 7
      let c = RelayDate.calendar
      let lower = max(0, min(6, index(item.start ?? days[0])))
      let upper = max(lower, min(6, index(item.end ?? days[6])))
      let byDay = Dictionary(grouping: milestones) { index($0.change.due ?? $0.time) }
      ZStack(alignment: .leading) {
        HStack(spacing: 0) {
          ForEach(days, id: \.self) { date in
            Rectangle()
              .fill(
                c.isDate(date, inSameDayAs: today)
                  ? RelayPalette.accent.opacity(0.09) : RelayPalette.wash.opacity(0.55)
              )
              .frame(width: width)
              .overlay(alignment: .leading) {
                Rectangle().fill(RelayPalette.line).frame(width: 0.75)
              }
          }
        }.clipShape(RoundedRectangle(cornerRadius: 5))
        RoundedRectangle(cornerRadius: 4)
          .fill(tone.opacity(0.24))
          .overlay(alignment: .leading) {
            endMark(continues: (item.start ?? days[0]) < days[0], symbol: "chevron.left")
          }
          .overlay(alignment: .trailing) {
            endMark(
              continues: (item.end ?? days[6]) >= RelayDate.adding(7, to: days[0]),
              symbol: "chevron.right")
          }
          .frame(width: max(3, CGFloat(upper - lower + 1) * width - 6), height: 12)
          .offset(x: CGFloat(lower) * width + 3)
        ForEach(byDay.keys.sorted(), id: \.self) { index in
          RoundedRectangle(cornerRadius: 1.4).fill(tone)
            .frame(width: 8, height: 8).rotationEffect(.degrees(45))
            .offset(x: (CGFloat(index) + 0.5) * width - 4)
            .help(milestoneSummary(byDay[index] ?? []))
        }
      }.frame(maxHeight: .infinity)
    }
    .frame(height: 24)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(milestones.isEmpty ? "需求排期" : milestoneSummary(milestones))
  }

  @ViewBuilder private func endMark(continues: Bool, symbol: String) -> some View {
    if continues {
      Image(systemName: symbol).font(.system(size: 7, weight: .bold))
        .foregroundStyle(tone).padding(.horizontal, 2)
    } else {
      Capsule().fill(tone).frame(width: 2)
    }
  }

  private func milestoneSummary(_ entries: [Entry]) -> String {
    entries.map { e in
      "计划节点 " + RelayDate.short(e.change.due ?? e.time) + " " + (e.change.note ?? "")
    }.joined(separator: "，")
  }

  private func index(_ date: Date) -> Int {
    let c = RelayDate.calendar
    return c.dateComponents([.day], from: days[0], to: c.startOfDay(for: date)).day ?? 0
  }
}
