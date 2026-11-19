import RelayCore
import SwiftUI

extension HostedFunction.Trigger {
  fileprivate var description: String {
    switch kind {
    case "cron": return [expression, timezone].compactMap { $0 }.joined(separator: " · ")
    case "at":
      if let at, let date = try? Date(at, strategy: .iso8601) { return date.formatted() }
      return at ?? "指定时间"
    case "event":
      let label = operation.map { WorkOperation(rawValue: $0).label } ?? "事项变化"
      let seconds = delaySeconds ?? 0
      guard seconds > 0 else { return label + "时" }
      let units = DateComponentsFormatter()
      var calendar = Calendar(identifier: .gregorian)
      calendar.locale = Locale(identifier: "zh_CN")
      units.calendar = calendar
      units.allowedUnits = [.day, .hour, .minute, .second]
      units.maximumUnitCount = 2
      units.unitsStyle = .full
      return label + "后 " + (units.string(from: TimeInterval(seconds)) ?? "\(seconds) 秒")
    default: return kind
    }
  }
}

struct HostedFunctionsView: View {
  let service: RemoteJournal
  let actor: String
  @State private var functions: [HostedFunction]?
  @State private var problem: String?

  var body: some View {
    RelayPage(maxWidth: 720) { _ in
      if let problem {
        ContentUnavailableView {
          Label("无法读取服务端自动化", systemImage: "exclamationmark.circle")
        } description: {
          Text(problem)
        } actions: {
          Button("重试") { Task { await load() } }
        }
      } else if let functions {
        if functions.isEmpty {
          ContentUnavailableView {
            Label("还没有托管函数", systemImage: "clock.arrow.2.circlepath")
          } description: {
            Text("可以对连接此工作空间的 Agent 说“需求暂停三天后，如果还卡着，就提醒我”。")
          }
        } else {
          RelayPanel(spacing: 0) {
            ForEach(functions) { function in
              if function.id != functions.first?.id { Hairline() }
              NavigationLink {
                HostedFunctionDetail(service: service, actor: actor, initial: function)
              } label: {
                HStack(spacing: 12) {
                  SymbolTile(
                    symbol: (function.resolvedTrigger ?? function.trigger).kind == "event"
                      ? "bolt" : "clock",
                    tone: RelayPalette.accent)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(function.name).font(.headline)
                    Text(function.trigger.description).font(.subheadline).foregroundStyle(
                      RelayPalette.secondary)
                    if let next = function.nextAt {
                      Text("下次执行 \(next.formatted())").font(.caption).foregroundStyle(
                        RelayPalette.secondary)
                    }
                  }
                  Spacer()
                  StatusLabel(
                    text: function.enabled ? "启用" : "已暂停",
                    tone: function.enabled ? RelayPalette.teal : RelayPalette.muted)
                  Image(systemName: "chevron.right").font(.caption).foregroundStyle(
                    RelayPalette.muted)
                }.padding(.vertical, 10)
              }.buttonStyle(RelayRowStyle())
            }
          }
        }
      } else {
        ProgressView("正在读取托管函数…")
      }
    }
    .task {
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private func load() async {
    do {
      let updated = try await service.functions()
      if !Task.isCancelled {
        functions = updated
        problem = nil
      }
    } catch { if !Task.isCancelled { problem = error.localizedDescription } }
  }
}

private struct HostedFunctionDetail: View {
  let service: RemoteJournal
  let actor: String
  let initial: HostedFunction
  @State private var detail: HostedFunction?
  @State private var problem: String?
  @State private var saving = false
  @State private var showCode = false

  var body: some View {
    let function = detail ?? initial
    RelayPage(maxWidth: 720) { _ in
      RelayPanel {
        PanelTitle(function.name)
        Text(function.trigger.description)
        if let source = function.resolvedTrigger {
          Text(source.description).font(.subheadline).foregroundStyle(RelayPalette.secondary)
        }
        if let item = (function.resolvedTrigger ?? function.trigger).itemID { Text("关联事项 \(item)") }
        if let next = function.nextAt { Text("下次执行 \(next.formatted())") }
        Text("发布人 \(function.actor) · 版本 \(function.revision)").font(.subheadline).foregroundStyle(
          RelayPalette.secondary)
        Button(function.enabled ? "暂停自动化" : "启用自动化") {
          saving = true
          Task {
            defer { saving = false }
            do {
              detail = try await service.setFunctionEnabled(
                function.id, revision: function.revision, enabled: !function.enabled, actor: actor)
              problem = nil
            } catch { problem = error.localizedDescription }
          }
        }.disabled(saving || detail == nil)
      }
      if let problem {
        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(RelayPalette.amber)
      }
      if let detail {
        RelayPanel {
          PanelTitle("最近执行")
          if let runs = detail.runs, !runs.isEmpty {
            ForEach(runs) { run in
              if run.id != runs.first?.id { Hairline() }
              VStack(alignment: .leading, spacing: 3) {
                Text(runLabel(run)).font(.subheadline.weight(.semibold))
                Text(
                  [run.scheduledAt.formatted(), run.itemID, "版本 \(run.revision)"].compactMap { $0 }
                    .joined(separator: " · ")
                )
                .font(.caption).foregroundStyle(RelayPalette.secondary)
                if let error = run.error {
                  Text(error).font(.caption).foregroundStyle(RelayPalette.amber)
                }
              }
            }
          } else {
            Text("还没有触发记录").font(.subheadline).foregroundStyle(RelayPalette.secondary)
          }
        }
        if let code = detail.code {
          DisclosureGroup("函数代码", isExpanded: $showCode) {
            Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
          }
        }
      }
    }
    .navigationTitle("函数详情")
    .task(id: initial.id) {
      while !Task.isCancelled {
        do {
          let updated = try await service.function(initial.id)
          if !Task.isCancelled && updated.revision >= (detail?.revision ?? 0) {
            detail = updated
            if !saving { problem = nil }
          }
        } catch { if !Task.isCancelled { problem = error.localizedDescription } }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private func runLabel(_ run: HostedFunction.Run) -> String {
    switch run.status {
    case "queued": return "等待执行"
    case "running": return "执行中"
    case "succeeded": return "已写入 \(run.writes) 条记录"
    case "skipped": return "已跳过"
    case "failed": return "执行失败"
    case "cancelled": return "版本变更，已取消"
    default: return run.status
    }
  }
}
