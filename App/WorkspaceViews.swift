import RelayCore
import SwiftUI

extension ItemKind {
  var label: String {
    switch self {
    case .direction: return "方向"
    case .requirement: return "需求"
    case .task: return "任务"
    case .idea: return "探索"
    }
  }
  var icon: String {
    switch self {
    case .direction: return "flag"
    case .requirement: return "calendar"
    case .task: return "checklist"
    case .idea: return "lightbulb"
    }
  }
  var tone: Color {
    switch self {
    case .direction: return RelayPalette.accent
    case .requirement: return RelayPalette.blue
    case .task: return RelayPalette.teal
    case .idea: return RelayPalette.amber
    }
  }
}

extension WorkOperation {
  var label: String {
    switch self {
    case .create: return "新增"
    case .update: return "披露进展"
    case .promote: return "纳入排期"
    case .pause: return "暂停"
    case .resume: return "恢复"
    case .close: return "记录收尾"
    case .milestone: return "计划节点"
    case .result: return "记录结果"
    case .handoff: return "交付"
    case .acknowledge: return "回应交付"
    case .remind: return "约定回看"
    }
  }
}

private enum Page: String, Identifiable {
  case overview = "团队概览"
  case directions = "方向与需求"
  case ideas = "探索池"
  case mine = "与我有关"
  case reminders = "提醒"
  case settings = "工作空间"
  var id: Self { self }
  var icon: String {
    switch self {
    case .overview: return "square.grid.2x2"
    case .directions: return "flag"
    case .ideas: return "lightbulb"
    case .mine: return "person"
    case .reminders: return "bell"
    case .settings: return "slider.horizontal.3"
    }
  }
}

struct ItemLink: View {
  let item: Item
  var subtitle: String? = nil

  var body: some View {
    NavigationLink(value: item.id) {
      HStack(alignment: .top, spacing: 10) {
        SymbolTile(symbol: item.kind.icon, tone: item.kind.tone)
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title).font(.headline).foregroundStyle(RelayPalette.primary)
          let context =
            subtitle
            ?? item.members.map { $0.role.isEmpty ? $0.name : "\($0.name) · \($0.role)" }
            .joined(separator: "，")
          if !context.isEmpty {
            Text(context).font(.subheadline).foregroundStyle(RelayPalette.secondary)
          }
        }
        Spacer(minLength: 4)
        StatusLabel(text: item.closed ? "已完成" : item.status, tone: item.kind.tone)
      }.padding(.vertical, 7).padding(.horizontal, 2)
    }.buttonStyle(RelayRowStyle())
  }
}

struct EditTarget: Identifiable {
  let id = UUID()
  var item: Item?
  var operation: WorkOperation
  var kind: ItemKind
  var reference: UUID?
  init(
    _ item: Item? = nil, _ op: WorkOperation = .create, _ kind: ItemKind = .direction,
    reference: UUID? = nil
  ) {
    self.item = item
    operation = op
    self.kind = kind
    self.reference = reference
  }
}

struct WorkspaceView: View {
  @EnvironmentObject var model: WorkspaceModel
  @Environment(\.scenePhase) var phase
  @State private var selection: Page? = {
    #if os(iOS) && targetEnvironment(simulator) && DEBUG
      if ProcessInfo.processInfo.arguments.contains("--preview-workspace") { return .settings }
    #endif
    return .overview
  }()
  @State private var path = NavigationPath()
  @State private var compact: NavigationSplitViewColumn = .detail
  @State private var edit: EditTarget?
  @State private var showingSchedule = false

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compact) {
      sidebar
    } detail: {
      NavigationStack(path: $path) {
        connectedPage.navigationTitle((selection ?? .overview).rawValue)
          #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
          #endif
          .navigationDestination(for: String.self) { id in
            if let item = model.state.items[id] {
              ItemDetails(item: item, edit: { edit = $0 })
            } else {
              ContentUnavailableView("暂无事项", systemImage: "questionmark.folder")
            }
          }
          .toolbar {
            if selection != .settings && path.isEmpty
              && (model.serverAddress == nil || model.hasSnapshot)
            {
              Button {
                edit = EditTarget(nil, .create, selection == .ideas ? .idea : .direction)
              } label: {
                Label("新建事项", systemImage: "plus")
              }.help("新建事项")
            }
          }
      }
    }
    .tint(RelayPalette.accent)
    .onChange(of: selection) { _, _ in path = NavigationPath() }
    .sheet(item: $edit) { Editor(target: $0).environmentObject(model) }
    .task(id: phase) {
      guard phase == .active else { return }
      await model.start()
      repeat {
        await model.refresh()
        try? await Task.sleep(for: .seconds(5))
      } while !Task.isCancelled
    }
    .alert(
      "工作空间提示",
      isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    ) {
      Button("知道了") { model.problem = nil }
    } message: {
      Text(model.problem ?? "")
    }
  }

  @ViewBuilder private var connectedPage: some View {
    if selection != .settings && !model.hasSnapshot {
      if let issue = model.sourceIssue {
        ContentUnavailableView {
          Label(
            model.serverAddress == nil ? "无法打开本地记录" : "无法连接团队服务",
            systemImage: "exclamationmark.circle")
        } description: {
          Text(issue)
        } actions: {
          Button("工作空间设置") { selection = .settings }
          Button("重试") { Task { await model.retry() } }
        }
      } else {
        ProgressView("正在打开工作空间…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      pageBody.safeAreaInset(edge: .top, spacing: 0) {
        if selection != .settings, model.sourceIssue != nil {
          HStack {
            Label("连接已中断，正在显示上次同步的记录", systemImage: "wifi.slash")
            Spacer()
            Button("连接设置") { selection = .settings }
          }.font(.callout).padding(8).background(.regularMaterial)
        }
      }
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      #if os(macOS)
        HStack(spacing: 9) {
          ZStack {
            RoundedRectangle(cornerRadius: 9).fill(
              LinearGradient(
                colors: [RelayPalette.rgb(0x625AD4), RelayPalette.rgb(0x383478)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 2.5) {
              Capsule().fill(.white.opacity(0.64)).frame(width: 5.5, height: 12).offset(y: -2)
              Capsule().fill(.white).frame(width: 6.5, height: 17).offset(y: 1)
            }.rotationEffect(.degrees(34))
          }.frame(width: 31, height: 31).accessibilityHidden(true)
          Text("Relay").font(.system(size: 23, weight: .bold, design: .rounded)).foregroundStyle(
            RelayPalette.primary)
        }.padding(.horizontal, 17).padding(.top, 10).padding(.bottom, 12)
      #endif
      List(selection: $selection) {
        Section("团队") { ForEach([Page.overview, .directions, .ideas]) { sidebarLink($0) } }
        Section("个人") { ForEach([Page.mine, .reminders]) { sidebarLink($0) } }
        Section { sidebarLink(.settings) }
      }.listStyle(.sidebar)
      HStack(spacing: 9) {
        MemberMark(name: model.currentActor, size: 30)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.currentActor.isEmpty ? "未署名" : model.currentActor)
            .font(.subheadline.weight(.semibold)).lineLimit(1)
          Text(model.workspaceLabel)
            .font(.caption).foregroundStyle(RelayPalette.secondary).lineLimit(1)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .overlay(alignment: .top) { Hairline() }
    }
    .navigationTitle("Relay")
    .navigationSplitViewColumnWidth(min: 174, ideal: 195, max: 240)
  }

  private func sidebarLink(_ page: Page) -> some View {
    NavigationLink(value: page) {
      Label(page.rawValue, systemImage: page.icon).padding(.vertical, 3)
    }
  }

  private var all: [Item] {
    model.state.items.values.sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }

  @ViewBuilder private var pageBody: some View {
    switch selection ?? .overview {
    case .overview: Overview(state: model.state)
    case .directions:
      let directions = all.filter { $0.kind == .direction }
      RelayPage { width in
        DisclosureGroup("需求排期", isExpanded: $showingSchedule) {
          let scheduled = all.filter { $0.kind == .requirement }.sorted {
            ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id)
          }
          RequirementSchedule(
            items: scheduled, entries: model.state.entries, width: width - 20, today: .now)
        }
        if directions.isEmpty { empty("flag", "尚未记录方向") }
        ForEach(directions) { direction in
          let requirements = model.state.children(of: direction.id).filter {
            $0.kind == .requirement
          }
          RelayPanel(spacing: 5) {
            ItemLink(item: direction, subtitle: direction.next)
            Hairline()
            if requirements.isEmpty {
              QuietMessage(symbol: "calendar", text: "这个方向还没有排定的需求")
            }
            ForEach(requirements) { item in ItemLink(item: item).padding(.leading, 12) }
          }
        }
      }
    case .ideas:
      let ideas = all.filter { $0.kind == .idea }
      let grouped = Dictionary(grouping: ideas) {
        $0.category.flatMap { $0.isEmpty ? nil : $0 } ?? "待分类"
      }
      RelayPage { _ in
        if ideas.isEmpty { empty("lightbulb", "探索池里还没有想法") }
        ForEach(grouped.keys.sorted(), id: \.self) { category in
          RelayPanel(spacing: 4) {
            PanelTitle(category).padding(.bottom, 3)
            ForEach(grouped[category] ?? []) { item in
              if item.id != grouped[category]?.first?.id { Hairline() }
              ItemLink(
                item: item, subtitle: model.state.history(item.id).last?.change.note ?? item.next)
            }
          }
        }
      }
    case .mine:
      let handoffs = model.state.entries.filter {
        $0.change.operation == .handoff && $0.change.recipient == model.currentActor
          && !model.state.resolved($0.id)
      }
      let active = all.filter {
        !$0.closed && $0.members.contains(where: { $0.name == model.currentActor })
      }
      RelayPage { _ in
        RelayPanel(spacing: 5) {
          PanelTitle("等我回应")
          if handoffs.isEmpty { QuietMessage(symbol: "tray", text: "没有等你回应的交付") }
          ForEach(handoffs) { e in
            if let item = model.state.items[e.change.itemID] {
              ItemLink(item: item, subtitle: e.actor + " · " + (e.change.note ?? "交付"))
            }
          }
        }
        RelayPanel(spacing: 5) {
          PanelTitle("我参与的工作")
          if active.isEmpty { QuietMessage(symbol: "person", text: "当前没有署名参与的事项") }
          ForEach(active) { ItemLink(item: $0) }
        }
      }
    case .reminders:
      let reminders = Array(
        model.state.entries.filter { $0.change.operation == .remind }.reversed())
      RelayPage { _ in
        RelayPanel {
          PanelTitle("本机通知")
          Text(model.notificationStatus.text).foregroundStyle(RelayPalette.secondary)
          if let issue = model.notificationRequestError, issue != model.notificationStatus.text {
            Text(issue).font(.callout).foregroundStyle(RelayPalette.amber)
          }
          if model.notificationStatus == .needsPermission {
            Button("允许本地通知") { Task { await model.authorizeNotifications() } }
          }
        }
        RelayPanel(spacing: 7) {
          PanelTitle("团队的回看约定")
          if reminders.isEmpty {
            QuietMessage(symbol: "bell", text: "还没有回看约定。可以在事项详情约定时间，也可以让 Agent 添加。")
          }
          ForEach(reminders) { entry in
            if let item = model.state.items[entry.change.itemID] {
              let condition =
                model.state.reminderIsCurrent(entry)
                ? (entry.change.reference == nil ? "到点通知" : "仍暂停时通知") : "条件已解除"
              NavigationLink(value: item.id) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(entry.change.note ?? item.title).font(.headline)
                  Text(
                    [entry.change.recipient, entry.change.due?.formatted(), condition].compactMap {
                      $0
                    }.joined(separator: " · ")
                  )
                  .font(.subheadline).foregroundStyle(RelayPalette.secondary)
                }.padding(.vertical, 5)
              }.buttonStyle(RelayRowStyle())
            }
          }
        }
      }
    case .settings: WorkspaceSettings { selection = .overview }
    }
  }

  private func empty(_ icon: String, _ text: String) -> some View {
    RelayPanel { QuietMessage(symbol: icon, text: text) }
  }

}
