import ImageIO
import QuickLook
import RelayCore
import SwiftUI

private enum ContextDestination: Hashable, Identifiable {
  case library, history
  case reference(String)
  case event(String, String)
  case eventLibrary(String, String)
  var id: Self { self }
}

struct ItemContextView: View {
  let service: any ContextReading
  let itemID: String
  @Environment(\.scenePhase) private var phase
  @State private var recall: ItemRecall?
  @State private var issue: String?
  @State private var destination: ContextDestination?

  var body: some View {
    RelayPanel(spacing: 12) {
      HStack {
        PanelTitle("事项回顾")
        Spacer()
        if let recall {
          Button("资料（\(recall.referenceCount)）") { destination = .library }
          Button("时间线") { destination = .history }
        }
      }
      if let recall {
        if recall.referenceCount == 0 && recall.highlights.allSatisfy({ $0.text == nil }) {
          Text("还没有回顾资料。可以让助手把依据和下一步挂到这个事项。")
            .font(.callout).foregroundStyle(RelayPalette.secondary)
        } else {
          ForEach(recall.highlights) { highlight in
            VStack(alignment: .leading, spacing: 4) {
              Text(
                ["decision": "上次决定", "evidence": "当时依据", "next": "接着做什么"][highlight.slot]
                  ?? highlight.slot
              )
              .font(.caption.weight(.medium)).foregroundStyle(RelayPalette.secondary)
              if let value = highlight.text {
                Text(value).font(.body).textSelection(.enabled)
                Button {
                  if let id = highlight.referenceID {
                    destination = .reference(id)
                  } else if let id = highlight.eventID {
                    destination = .event(itemID, id)
                  }
                } label: {
                  Label(
                    [highlight.sourceTitle, highlight.time.map(RelayDate.long)].compactMap { $0 }
                      .joined(separator: " · "), systemImage: "link"
                  )
                  .font(.caption)
                }.buttonStyle(.borderless)
              } else {
                Text("待确认").font(.callout).foregroundStyle(RelayPalette.muted)
              }
            }
          }
        }
      } else if issue == nil {
        ProgressView("正在读取回顾…")
      }
      if let issue { Text(issue).font(.caption).foregroundStyle(RelayPalette.amber) }
    }
    .task(id: phase) {
      guard phase == .active else { return }
      while !Task.isCancelled {
        do {
          let update = try await service.recall(itemID, since: nil)
          try Task.checkCancellation()
          recall = update
          issue = nil
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        try? await Task.sleep(for: .seconds(5))
      }
    }
    .sheet(item: $destination) { first in
      NavigationStack {
        page(first).navigationDestination(for: ContextDestination.self) { page($0) }
          .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { destination = nil } }
          }
      }
      #if os(macOS)
        .frame(minWidth: 480, idealWidth: 680, minHeight: 400, idealHeight: 530)
      #endif
    }
  }

  @ViewBuilder private func page(_ route: ContextDestination) -> some View {
    switch route {
    case .reference(let id): ReferenceView(service: service, id: id)
    case .event(let item, let id): WorkEventView(itemID: item, id: id)
    case .eventLibrary(let item, let id):
      ContextCollection(service: service, itemID: item, library: true, eventID: id)
    case .library, .history:
      ContextCollection(service: service, itemID: itemID, library: route == .library)
    }
  }
}

private struct ContextCollection: View {
  let service: any ContextReading
  let itemID: String
  let library: Bool
  var eventID: String? = nil
  @State private var refs: [ContextReference] = []
  @State private var moments: [ContextMoment] = []
  @State private var cursor: String?
  @State private var busy = false
  @State private var loaded = false
  @State private var issue: String?
  @State private var weekOnly = false
  @State private var filterSince: String?
  @State private var reloadID = UUID()
  @EnvironmentObject private var model: WorkspaceModel

  var body: some View {
    List {
      if !library {
        Toggle("只看最近七天", isOn: $weekOnly)
          .onChange(of: weekOnly) { _, _ in reloadID = UUID() }
      }
      if library {
        ForEach(refs) { ref in
          NavigationLink(value: ContextDestination.reference(ref.id)) {
            VStack(alignment: .leading, spacing: 4) {
              Label(ref.material.title, systemImage: symbol(ref.material.kind)).font(.headline)
              Text(
                [ref.purpose, ref.locator, "v\(ref.revision)"].compactMap { $0 }.joined(
                  separator: " · ")
              ).font(.caption)
              if let note = ref.note { Text(note).font(.callout).lineLimit(2) }
            }.padding(.vertical, 4)
          }
        }
      } else {
        ForEach(moments) { e in
          NavigationLink(
            value: e.referenceID.map(ContextDestination.reference) ?? .event(itemID, e.id)
          ) {
            VStack(alignment: .leading, spacing: 4) {
              Text(e.kind == "event" ? model.state.label(.event, e.title) : e.title).font(.headline)
              if let value = e.text { Text(value).font(.callout).lineLimit(2) }
              Text(e.actor + " · " + RelayDate.long(e.time)).font(.caption).foregroundStyle(
                .secondary)
            }.padding(.vertical, 4)
          }
        }
      }
      if loaded && refs.isEmpty && moments.isEmpty && issue == nil {
        Text(library ? "还没有资料" : "这段时间没有更新").foregroundStyle(.secondary)
      }
      if let issue { Text(issue).foregroundStyle(RelayPalette.amber) }
      if busy {
        ProgressView()
      } else if cursor != nil || issue != nil {
        Button(issue == nil ? "载入更多" : "重试") {
          Task { await load(reset: !loaded, version: reloadID) }
        }
      }
    }.navigationTitle(library ? "全部资料" : "时间线")
      .task(id: reloadID) { await load(reset: true, version: reloadID) }
  }
  @MainActor private func load(reset: Bool, version: UUID) async {
    if reset {
      refs = []
      moments = []
      loaded = false
      cursor = nil
      filterSince = weekOnly ? Date.now.addingTimeInterval(-7 * 86400).ISO8601Format() : nil
    } else if busy {
      return
    }
    busy = true
    issue = nil
    defer { if version == reloadID { busy = false } }
    do {
      if library {
        let page = try await service.references(itemID, before: cursor, eventID: eventID)
        guard !Task.isCancelled, version == reloadID else { return }
        refs += page.items
        cursor = page.next
      } else {
        let page = try await service.contextHistory(itemID, since: filterSince, before: cursor)
        guard !Task.isCancelled, version == reloadID else { return }
        moments += page.items
        cursor = page.next
      }
      loaded = true
    } catch { if !Task.isCancelled, version == reloadID { issue = error.localizedDescription } }
  }
}

private func symbol(_ kind: String) -> String {
  switch kind {
  case "note": return "text.alignleft"
  case "link": return "link"
  case "image": return "photo"
  default: return "paperclip"
  }
}

private struct ReferenceView: View {
  let service: any ContextReading
  let id: String
  @State private var ref: ContextReference?
  @State private var issue: String?
  @State private var preview: URL?
  @State private var file: URL?
  @State private var thumbnail: CGImage?
  @State private var attempt = 0

  var body: some View {
    RelayPage(maxWidth: 720) { _ in
      if let ref {
        RelayPanel(spacing: 10) {
          Label(ref.material.title, systemImage: symbol(ref.material.kind)).font(.title3.bold())
          Text(
            [
              ref.purpose, ref.locator, "引用 v\(ref.revision)",
              ref.latestRevision > ref.revision ? "最新 v\(ref.latestRevision)" : nil,
              ref.material.sourceVersion.map { "来源版本 " + $0 },
            ].compactMap { $0 }.joined(separator: " · ")
          ).font(.caption).foregroundStyle(.secondary)
          if let note = ref.note { Text(note).textSelection(.enabled) }
          Text([ref.actor, ref.source, RelayDate.long(ref.time)].joined(separator: " · ")).font(
            .caption
          ).foregroundStyle(.secondary)
          if let newer = ref.latestReferenceID {
            NavigationLink(
              "查看新版 v\(ref.latestRevision)", value: ContextDestination.reference(newer))
          }
          if let event = ref.eventID {
            NavigationLink("关联工作记录", value: ContextDestination.event(ref.itemID, event))
          }
        }
        RelayPanel(spacing: 10) {
          if let url = ref.originalURL {
            Link(destination: url) { Label("打开原文", systemImage: "arrow.up.right.square") }
            Text(url.host ?? url.absoluteString).font(.caption).foregroundStyle(.secondary)
          } else if let body = ref.material.body {
            Text(body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          } else {
            if let thumbnail {
              Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
                .frame(maxHeight: 320).accessibilityLabel(ref.material.title)
            }
            Text(ref.material.filename ?? "附件").font(.headline)
            if let size = ref.material.bytes {
              Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(
                .caption
              ).foregroundStyle(.secondary)
            }
            if let file {
              HStack {
                Button("预览附件") { preview = file }
                ShareLink(item: file) { Label("保存或分享", systemImage: "square.and.arrow.up") }
              }
            } else if issue == nil {
              ProgressView("正在读取附件…")
            }
          }
        }
      } else if issue == nil {
        ProgressView("正在读取资料…")
      }
      if let issue {
        Text(issue).foregroundStyle(RelayPalette.amber)
        Button("重试") { attempt += 1 }
      }
    }.navigationTitle("资料详情")
      .quickLookPreview($preview)
      .task(id: attempt) {
        do {
          issue = nil
          let result = try await service.reference(id)
          try Task.checkCancellation()
          ref = result
          if result.material.digest != nil {
            let data = try await service.fileBytes(result)
            try Task.checkCancellation()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
              UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
              at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
              let raw = result.material.filename ?? "附件"
              let name =
                raw != "." && raw != ".." && !raw.isEmpty && raw.utf8.count <= 240
                  && raw == (raw as NSString).lastPathComponent ? raw : "附件"
              let local = dir.appendingPathComponent(name)
              try data.write(to: local, options: .atomic)
              if result.material.kind == "image",
                let image = CGImageSourceCreateWithData(data as CFData, nil)
              {
                thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  image, 0,
                  [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 960,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary)
              }
              file = local
            } catch {
              try? FileManager.default.removeItem(at: dir)
              throw error
            }
          }
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      }.onDisappear {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        file = nil
        thumbnail = nil
      }
  }
}

private struct WorkEventView: View {
  @EnvironmentObject private var model: WorkspaceModel
  let itemID: String
  let id: String
  var body: some View {
    RelayPage { _ in
      if let event = model.state.history(itemID).first(where: {
        $0.id.uuidString.lowercased() == id.lowercased()
      }) {
        RelayPanel {
          PanelTitle(model.state.label(.event, event.change.operation.rawValue))
          Text(event.actor + " · " + RelayDate.long(event.time)).font(.caption)
          NavigationLink("查看这次记录的依据", value: ContextDestination.eventLibrary(itemID, id))
          if let note = event.change.note { Text(note).textSelection(.enabled) }
          if let title = event.change.title { Text(title) }
          if let next = event.change.next { Text("下一步 · " + next) }
          if let status = event.change.status { Text(status) }
          if let recipient = event.change.recipient { Text("交给 " + recipient) }
          if let payload = event.change.payload {
            ForEach(payload.keys.sorted(), id: \.self) { k in
              Text(k + " · " + (payload[k]?.display ?? ""))
            }
          }
          Text([event.source, event.session].compactMap { $0 }.joined(separator: " · ")).font(
            .caption
          ).foregroundStyle(.secondary)
        }
      } else {
        ContentUnavailableView("工作记录尚未同步", systemImage: "clock")
      }
    }.navigationTitle("工作记录")
  }
}

struct ContextSearchView: View {
  let service: any ContextReading
  let open: (String) -> Void
  @State private var query = ""
  @State private var hits: [ContextMatch] = []
  @State private var issue: String?
  @State private var searching = false
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading) {
      TextField("输入记得的词、资料名或一句描述", text: $query).textFieldStyle(.roundedBorder).focused($focused)
        .padding()
      if searching { ProgressView().padding(.horizontal) }
      if let issue { Text(issue).foregroundStyle(RelayPalette.amber).padding(.horizontal) }
      if !searching && issue == nil && hits.isEmpty && !query.isEmpty {
        ContentUnavailableView("没有找到相关事项", systemImage: "magnifyingglass")
      }
      List(hits) { hit in
        Button {
          open(hit.itemID)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(hit.title).font(.headline)
            Text(hit.match).font(.callout).lineLimit(3).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
    }.onAppear { focused = true }.task(id: query) {
      hits = []
      issue = nil
      let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !q.isEmpty else {
        searching = false
        return
      }
      searching = true
      do {
        try await Task.sleep(for: .milliseconds(250))
        let result = try await service.findContext(q)
        try Task.checkCancellation()
        hits = result
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      if !Task.isCancelled { searching = false }
    }
  }
}
