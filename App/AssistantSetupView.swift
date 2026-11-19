#if os(macOS)
  import AppKit
  import RelayCore
  import SwiftUI

  extension WorkspaceModel {
    var assistantConnection: AssistantConnection {
      let relay = (Bundle.main.executableURL ?? Bundle.main.bundleURL).deletingLastPathComponent()
        .appendingPathComponent("relay")
      if let server = serverAddress {
        return AssistantConnection(
          relay: relay, server: server, keychain: usesSavedToken,
          actor: currentActor)
      }
      return AssistantConnection(relay: relay, folder: root, actor: currentActor)
    }

  }

  struct AssistantSetupView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var client = LocalAssistant.codex
    @State private var busy = false
    @State private var registered: AssistantRegistration?
    @State private var error: String?
    @State private var manual = false
    @State private var copied = false

    let configured: [LocalAssistant]

    private var connection: AssistantConnection { model.assistantConnection }

    var body: some View {
      SettingsSheet(title: "连接工作助手") {
        VStack(alignment: .leading, spacing: 8) {
          Text("你平时用哪个助手？").font(.headline)
          Picker("选择助手", selection: $client) {
            ForEach(LocalAssistant.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).labelsHidden().disabled(busy)
        }
        if let registered {
          VStack(alignment: .leading, spacing: 8) {
            Label(
              registered == .added ? "已添加到 \(client.rawValue)" : "\(client.rawValue) 已有这个工作空间",
              systemImage: "checkmark.circle.fill"
            ).font(.headline).foregroundStyle(RelayPalette.teal)
            Text("在助手里新开一个对话，问它「团队有哪些需求在等人接手？」。")
              .font(.callout)
          }
        } else {
          Text(
            model.usesViewerToken
              ? "当前连接使用查看令牌。若要记录进展，请给助手进程设置 RELAY_TOKEN，值为团队分配给你的 Agent 令牌。"
              : "Relay 会将当前看板添加到这台 Mac 的 \(client.rawValue)。之后可以在对话里查看需求、记录进展。"
          )
          .font(.callout).foregroundStyle(.secondary)
          if let error {
            Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(
              RelayPalette.amber)
          }
          DisclosureGroup("手动设置", isExpanded: $manual) {
            if let command = try? connection.terminalCommand(for: client) {
              VStack(alignment: .leading, spacing: 9) {
                Text("在终端执行这条命令，然后在助手里新开一个对话。").font(.caption)
                Text(command).textSelection(.enabled).font(.caption.monospaced())
                  .padding(9).background(RelayPalette.wash, in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? "已复制" : "复制命令") {
                  NSPasteboard.general.clearContents()
                  copied = NSPasteboard.general.setString(command, forType: .string)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
          }.disabled(busy)
        }
      } actions: {
        if busy { ProgressView().controlSize(.small) }
        if registered != nil {
          Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        } else {
          Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
          Button("添加到 \(client.rawValue)") { Task { await register() } }
            .keyboardShortcut(.defaultAction).disabled(busy)
        }
      }
      .interactiveDismissDisabled(busy)
      .onAppear { clearFeedback() }
      .onChange(of: client) { _, _ in clearFeedback() }
      .onChange(of: connection) { _, _ in clearFeedback() }
    }

    private func clearFeedback() {
      error = nil
      copied = false
      registered = configured.contains(client) ? .alreadyAdded : nil
      manual = false
    }

    @MainActor private func register() async {
      guard !busy else { return }
      busy = true
      defer { busy = false }
      error = nil
      let target = connection
      do {
        let result = try await target.register(with: client)
        if target == connection { registered = result }
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
#endif
