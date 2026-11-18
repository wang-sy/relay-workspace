import Foundation

/// Each accepted write has a separate immutable file so offline writers do not replace a whole workspace snapshot.
public struct Journal: Sendable {
  public let root: URL
  private var folder: URL { root.appendingPathComponent("RelayEvents", isDirectory: true) }
  public init(_ root: URL) { self.root = root.standardizedFileURL }
  public static var local: Journal {
    Journal(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Relay Workspace/Local", isDirectory: true))
  }
  private func coordinate<T>(write: Bool, _ body: @escaping (URL) throws -> T) throws -> T {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var result: Result<T, Error>?
    let access: (URL) -> Void = { url in result = Result { try body(url) } }
    if write {
      coordinator.coordinate(
        writingItemAt: folder, options: .forMerging, error: &coordinationError, byAccessor: access)
    } else {
      coordinator.coordinate(
        readingItemAt: folder, options: [], error: &coordinationError, byAccessor: access)
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw RelayError("Workspace folder is unavailable") }
    return try result.get()
  }

  private func load(at folder: URL) throws -> (Workspace, Int) {
    let fm = FileManager.default
    let files = try fm.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])
    var events: [UUID: Entry] = [:]
    for url in files {
      if url.pathExtension == "icloud" {
        let name = String(url.deletingPathExtension().lastPathComponent.dropFirst())
        if name.hasSuffix(".json") {
          try fm.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(name))
          throw RelayError("正在从 iCloud 下载工作记录")
        }
      }
      guard url.pathExtension == "json" else { continue }
      if let status = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        .ubiquitousItemDownloadingStatus, status == .notDownloaded
      {
        try fm.startDownloadingUbiquitousItem(at: url)
        throw RelayError("正在从 iCloud 下载工作记录")
      }
      let data = try Data(contentsOf: url)
      let batch: [Entry]
      if url.lastPathComponent == "Starter.json" {
        batch = try Wire.decoder().decode([Entry].self, from: data)
      } else {
        batch = [try Wire.decoder().decode(Entry.self, from: data)]
      }
      for entry in batch {
        if let existing = events[entry.id], existing != entry {
          throw RelayError("Conflicting copies of event " + entry.id.uuidString)
        }
        events[entry.id] = entry
      }
    }
    var workspace = Workspace()
    let sorted = events.values.sorted { a, b in
      a.sequence == b.sequence ? a.id.uuidString < b.id.uuidString : a.sequence < b.sequence
    }
    for entry in sorted { workspace.replay(entry) }
    return (workspace, sorted.last?.sequence ?? 0)
  }

  public func read() throws -> Workspace { try coordinate(write: false) { try load(at: $0).0 } }

  public func installExampleIfEmpty() throws {
    try coordinate(write: true) { dir in
      guard try load(at: dir).1 == 0 else { return }
      try Wire.encoder(pretty: true).encode(Example.entries(at: Date())).write(
        to: dir.appendingPathComponent("Starter.json"), options: .atomic)
    }
  }

  @discardableResult
  public func append(
    _ change: Change, id: UUID = UUID(), actor: String, source: String, session: String? = nil,
    time: Date = Date()
  ) throws -> Entry {
    // Normalize timestamps to the portable wire precision, including comparisons on retry.
    let canonical = try Wire.decoder().decode(Change.self, from: Wire.encoder().encode(change))
    return try coordinate(write: true) { dir in
      let file = dir.appendingPathComponent(id.uuidString.lowercased() + ".json")
      if FileManager.default.fileExists(atPath: file.path) {
        let old = try Wire.decoder().decode(Entry.self, from: Data(contentsOf: file))
        guard
          old.change == canonical && old.actor == actor && old.source == source
            && old.session == session
        else {
          throw RelayError("This request ID is bound to a different write")
        }
        return old
      }
      var (workspace, sequence) = try load(at: dir)
      if canonical.operation == .close, workspace.items[canonical.itemID]?.kind == .requirement,
        (canonical.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw RelayError("请写清楚这个需求完成了什么")
      }
      guard !workspace.entries.contains(where: { $0.id == id }) else {
        throw RelayError("Reserved event ID")
      }
      let entry = Entry(
        id: id, sequence: sequence + 1,
        time: Date(timeIntervalSince1970: floor(time.timeIntervalSince1970)), actor: actor,
        source: source, session: session, change: canonical)
      try workspace.apply(entry)
      try Wire.encoder(pretty: true).encode(entry).write(to: file, options: .atomic)
      return entry
    }
  }
}
