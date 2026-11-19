import RelayCore
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsAction: Int, Identifiable {
  case workspace, signature, assistant
  var id: Self { self }
}

private func isDeviceService(_ address: String) -> Bool {
  guard let host = URL(string: address)?.host?.lowercased() else { return false }
  return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
}

struct WorkspaceSettings: View {
  @EnvironmentObject private var model: WorkspaceModel
  @Environment(\.dynamicTypeSize) private var typeSize
  #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
  #endif
  @State private var action: SettingsAction?
  @State private var retrying = false
  #if os(macOS)
    @Environment(\.scenePhase) private var phase
    @State private var checkedConnection: AssistantConnection?
    @State private var checkedAssistants: [LocalAssistant] = []

    private var assistants: [LocalAssistant] {
      checkedConnection == model.assistantConnection ? checkedAssistants : []
    }
    private var connectionToCheck: AssistantConnection? {
      phase == .active && model.hasSnapshot && action != .assistant
        ? model.assistantConnection : nil
    }
  #endif
  let showBoard: () -> Void

  private var sourceName: String {
    if let address = model.serverAddress {
      return isDeviceService(address) ? "本机服务" : model.workspaceLabel
    }
    return model.root == Journal.local.root ? "此设备上的记录" : model.root.lastPathComponent
  }

  private var sourceDetail: String {
    if let issue = model.sourceIssue {
      let detail = model.hasSnapshot ? "当前显示上次读到的看板。" : ""
      return detail + issue
    }
    if let address = model.serverAddress {
      return isDeviceService(address)
        ? "通过这台设备上的 Relay 服务同步看板。" : "这份看板由团队服务同步。"
    }
    return model.root == Journal.local.root ? "看板保存在此设备的应用目录中。" : "看板从所选文件夹读取并保存。"
  }

  private var status: String {
    if model.sourceIssue != nil {
      return model.serverAddress == nil ? "读取失败" : (model.hasSnapshot ? "连接中断" : "无法连接")
    }
    if model.serverAddress == nil { return model.hasSnapshot ? "使用中" : "正在读取" }
    return model.hasSnapshot ? "已连接" : "正在连接"
  }

  var body: some View {
    RelayPage(maxWidth: 780) { width in
      let narrow = width < 460 || typeSize.isAccessibilitySize
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          PanelTitle("当前工作空间")
          Spacer()
          Button("切换工作空间…") { action = .workspace }
            #if os(iOS)
              .foregroundStyle(RelayPalette.accent)
            #endif
        }
        RelayPanel(spacing: 16) {
          HStack(alignment: .top, spacing: 13) {
            SymbolTile(
              symbol: model.serverAddress == nil ? "folder" : "server.rack",
              tone: RelayPalette.accent, size: 42)
            VStack(alignment: .leading, spacing: 7) {
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                  sourceTitle
                  statusView
                }
                VStack(alignment: .leading, spacing: 4) {
                  sourceTitle
                  statusView
                }
              }
              Text(sourceDetail).font(.callout).foregroundStyle(RelayPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
              if model.hasSnapshot {
                Button("查看方向与需求", action: showBoard).buttonStyle(.borderedProminent)
                  #if os(iOS)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                  #endif
                  .padding(.top, 4)
              } else if model.sourceIssue != nil {
                Button(retrying ? "正在重试…" : "重试") {
                  retrying = true
                  Task {
                    await model.retry()
                    retrying = false
                  }
                }.buttonStyle(.borderedProminent).disabled(retrying)
                  #if os(iOS)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                  #endif
              }
            }
          }
          Hairline()
          let pending = model.serverAddress != nil && !model.hasSnapshot
          HStack(spacing: 10) {
            if pending {
              SymbolTile(symbol: "person", tone: RelayPalette.muted, size: 30)
            } else {
              MemberMark(name: model.currentActor, size: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
              Text("记录署名").font(.caption).foregroundStyle(RelayPalette.secondary)
              Text(pending ? "连接后显示" : (model.currentActor.isEmpty ? "尚未填写" : model.currentActor))
                .font(.body.weight(.medium)).textSelection(.enabled)
            }
            Spacer()
            if model.viewer != nil {
              Text(model.sourceIssue == nil ? "由团队服务确认" : "上次连接时确认")
                .font(.caption).foregroundStyle(RelayPalette.secondary)
            } else if !pending {
              Button("修改署名…") { action = .signature }.buttonStyle(.borderless)
                #if os(iOS)
                  .foregroundStyle(RelayPalette.accent)
                #endif
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        PanelTitle("工作助手")
        RelayPanel {
          let layout =
            narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
          layout {
            HStack(alignment: .top, spacing: 12) {
              SymbolTile(
                symbol: "bubble.left.and.text.bubble.right", tone: RelayPalette.teal, size: 36)
              VStack(alignment: .leading, spacing: 5) {
                #if os(macOS)
                  Text(
                    assistants.isEmpty
                      ? "让助手更新看板" : assistants.map(\.rawValue).joined(separator: "、") + " 已配置"
                  ).font(.headline)
                  Text(
                    assistants.isEmpty
                      ? "连接后，你可以在 Codex 或 Claude Code 的对话里记录进展。" : "在助手里新开一个对话，就可以查看需求或记录进展。"
                  )
                  .font(.callout).foregroundStyle(RelayPalette.secondary)
                #else
                  Text("让助手更新看板").font(.headline)
                  Text("在 Mac 上打开 Relay 的「工作空间」并连接助手。使用同一团队服务时，这里也能看到更新。")
                    .font(.callout).foregroundStyle(RelayPalette.secondary)
                #endif
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
              Button(assistants.isEmpty ? "连接助手…" : "设置助手…") { action = .assistant }
                .disabled(!model.hasSnapshot)
            #endif
          }
        }
      }
      if !model.state.conflicts.isEmpty {
        RelayPanel {
          PanelTitle("待核对的记录")
          ForEach(model.state.conflicts, id: \.self) {
            Text($0).font(.callout).textSelection(.enabled)
          }
        }
      }
    }
    #if os(macOS)
      .task(id: connectionToCheck) {
        guard let connection = connectionToCheck else { return }
        let result = await connection.configuredAssistants()
        guard !Task.isCancelled, connection == connectionToCheck else { return }
        checkedConnection = connection
        checkedAssistants = result
      }
    #endif
    .sheet(item: $action) { which in
      switch which {
      case .workspace: WorkspaceChooser(model: model)
      case .signature: SignatureEditor(model: model)
      case .assistant:
        #if os(macOS)
          AssistantSetupView(model: model, configured: assistants)
        #else
          EmptyView()
        #endif
      }
    }
  }

  private var sourceTitle: some View {
    Text(sourceName).font(.title2.weight(.semibold)).foregroundStyle(RelayPalette.primary)
  }

  private var statusView: some View {
    StatusLabel(
      text: status,
      tone: model.sourceIssue != nil
        ? RelayPalette.amber
        : (model.hasSnapshot ? RelayPalette.teal : RelayPalette.muted))
  }
}

struct SettingsSheet<Content: View, Actions: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content
  @ViewBuilder let actions: () -> Actions

  private var fields: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
      content()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var footer: some View {
    HStack {
      Spacer(minLength: 0)
      actions()
    }
  }

  var body: some View {
    #if os(macOS)
      VStack(spacing: 20) {
        fields
        Hairline()
        footer
      }
      .padding(24).frame(width: 456)
    #else
      ScrollView { fields.padding(20).padding(.top, 10) }
        .safeAreaInset(edge: .bottom) {
          footer.padding().background(.regularMaterial)
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    #endif
  }
}

private struct SignatureEditor: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: String
  init(model: WorkspaceModel) {
    self.model = model
    _draft = State(initialValue: model.actor)
  }
  private var name: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
  var body: some View {
    SettingsSheet(title: "修改记录署名") {
      VStack(alignment: .leading, spacing: 7) {
        Text("你在此设备上新写的记录会使用这个名字。").font(.callout).foregroundStyle(.secondary)
        TextField("你的名字", text: $draft).textFieldStyle(.roundedBorder)
          .onSubmit { save() }
      }
    } actions: {
      Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("保存") { save() }.keyboardShortcut(.defaultAction)
        .disabled(name.isEmpty || model.viewer != nil)
    }
  }
  private func save() {
    guard !name.isEmpty, model.viewer == nil else { return }
    model.actor = name
    dismiss()
  }
}

private enum WorkspaceSource { case service, files }

private struct WorkspaceChooser: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var source: WorkspaceSource
  @State private var address: String
  @State private var token = ""
  @State private var folder: URL?
  @State private var picking = false
  @State private var busy = false
  @State private var issue: String?

  init(model: WorkspaceModel) {
    self.model = model
    _source = State(initialValue: model.serverAddress == nil ? .files : .service)
    _address = State(
      initialValue: model.serverAddress
        ?? UserDefaults.standard.string(forKey: "relay.server") ?? RemoteJournal.defaultAddress)
    _folder = State(
      initialValue: model.serverAddress == nil && model.root != Journal.local.root
        ? model.root : nil)
  }

  var body: some View {
    SettingsSheet(title: "切换工作空间") {
      Picker("看板来源", selection: $source) {
        Text("连接服务").tag(WorkspaceSource.service)
        Text("本地记录").tag(WorkspaceSource.files)
      }.pickerStyle(.segmented).labelsHidden().disabled(busy)
      Group {
        if source == .service {
          serviceFields
        } else {
          fileFields
        }
      }.disabled(busy)
      if let issue {
        Label(issue, systemImage: "exclamationmark.circle").font(.callout)
          .foregroundStyle(RelayPalette.amber).fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("未能切换工作空间，" + issue)
      }
    } actions: {
      if busy { ProgressView().controlSize(.small) }
      Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
      Button(source == .service ? "连接并使用" : "使用这些记录") { Task { await apply() } }
        .keyboardShortcut(.defaultAction)
        .disabled(
          busy
            || (source == .service
              && address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
    }
    .interactiveDismissDisabled(busy)
    .onChange(of: source) { _, _ in
      issue = nil
      token = ""
    }
    .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
      switch result {
      case .success(let selected):
        folder = selected
        issue = nil
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled { issue = error.localizedDescription }
      }
    }
  }

  private var serviceFields: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("服务地址").font(.headline)
        TextField(
          "https://…",
          text: Binding(
            get: { address },
            set: { next in
              if address != next {
                token = ""
                issue = nil
              }
              address = next
            })
        ).textFieldStyle(.roundedBorder).accessibilityLabel("服务地址")
          #if os(iOS)
            .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
          #endif
        #if os(iOS)
          Text("请输入这台设备能访问的团队 HTTPS 地址。").font(.caption).foregroundStyle(.secondary)
        #endif
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("成员令牌").font(.headline)
        SecureField(model.hasToken(address) ? "已保存，可留空" : "粘贴个人令牌", text: $token)
          .textFieldStyle(.roundedBorder).accessibilityLabel("成员令牌")
          .onChange(of: token) { _, _ in issue = nil }
        Text(
          model.hasToken(address)
            ? "留空会使用此地址已保存的令牌。"
            : (isDeviceService(address) ? "本机演示可以留空。连接团队服务时，使用团队给你的个人令牌。" : "请使用团队给你的个人 Relay 令牌。")
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var fileFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("记录位置").font(.headline)
      Text(folder?.path ?? "此设备上的应用目录")
        .font(.body).textSelection(.enabled)
      HStack {
        Button("选择已有文件夹…") { picking = true }
        if folder != nil {
          Button("改用此设备的记录") {
            folder = nil
            issue = nil
          }
        }
      }
      Text("切换只会打开所选位置的看板。原工作空间的记录会保留。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  @MainActor private func apply() async {
    guard !busy else { return }
    busy = true
    issue = nil
    defer { busy = false }
    do {
      switch source {
      case .service: try await model.connect(address, token: token)
      case .files: try await model.openFolder(folder)
      }
      dismiss()
    } catch let error as URLError
      where error.code == .cannotConnectToHost || error.code == .timedOut
    {
      issue = "服务没有响应。请确认服务已启动，并核对地址。"
    } catch {
      issue = error.localizedDescription
    }
  }
}
