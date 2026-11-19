import RelayCore
import SwiftUI

extension Item {
  var displayStatus: String { closed ? "已完成" : status }
}

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

private enum Page: String, CaseIterable, Identifiable {
  case directions = "方向与需求"
  case ideas = "探索池"
  var id: Self { self }
  var icon: String { self == .directions ? "flag" : "lightbulb" }
}

private enum WorkspaceTool: String, Identifiable {
  case settings = "工作空间"
  case reminders = "提醒"
  var id: Self { self }
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
        StatusLabel(text: item.displayStatus, tone: item.kind.tone)
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
  @EnvironmentObject private var model: WorkspaceModel
  @Environment(\.scenePhase) private var phase
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  @State private var selection = Page.directions
  @State private var directionPath: [String] = []
  @State private var ideaPath: [String] = []
  @State private var onlyMine = false
  @State private var edit: EditTarget?
  @State private var tool: WorkspaceTool? = {
    #if os(iOS) && targetEnvironment(simulator) && DEBUG
      if ProcessInfo.processInfo.arguments.contains("--preview-workspace") { return .settings }
    #endif
    return nil
  }()

  var body: some View {
    Group {
      #if os(iOS)
        if sizeClass == .compact {
          TabView(selection: $selection) {
            ForEach(Page.allCases) { page in
              screen(page)
                .tabItem { Label(page.rawValue, systemImage: page.icon) }
                .tag(page)
            }
          }
        } else {
          splitView
        }
      #else
        splitView
      #endif
    }
    .tint(RelayPalette.accent)
    .sheet(item: $edit) { Editor(target: $0).environmentObject(model) }
    .sheet(item: $tool) { utility in
      NavigationStack {
        Group {
          switch utility {
          case .settings:
            WorkspaceSettings {
              directionPath = []
              selection = .directions
              tool = nil
            }
          case .reminders: reminders
          }
        }
        .navigationTitle(utility.rawValue)
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { tool = nil }.keyboardShortcut(.cancelAction)
          }
        }
      }
      #if os(macOS)
        .frame(minWidth: 480, idealWidth: 700, minHeight: 400, idealHeight: 510)
      #endif
    }
    .onChange(of: model.serverAddress ?? model.root.path) { _, _ in
      directionPath = []
      ideaPath = []
    }
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

  private var splitView: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      screen(selection).id(selection)
    }
  }

  private func screen(_ page: Page) -> some View {
    let path = page == .directions ? $directionPath : $ideaPath
    return NavigationStack(path: path) {
      connectedPage(page)
        .navigationTitle(page.rawValue)
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
          if path.wrappedValue.isEmpty {
            #if os(iOS)
              if sizeClass == .compact {
                ToolbarItem(placement: .topBarLeading) {
                  Menu {
                    workspaceActions
                  } label: {
                    Label("工作空间菜单", systemImage: "person.crop.circle")
                  }
                }
              }
            #endif
            if model.hasSnapshot {
              ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                  Picker("显示范围", selection: $onlyMine) {
                    Text("全部事项").tag(false)
                    Text("与我有关").tag(true)
                  }
                } label: {
                  Label(
                    onlyMine ? "与我有关" : "筛选",
                    systemImage: onlyMine
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                }
                .help(onlyMine ? "正在显示与我有关的事项" : "筛选与我有关的事项")
                Button {
                  edit = EditTarget(nil, .create, page == .ideas ? .idea : .direction)
                } label: {
                  Label(page == .ideas ? "新建探索" : "新建事项", systemImage: "plus")
                }.help(page == .ideas ? "新建探索" : "新建事项")
              }
            }
          }
        }
    }
  }

  @ViewBuilder private func connectedPage(_ page: Page) -> some View {
    if !model.hasSnapshot {
      if let issue = model.sourceIssue {
        ContentUnavailableView {
          Label(
            model.serverAddress == nil ? "无法打开本地记录" : "无法连接团队服务",
            systemImage: "exclamationmark.circle")
        } description: {
          Text(issue)
        } actions: {
          Button("工作空间设置") { tool = .settings }
          Button("重试") { Task { await model.retry() } }
        }
      } else {
        ProgressView("正在打开工作空间…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      let ids = onlyMine ? model.state.itemIDs(relatedTo: model.currentActor) : nil
      Group {
        switch page {
        case .directions: RequirementsView(state: model.state, scope: ids)
        case .ideas: ideas(scope: ids)
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        if model.sourceIssue != nil {
          HStack {
            Label("连接已中断，正在显示上次同步的记录", systemImage: "wifi.slash")
            Spacer()
            Button("连接设置") { tool = .settings }
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
      List(
        selection: Binding<Page?>(
          get: { selection }, set: { if let page = $0 { selection = page } })
      ) {
        ForEach(Page.allCases) { page in
          NavigationLink(value: page) {
            Label(page.rawValue, systemImage: page.icon).padding(.vertical, 4)
          }
        }
      }.listStyle(.sidebar)
      Hairline()
      Menu {
        workspaceActions
      } label: {
        HStack(spacing: 9) {
          MemberMark(name: model.currentActor, size: 30)
          VStack(alignment: .leading, spacing: 2) {
            Text(model.currentActor.isEmpty ? "未署名" : model.currentActor)
              .font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("工作空间").font(.caption).foregroundStyle(RelayPalette.secondary)
          }
          Spacer(minLength: 4)
          Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(
            RelayPalette.secondary)
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityLabel("工作空间菜单")
      .help("工作空间设置与提醒")
      .padding(14)
    }
    .navigationTitle("Relay")
    .navigationSplitViewColumnWidth(min: 174, ideal: 195, max: 240)
  }

  @ViewBuilder private var workspaceActions: some View {
    Button {
      tool = .settings
    } label: {
      Label("工作空间设置…", systemImage: "gearshape")
    }
    Button {
      tool = .reminders
    } label: {
      Label("提醒…", systemImage: "bell")
    }
  }

  private func ideas(scope: Set<String>?) -> some View {
    let items = model.state.items.values.filter {
      $0.kind == .idea && (scope?.contains($0.id) ?? true)
    }
    .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    let grouped = Dictionary(grouping: items) {
      $0.category.flatMap { $0.isEmpty ? nil : $0 } ?? "待分类"
    }
    return RelayPage { _ in
      if items.isEmpty {
        ContentUnavailableView(scope == nil ? "还没有探索" : "没有与你相关的探索", systemImage: "lightbulb")
      }
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
  }

  private func openItem(_ item: Item) {
    selection = item.kind == .idea ? .ideas : .directions
    if selection == .ideas { ideaPath = [item.id] } else { directionPath = [item.id] }
    tool = nil
  }

  private var reminders: some View {
    let reminders = Array(
      model.state.entries.filter { $0.change.operation == .remind }.reversed())
    return RelayPage { _ in
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
            Button {
              openItem(item)
            } label: {
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
  }
}
