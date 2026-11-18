import SwiftUI

enum RelayPalette {
  static let canvas = adaptive(0xF5F6F9, 0x17191F)
  static let surface = adaptive(0xFFFFFF, 0x21242C)
  static let primary = adaptive(0x202434, 0xF1F2F8)
  static let secondary = adaptive(0x5C6272, 0xB7BDCD)
  static let muted = adaptive(0x666D7D, 0xA1A9BB)
  static let line = adaptive(0xE0E3EB, 0x383C48)
  static let wash = adaptive(0xF1F2F7, 0x2C303A)
  static let accent = adaptive(0x514ABD, 0xB5ACFF)
  static let amber = adaptive(0x965713, 0xF2BC76)
  static let teal = adaptive(0x176F69, 0x82D1C5)
  static let blue = adaptive(0x365E9F, 0x9ABFF5)

  static func rgb(_ hex: Int) -> Color {
    Color(
      red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }

  private static func adaptive(_ light: Int, _ dark: Int) -> Color {
    #if os(macOS)
      Color(
        nsColor: NSColor(name: nil) { appearance in
          let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
          return NSColor(
            srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    #else
      Color(
        uiColor: UIColor { traits in
          let hex = traits.userInterfaceStyle == .dark ? dark : light
          return UIColor(
            red: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    #endif
  }
}

struct RelayPage<Content: View>: View {
  private let content: (CGFloat) -> Content

  init(@ViewBuilder content: @escaping (CGFloat) -> Content) { self.content = content }

  var body: some View {
    GeometryReader { proxy in
      let inset: CGFloat = proxy.size.width < 550 ? 16 : 24
      let width = max(0, min(1232, proxy.size.width - 2 * inset))
      ScrollView {
        VStack(alignment: .leading, spacing: 18) { content(width) }
          .frame(width: width, alignment: .leading)
          .padding(.vertical, inset)
          .frame(maxWidth: .infinity)
      }
    }
    .foregroundStyle(RelayPalette.primary)
    .background(RelayPalette.canvas)
  }
}

struct RelayPanel<Content: View>: View {
  var spacing: CGFloat
  private let content: Content

  init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) { content }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RelayPalette.surface, in: RoundedRectangle(cornerRadius: 15))
      .overlay {
        RoundedRectangle(cornerRadius: 15).strokeBorder(RelayPalette.line, lineWidth: 0.8)
      }
      .accessibilityElement(children: .contain)
  }
}

struct PanelTitle: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.title3.weight(.semibold)).foregroundStyle(RelayPalette.primary)
      .accessibilityAddTraits(.isHeader)
  }
}

struct StatusLabel: View {
  let text: String
  var tone = RelayPalette.accent

  var body: some View {
    Text(text)
      .font(.caption.weight(.medium))
      .foregroundStyle(tone)
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(tone.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
  }
}

struct SymbolTile: View {
  let symbol: String
  let tone: Color
  var size: CGFloat = 30
  var body: some View {
    Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold))
      .foregroundStyle(tone).frame(width: size, height: size)
      .background(tone.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.29))
      .accessibilityHidden(true)
  }
}

struct MemberMark: View {
  let name: String
  var size: CGFloat = 27
  private var tint: Color {
    let colors = [RelayPalette.accent, RelayPalette.teal, RelayPalette.amber, RelayPalette.blue]
    let index = name.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
    return colors[index]
  }
  var body: some View {
    Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
      .font(.system(size: size * 0.45, weight: .bold, design: .rounded)).foregroundStyle(tint)
      .frame(width: size, height: size).background(tint.opacity(0.13), in: Circle())
      .accessibilityHidden(true)
  }
}

struct RelayRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Row(configuration: configuration)
  }

  private struct Row: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
          RoundedRectangle(cornerRadius: 7)
            .fill(
              RelayPalette.accent.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.055 : 0)))
        }
        #if os(macOS)
          .onHover { hovering = $0 }
        #endif
    }
  }
}

struct Hairline: View {
  var body: some View {
    Rectangle().fill(RelayPalette.line).frame(height: 0.75).accessibilityHidden(true)
  }
}

struct QuietMessage: View {
  let symbol: String
  let text: String
  var body: some View {
    Label(text, systemImage: symbol)
      .font(.callout).foregroundStyle(RelayPalette.secondary)
      .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum RelayDate {
  static var calendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .autoupdatingCurrent
    cal.firstWeekday = 2
    return cal
  }

  static func adding(_ days: Int, to date: Date) -> Date {
    calendar.date(byAdding: .day, value: days, to: date) ?? date
  }

  static func short(_ date: Date) -> String {
    "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
  }

  static func long(_ date: Date) -> String {
    date.formatted(
      .dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().weekday(.wide))
  }

  static func age(_ date: Date, at today: Date = .now) -> String {
    let c = calendar
    let days =
      c.dateComponents([.day], from: c.startOfDay(for: date), to: c.startOfDay(for: today)).day ?? 0
    switch days {
    case 0: return "今天"
    case 1: return "昨天"
    case 2...6: return "\(days) 天前"
    default: return short(date)
    }
  }
}
