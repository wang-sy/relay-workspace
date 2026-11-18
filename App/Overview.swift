import RelayCore
import SwiftUI

struct Overview: View {
  @Environment(\.calendar) private var calendar
  @Environment(\.dynamicTypeSize) private var typeSize
  let state: Workspace

  var body: some View {
    // A date change affects the board even when HTTP returns an unchanged snapshot.
    TimelineView(.everyMinute) { clock in
      let rows = state.requirementBoard(at: clock.date, calendar: calendar)
      RelayPage(maxWidth: 1180, background: RelayPalette.surface) { width in
        let wide = width >= 665 && !typeSize.isAccessibilitySize
        HStack(alignment: .firstTextBaseline) {
          Text("团队需求").font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
          Spacer()
          Text(
            clock.date.formatted(
              .dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday())
          )
          .font(.subheadline).foregroundStyle(RelayPalette.secondary)
        }
        if rows.isEmpty {
          ContentUnavailableView(
            "当前没有推进中的需求", systemImage: "list.bullet",
            description: Text("在「方向与需求」中查看排期和已完成的需求。")
          )
          .frame(maxWidth: .infinity)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            if wide {
              columns(width: width) {
                Text("需求 · 方向")
              } members: {
                Text("推进人")
              } progress: {
                Text("当前进展")
              }
              .font(.subheadline.weight(.medium)).foregroundStyle(RelayPalette.secondary)
              .padding(.vertical, 8).accessibilityHidden(true)
            }
            Hairline()
            LazyVStack(spacing: 0) {
              ForEach(rows) { row in
                NavigationLink(value: row.id) {
                  if wide {
                    columns(width: width) {
                      subject(row)
                    } members: {
                      owners(row)
                    } progress: {
                      progress(row)
                    }
                    .padding(.vertical, 13)
                  } else {
                    VStack(alignment: .leading, spacing: 6) {
                      subject(row)
                      ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                          owners(row).fixedSize()
                          progress(row).fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                          owners(row)
                          progress(row)
                        }
                      }
                    }.padding(.vertical, 11)
                  }
                }
                .buttonStyle(RelayRowStyle())
                .accessibilityLabel(describe(row))
                .help(describe(row))
                Hairline()
              }
            }
          }
        }
      }
    }
  }

  private func columns<Subject: View, Owners: View, Progress: View>(
    width: CGFloat, @ViewBuilder subject: () -> Subject, @ViewBuilder members: () -> Owners,
    @ViewBuilder progress: () -> Progress
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      subject().frame(width: width * 0.39, alignment: .leading)
      members().frame(width: min(150, width * 0.15), alignment: .leading)
      progress().frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func subject(_ row: RequirementRow) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(row.title).font(.headline).foregroundStyle(RelayPalette.primary)
        .lineLimit(typeSize.isAccessibilitySize ? nil : 2).layoutPriority(1)
      if let direction = row.direction {
        Text(direction).font(.caption).foregroundStyle(RelayPalette.secondary)
          .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(RelayPalette.wash, in: RoundedRectangle(cornerRadius: 4))
      }
    }
  }

  private func owners(_ row: RequirementRow) -> some View {
    Text(memberNames(row)).font(.subheadline).foregroundStyle(RelayPalette.secondary)
      .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
  }

  private func memberNames(_ row: RequirementRow) -> String {
    row.members.isEmpty ? "未署名" : row.members.map(\.name).joined(separator: "、")
  }

  private func progress(_ row: RequirementRow) -> some View {
    let summary = Text(row.summary).foregroundStyle(RelayPalette.primary)
    return Group {
      if let label = row.phase.label {
        (Text(label + "  ").fontWeight(.semibold).foregroundStyle(row.phase.tone) + summary)
      } else {
        summary
      }
    }
    .font(.subheadline)
    .lineLimit(typeSize.isAccessibilitySize ? nil : (row.phase == .active ? 1 : 3))
  }

  private func describe(_ row: RequirementRow) -> String {
    [row.title, row.direction, "推进人 " + memberNames(row), row.phase.label, row.summary]
      .compactMap { $0 }.joined(separator: "，")
  }
}

extension RequirementRow.Phase {
  fileprivate var label: String? {
    switch self {
    case .blocked: return "卡住"
    case .waiting: return "等接手"
    case .completedToday: return "今日完成"
    case .active: return nil
    }
  }

  fileprivate var tone: Color {
    switch self {
    case .blocked: return RelayPalette.amber
    case .waiting: return RelayPalette.accent
    case .completedToday: return RelayPalette.teal
    case .active: return RelayPalette.secondary
    }
  }
}
