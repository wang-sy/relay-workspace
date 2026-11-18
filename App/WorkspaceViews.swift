import RelayCore
import SwiftUI
import UniformTypeIdentifiers

extension ItemKind {
  var label: String {
    switch self {
    case .direction: return "方向"
    case .requirement: return "需求"
    case .task: return "Task"
    case .idea: return "探索 / To Do"
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
  case overview = "团队概览"
  case directions = "方向与需求"
  case ideas = "探索池"
  case mine = "与我有关"
  case reminders = "提醒"
  case settings = "工作空间"
  var id: Self { self }
  var icon: String {
    switch self {
    case .overview: return "rectangle.grid.2x2"
    case .directions: return "point.3.connected.trianglepath.dotted"
    case .ideas: return "lightbulb"
    case .mine: return "person"
    case .reminders: return "bell"
    case .settings: return "slider.horizontal.3"
    }
  }
}
struct ItemLink: View {
  let item: Item
  var body: some View {
    NavigationLink(value: item.id) {
      HStack(spacing: 12) {
        Image(systemName: item.kind.icon).foregroundStyle(.indigo).frame(width: 22)
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title).font(.headline)
          Text(
            [
              item.category,
              item.members.map { $0.name + ($0.role.isEmpty ? "" : " · " + $0.role) }.joined(
                separator: "，"),
            ]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "　")
          ).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(item.status).font(.caption).foregroundStyle(.indigo)
      }.padding(.vertical, 3)
    }
  }
}
struct EditTarget: Identifiable {
  let id = UUID()
  var item: Item?
  var operation: WorkOperation
  var kind: ItemKind
  init(_ item: Item? = nil, _ op: WorkOperation = .create, _ kind: ItemKind = .direction) {
    self.item = item
    operation = op
    self.kind = kind
  }
}

struct WorkspaceView: View {
  @EnvironmentObject var model: WorkspaceModel
  @Environment(\.scenePhase) var phase
  @State private var selection: Page? = .overview
  @State private var path = [String]()
  @State private var compact: NavigationSplitViewColumn = .detail
  @State private var edit: EditTarget?
  @State private var picking = false
  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compact) {
      List(selection: $selection) {
        Section("Relay Workspace") {
          ForEach(Page.allCases) { page in
            NavigationLink(value: page) { Label(page.rawValue, systemImage: page.icon) }
          }
        }
      }.navigationTitle("Relay").listStyle(.sidebar)
    } detail: {
      NavigationStack(path: $path) {
        pageBody.navigationTitle((selection ?? .overview).rawValue)
          .navigationDestination(for: String.self) { id in
            if let item = model.state.items[id] {
              ItemDetails(item: item, edit: { edit = $0 })
            } else {
              ContentUnavailableView("暂无事项", systemImage: "questionmark.folder")
            }
          }
          .toolbar {
            if selection != .settings {
              Button {
                edit = EditTarget(nil, .create, selection == .ideas ? .idea : .direction)
              } label: {
                Label("新建事项", systemImage: "plus")
              }
            }
          }
      }
    }
    .tint(.indigo)
    .onChange(of: selection) { _, _ in path.removeAll() }
    .sheet(item: $edit) { Editor(target: $0).environmentObject(model) }
    .fileImporter(
      isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls): if let url = urls.first { Task { await model.select(url) } }
      case .failure(let err): model.problem = err.localizedDescription
      }
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

  var all: [Item] {
    model.state.items.values.sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
  @ViewBuilder private var pageBody: some View {
    switch selection ?? .overview {
    case .overview: Overview(items: all)
    case .directions:
      List {
        ForEach(all.filter { $0.kind == .direction }) { direction in
          Section {
            ItemLink(item: direction)
            ForEach(model.state.children(of: direction.id).filter { $0.kind == .requirement }) {
              ItemLink(item: $0).padding(.leading, 16)
            }
          }
        }
      }
    case .ideas:
      let ideas = all.filter { $0.kind == .idea }
      List {
        ForEach(Set(ideas.map { $0.category ?? "待分类" }).sorted(), id: \.self) { category in
          Section(category) {
            ForEach(ideas.filter { ($0.category ?? "待分类") == category }) { ItemLink(item: $0) }
          }
        }
      }
    case .mine:
      List {
        Section("等我回应") {
          ForEach(
            model.state.entries.filter {
              $0.change.operation == .handoff && $0.change.recipient == model.actor
                && !model.state.resolved($0.id)
            }
          ) { e in
            if let item = model.state.items[e.change.itemID] { ItemLink(item: item) }
          }
        }
        Section("我参与的工作") {
          ForEach(
            all.filter { !$0.closed && $0.members.contains(where: { $0.name == model.actor }) }
          ) { ItemLink(item: $0) }
        }
      }
    case .reminders:
      let reminders = model.state.entries.filter { $0.change.operation == .remind }.reversed()
      List {
        Section("此设备") {
          Label(model.notificationText, systemImage: "bell.badge")
          Button("允许本地通知") { Task { await model.authorizeNotifications() } }
        }
        Section("团队的回看约定") {
          if reminders.isEmpty {
            Text("在事项详情里选择“约定回看”，或让本地 Agent 提交提醒。").foregroundStyle(.secondary)
          }
          ForEach(Array(reminders)) { e in
            NavigationLink(value: e.change.itemID) {
              VStack(alignment: .leading, spacing: 4) {
                Text(e.change.note ?? "回看").font(.headline)
                Text(
                  "\(e.change.recipient ?? "") · \(e.change.due?.formatted() ?? "") · \(model.state.reminderIsCurrent(e) ? (e.change.reference == nil ? "到点通知" : "仍暂停时通知") : "条件已解除")"
                ).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    case .settings: settings
    }
  }
  private var settings: some View {
    Form {
      Section("当前工作空间") {
        Text(model.root.lastPathComponent).font(.headline)
        Text(model.root.path).font(.caption.monospaced()).textSelection(.enabled)
        Button("选择共享文件夹…") { picking = true }
        Button("使用设备本地工作空间") {
          Task {
            await model.select(nil)
            path.removeAll()
          }
        }
        Text("在 Mac 和移动设备上选择同一个已共享的 iCloud Drive 文件夹。各端读取其中的工作记录。").font(.caption).foregroundStyle(
          .secondary)
      }
      Section("此设备的成员标签") {
        TextField("成员名", text: $model.actor)
        Text("用于本机署名及提醒匹配。事项角色由每条工作记录填写。").font(.caption).foregroundStyle(.secondary)
      }
      #if os(macOS)
        Section("接入本地 Agent") {
          Text("在终端执行以下命令，为 Codex 连接此工作空间。其他支持 stdio MCP 的客户端可以使用相同程序和参数。")
          let folder = model.root.path
          let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relay").path
          let command =
            "codex mcp add relay --env " + quote("RELAY_ACTOR=" + model.actor) + " -- "
            + quote(tool) + " --workspace " + quote(folder) + " mcp"
          Text(command).font(.caption.monospaced()).textSelection(.enabled)
          Button("复制接入命令") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
          }
        }
      #endif
      if !model.state.conflicts.isEmpty {
        Section("待核对的记录") { ForEach(model.state.conflicts, id: \.self) { Text($0).font(.caption) } }
      }
    }.formStyle(.grouped)
  }
  private func quote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

private struct Overview: View {
  @EnvironmentObject var model: WorkspaceModel
  let items: [Item]
  var body: some View {
    let reqs = items.filter { $0.kind == .requirement }.sorted {
      ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture)
    }
    let gaps = model.state.gaps()
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 12) {
          Image(systemName: "point.3.connected.trianglepath.dotted").font(
            .system(size: 30, weight: .medium)
          ).foregroundStyle(.white)
          VStack(alignment: .leading, spacing: 5) {
            Text("工作空间概览").font(.title2.bold())
            Text(
              "\(items.filter{$0.kind == .direction}.count) 个方向　·　\(reqs.count) 项需求　·　\(items.filter{$0.kind == .idea}.count) 个探索"
            ).font(.subheadline)
          }.foregroundStyle(.white)
          Spacer()
        }.padding(20).background(
          LinearGradient(
            colors: [Color(red: 0.18, green: 0.16, blue: 0.37), .indigo], startPoint: .leading,
            endPoint: .trailing), in: RoundedRectangle(cornerRadius: 15))
        VStack(alignment: .leading, spacing: 10) {
          Label("需要回看 · \(gaps.count)", systemImage: "clock.badge.exclamationmark").font(
            .title3.bold())
          if gaps.isEmpty { Text("当前没有命中回看规则的记录。").foregroundStyle(.secondary) }
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading,
            spacing: 10
          ) {
            ForEach(gaps) { g in
              NavigationLink(value: g.itemID) {
                VStack(alignment: .leading, spacing: 7) {
                  Text(g.label).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                  Text(model.state.items[g.itemID]?.title ?? g.itemID).font(.headline)
                  Text(g.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(
                  .regularMaterial, in: RoundedRectangle(cornerRadius: 10))
              }.buttonStyle(.plain)
            }
          }
        }
        VStack(alignment: .leading, spacing: 6) {
          Label("需求时间线", systemImage: "calendar").font(.title3.bold())
          ForEach(reqs) { r in
            NavigationLink(value: r.id) {
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(r.title).font(.headline)
                  Spacer()
                  Text(r.status).font(.caption).foregroundStyle(.indigo)
                }
                if let a = r.start, let b = r.end {
                  Text(
                    "\(a.formatted(date:.abbreviated,time:.omitted)) — \(b.formatted(date:.abbreviated,time:.omitted))"
                  ).font(.caption).foregroundStyle(.secondary)
                }
              }.padding(.vertical, 6)
            }.buttonStyle(.plain)
            Divider()
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Label("最近披露", systemImage: "text.bubble").font(.title3.bold())
          ForEach(model.state.entries.sorted { $0.time > $1.time }.prefix(5)) { e in
            NavigationLink(value: e.change.itemID) {
              VStack(alignment: .leading, spacing: 3) {
                Text("\(e.actor) · \(e.change.operation.label)").font(
                  .subheadline.weight(.semibold))
                Text(e.change.note ?? model.state.items[e.change.itemID]?.title ?? e.change.itemID)
                  .font(.caption).foregroundStyle(.secondary)
              }
            }.buttonStyle(.plain)
          }
        }
      }.padding(20).frame(maxWidth: 1100, alignment: .leading)
    }.frame(maxWidth: .infinity)
  }
}

private struct ItemDetails: View {
  @EnvironmentObject var model: WorkspaceModel
  let item: Item
  let edit: (EditTarget) -> Void
  var body: some View {
    let events = model.state.history(item.id)
    List {
      Section("事项") {
        LabeledContent("类型", value: item.kind.label)
        LabeledContent("状态", value: item.status)
        if let parent = item.parentID, let p = model.state.items[parent] {
          NavigationLink("上级 · " + p.title, value: parent)
        }
        if let next = item.next, !next.isEmpty { Text(next) }
        if let start = item.start, let end = item.end {
          LabeledContent(
            "计划周期",
            value: start.formatted(date: .abbreviated, time: .omitted) + " — "
              + end.formatted(date: .abbreviated, time: .omitted))
        }
        ForEach(item.members, id: \.name) { p in LabeledContent(p.name, value: p.role) }
      }
      if !model.state.children(of: item.id).isEmpty {
        Section("下级事项") { ForEach(model.state.children(of: item.id)) { ItemLink(item: $0) } }
      }
      if events.contains(where: { $0.change.operation == .milestone }) {
        Section("计划节点") {
          ForEach(
            events.filter { $0.change.operation == .milestone }.sorted {
              ($0.change.due ?? .distantFuture) < ($1.change.due ?? .distantFuture)
            }
          ) { e in
            Label(
              (e.change.due?.formatted(date: .abbreviated, time: .omitted) ?? "") + " · "
                + (e.change.note ?? ""),
              systemImage: model.state.resolved(e.id) ? "checkmark.circle.fill" : "diamond")
          }
        }
      }
      Section("披露记录") {
        ForEach(events.reversed()) { e in
          VStack(alignment: .leading, spacing: 4) {
            Text("\(e.actor) · \(e.change.operation.label)").font(.headline)
            if let note = e.change.note { Text(note) }
            Text(
              [e.source, e.session, e.time.formatted()].compactMap { $0 }.joined(separator: " · ")
            ).font(.caption).foregroundStyle(.secondary)
          }.padding(.vertical, 3)
        }
      }
    }.navigationTitle(item.title)
      .toolbar {
        Menu {
          Button("披露进展") { edit(EditTarget(item, .update)) }
          Button("约定回看") { edit(EditTarget(item, .remind)) }
          if item.kind == .idea { Button("纳入需求排期") { edit(EditTarget(item, .promote)) } }
          if item.kind == .direction {
            Button("新增需求") { edit(EditTarget(item, .create, .requirement)) }
          }
          if item.kind == .requirement {
            Button("拆出 Task") { edit(EditTarget(item, .create, .task)) }
          }
        } label: {
          Label("事项操作", systemImage: "ellipsis.circle")
        }
      }
  }
}
