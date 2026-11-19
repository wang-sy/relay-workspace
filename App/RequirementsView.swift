import RelayCore
import SwiftUI

private enum RequirementLayout: String, CaseIterable {
  case tree, gantt, cards
  var title: String {
    switch self {
    case .tree: return "树状图"
    case .gantt: return "甘特图"
    case .cards: return "状态卡片"
    }
  }
}

struct RequirementsView: View {
  let state: Workspace
  let scope: Set<String>?
  @AppStorage("relay.requirements.layout") private var layout = RequirementLayout.tree
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var collapsedDirections: Set<String> = []
  @State private var expandedRequirements: Set<String> = []
  @State private var weekOffset = 0

  var body: some View {
    let items = state.items.values.filter { $0.kind != .idea && (scope?.contains($0.id) ?? true) }
      .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    let requirements = items.filter { $0.kind == .requirement }
    RelayPage { width in
      HStack(spacing: 12) {
        Picker("需求视图", selection: $layout) {
          ForEach(RequirementLayout.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(maxWidth: width < 500 ? .infinity : 300)
        if width >= 500 && !typeSize.isAccessibilitySize {
          Spacer()
          Text(scope == nil ? "\(requirements.count) 个需求" : "与我有关 · \(requirements.count) 个需求")
            .font(.subheadline).foregroundStyle(RelayPalette.secondary)
        }
      }
      switch layout {
      case .tree:
        if items.isEmpty {
          emptyView
        } else {
          outline(items, compact: width < 680 || typeSize.isAccessibilitySize)
        }
      case .gantt:
        if requirements.isEmpty {
          emptyView
        } else {
          TimelineView(.everyMinute) { clock in
            RequirementSchedule(
              offset: $weekOffset,
              items: requirements.sorted {
                ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id)
              }, entries: state.entries, width: width, today: clock.date)
          }
        }
      case .cards:
        if requirements.isEmpty {
          emptyView
        } else {
          RequirementCards(state: state, requirements: requirements, width: width)
        }
      }
    }
  }

  private var emptyView: some View {
    ContentUnavailableView(
      scope != nil
        ? "没有与你相关的\(layout == .tree ? "事项" : "需求")"
        : (layout == .tree ? "还没有方向与需求" : "还没有需求"),
      systemImage: layout == .gantt ? "calendar" : "flag")
  }

  private func outline(_ items: [Item], compact: Bool) -> some View {
    let children = Dictionary(
      grouping: items.compactMap { item in
        item.parentID.map { (parent: $0, item: item) }
      }, by: \.parent
    ).mapValues { $0.map(\.item) }
    let directions = items.filter { $0.kind == .direction }
    return VStack(spacing: 0) {
      ForEach(directions) { direction in
        let requirements = children[direction.id] ?? []
        let open = !collapsedDirections.contains(direction.id)
        if direction.id != directions.first?.id { Hairline() }
        outlineRow(direction, depth: 0, count: requirements.count, expanded: open, compact: compact)
        {
          if open {
            collapsedDirections.insert(direction.id)
          } else {
            collapsedDirections.remove(direction.id)
          }
        }
        if open {
          ForEach(requirements) { requirement in
            let tasks = children[requirement.id] ?? []
            let expanded = expandedRequirements.contains(requirement.id)
            outlineRow(
              requirement, depth: 1, count: tasks.count, expanded: expanded, compact: compact
            ) {
              if expanded {
                expandedRequirements.remove(requirement.id)
              } else {
                expandedRequirements.insert(requirement.id)
              }
            }
            if expanded {
              ForEach(tasks) { task in
                outlineRow(task, depth: 2, compact: compact)
              }
            }
          }
        }
      }
    }
    .padding(.vertical, 4).padding(.horizontal, compact ? 6 : 12)
    .background(RelayPalette.surface, in: RoundedRectangle(cornerRadius: 13))
    .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(RelayPalette.line, lineWidth: 0.8) }
  }

  private func outlineRow(
    _ item: Item, depth: Int, count: Int = 0, expanded: Bool = false, compact: Bool,
    toggle: (() -> Void)? = nil
  ) -> some View {
    let status = item.displayStatus
    let members = item.members.map(\.name).joined(separator: "、")
    let countLabel = count > 0 ? "\(count) 个\(depth == 0 ? "需求" : "任务")" : ""
    let summary = [countLabel, members, status].filter { !$0.isEmpty }.joined(separator: " · ")
    return HStack(spacing: 4) {
      if count > 0, let toggle {
        Button(action: toggle) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold)).foregroundStyle(RelayPalette.secondary)
            .frame(width: compact ? 36 : 28, height: compact ? 44 : 32).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityLabel("\(expanded ? "折叠" : "展开")\(item.title)，\(countLabel)")
          .help("\(expanded ? "折叠" : "展开")\(countLabel)")
      } else {
        Color.clear.frame(width: compact ? 36 : 28, height: 1).accessibilityHidden(true)
      }
      NavigationLink(value: item.id) {
        HStack(spacing: 9) {
          Image(systemName: item.kind.icon)
            .font(.system(size: depth == 0 ? 16 : 14, weight: .medium))
            .foregroundStyle(item.kind.tone).frame(width: 20).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(depth == 0 ? .headline : .body).foregroundStyle(
              RelayPalette.primary
            )
            .fixedSize(horizontal: false, vertical: true)
            if compact {
              Text(summary).font(.caption).foregroundStyle(RelayPalette.secondary)
            }
          }
          Spacer(minLength: 2)
          if !compact {
            if !countLabel.isEmpty {
              Text(countLabel).font(.caption).foregroundStyle(RelayPalette.muted)
            }
            if !members.isEmpty {
              Text(members).font(.subheadline).foregroundStyle(RelayPalette.secondary)
                .lineLimit(1).frame(maxWidth: 180, alignment: .trailing)
            }
            StatusLabel(text: status, tone: item.kind.tone)
          }
        }.padding(.vertical, compact ? 8 : 10).padding(.trailing, 6)
      }
      .buttonStyle(RelayRowStyle())
      .accessibilityLabel("\(item.kind.label)，\(item.title)，\(summary)")
    }
    .padding(.leading, CGFloat(depth) * (compact ? 12 : 25))
  }
}
