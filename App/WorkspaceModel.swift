import CryptoKit
import Foundation
import RelayCore
import SwiftUI
import UserNotifications

enum DeviceNotificationStatus: Equatable {
  case reading, needsPermission, denied, authorized
  case unavailable(String)

  var text: String {
    switch self {
    case .reading: return "正在读取通知设置"
    case .needsPermission: return "尚未授权本机通知"
    case .denied:
      #if os(macOS)
        return "系统通知已关闭。前往“系统设置”里的“通知”，选择 Relay Workspace 后打开“允许通知”。"
      #else
        return "系统通知已关闭。前往“设置”里的“通知”，选择 Relay Workspace 后打开“允许通知”。"
      #endif
    case .authorized: return "已获系统授权"
    case .unavailable(let reason): return reason
    }
  }
}

@MainActor
final class WorkspaceModel: ObservableObject {
  @Published private(set) var state = Workspace()
  @Published private(set) var root = Journal.local.root
  @Published private(set) var serverAddress: String?
  @Published private(set) var sourceIssue: String?
  @Published private(set) var hasSnapshot = false
  @Published private(set) var viewer: String?
  @Published var problem: String?
  @Published private(set) var notificationStatus = DeviceNotificationStatus.reading
  @Published private(set) var notificationRequestError: String?
  @Published var actor: String {
    didSet { UserDefaults.standard.set(actor, forKey: "relay.actor") }
  }
  var currentActor: String { viewer ?? actor }
  var workspaceLabel: String {
    if let serverAddress { return URL(string: serverAddress)?.host ?? serverAddress }
    return root == Journal.local.root ? "本机工作空间" : root.lastPathComponent
  }
  var usesSavedToken: Bool { serverAddress.map(hasToken) ?? false }
  private let alerts = LocalAlerts()
  private var journal: WorkspaceJournal?
  private var grant: URL?
  private var started = false
  private var generation = 0
  private var choice = 0
  private var readSerial = 0
  private var etag: String?

  init() {
    #if os(macOS)
      let defaultActor = NSUserName()
    #else
      let defaultActor = "我"
    #endif
    let defaults = UserDefaults.standard
    actor = defaults.string(forKey: "relay.actor") ?? defaultActor
    let mode = defaults.string(forKey: "relay.mode")
    if mode == "server" || (mode != "folder" && defaults.data(forKey: "relay.folder") == nil) {
      serverAddress = defaults.string(forKey: "relay.server") ?? RemoteJournal.defaultAddress
    }
  }

  func hasToken(_ address: String) -> Bool {
    guard let url = try? RemoteJournal.endpoint(address) else { return false }
    return UserDefaults.standard.stringArray(forKey: "relay.savedTokens")?.contains(
      url.absoluteString) == true
  }

  func start() async {
    guard !started else { return }
    started = true
    if let serverAddress {
      do {
        let endpoint = try RemoteJournal.endpoint(serverAddress)
        let token = hasToken(endpoint.absoluteString) ? try ServerCredentials.read(endpoint) : nil
        journal = .server(try RemoteJournal(address: serverAddress, token: token))
      } catch { sourceIssue = error.localizedDescription }
      return
    }
    if let data = UserDefaults.standard.data(forKey: "relay.folder") {
      do {
        var stale = false
        #if os(macOS)
          let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
          let options: URL.BookmarkResolutionOptions = []
        #endif
        let url = try URL(
          resolvingBookmarkData: data, options: options, relativeTo: nil,
          bookmarkDataIsStale: &stale)
        try await openFolder(url)
      } catch is CancellationError { return } catch {
        sourceIssue = "请在工作空间设置中重新选择共享文件夹。\(error.localizedDescription)"
      }
    } else {
      journal = .folder(.local)
    }
  }

  func retry() async {
    if journal == nil {
      started = false
      await start()
    }
    await refresh()
  }

  private func reset(to source: WorkspaceJournal) {
    generation += 1
    journal = source
    etag = nil
    sourceIssue = nil
    viewer = nil
    hasSnapshot = false
    state = Workspace()
  }

  // Probe and decode the new service before replacing the active journal.
  func connect(_ address: String, token newToken: String) async throws {
    choice += 1
    let attempt = choice
    let url = try RemoteJournal.endpoint(address)
    let supplied = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let token =
      supplied.isEmpty && hasToken(url.absoluteString) ? try ServerCredentials.read(url) : supplied
    let remote = try RemoteJournal(address: url.absoluteString, token: token)
    let update = try await remote.read()
    guard attempt == choice else { throw CancellationError() }
    if !supplied.isEmpty {
      try ServerCredentials.save(supplied, for: url)
      var saved = Set(UserDefaults.standard.stringArray(forKey: "relay.savedTokens") ?? [])
      saved.insert(url.absoluteString)
      UserDefaults.standard.set(Array(saved), forKey: "relay.savedTokens")
    }
    grant?.stopAccessingSecurityScopedResource()
    grant = nil
    reset(to: .server(remote))
    serverAddress = url.absoluteString
    UserDefaults.standard.set(url.absoluteString, forKey: "relay.server")
    UserDefaults.standard.set("server", forKey: "relay.mode")
    apply(update)
    await updateNotifications(version: generation, serial: readSerial)
  }

  func openFolder(_ url: URL?) async throws {
    choice += 1
    let attempt = choice
    let folder = url.map(Journal.init) ?? .local
    let scoped = url?.startAccessingSecurityScopedResource() == true
    do {
      let source = WorkspaceJournal.folder(folder)
      let update = try await source.read()
      guard attempt == choice else { throw CancellationError() }
      let defaults = UserDefaults.standard
      if let url {
        #if os(macOS)
          let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
          let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        let bookmark = try url.bookmarkData(
          options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "relay.folder")
      } else {
        defaults.removeObject(forKey: "relay.folder")
      }
      grant?.stopAccessingSecurityScopedResource()
      grant = scoped ? url : nil
      root = folder.root
      reset(to: source)
      serverAddress = nil
      defaults.set("folder", forKey: "relay.mode")
      apply(update)
      await updateNotifications(version: generation, serial: readSerial)
    } catch {
      if scoped { url?.stopAccessingSecurityScopedResource() }
      throw error
    }
  }

  private func apply(_ update: JournalUpdate) {
    if let snapshot = update.workspace {
      state = snapshot
      viewer = update.viewer
      hasSnapshot = true
    }
    etag = update.etag
    sourceIssue = nil
  }

  func refresh() async {
    guard let journal else { return }
    let version = generation
    readSerial += 1
    let serial = readSerial
    do {
      let update = try await journal.read(ifNoneMatch: etag)
      guard version == generation, serial == readSerial else { return }
      apply(update)
    } catch {
      guard version == generation, serial == readSerial, !Task.isCancelled else { return }
      sourceIssue = error.localizedDescription
      return
    }
    await updateNotifications(version: version, serial: serial)
  }

  private func updateNotifications(version: Int, serial: Int) async {
    let scope = serverAddress ?? root.standardizedFileURL.path
    do {
      let status = try await alerts.reconcile(state, actor: currentActor, scope: scope)
      if version == generation, serial == readSerial {
        notificationStatus = status
        if status != .needsPermission { notificationRequestError = nil }
      }
    } catch {
      if version == generation, serial == readSerial {
        notificationStatus = .unavailable(notificationMessage(error))
      }
    }
  }

  func submit(_ change: Change, id: UUID) async throws {
    guard let journal else { throw RelayError("请先连接工作空间") }
    let writer = currentActor.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await journal.append(change, id: id, actor: writer, source: "Relay App")
    await refresh()
  }
  func authorizeNotifications() async {
    notificationRequestError = nil
    do {
      _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
      await refresh()
    } catch { notificationRequestError = notificationMessage(error) }
  }

  private func notificationMessage(_ error: Error) -> String {
    let cause = error as NSError
    if cause.domain == UNErrorDomain, cause.code == UNError.Code.notificationsNotAllowed.rawValue {
      return "系统未允许此应用发送通知。可以在系统通知设置中查看 Relay Workspace。"
    }
    return "本机通知暂不可用。" + cause.localizedDescription
  }
}

@MainActor
private final class LocalAlerts: NSObject, UNUserNotificationCenterDelegate {
  func reconcile(_ state: Workspace, actor: String, scope: String) async throws
    -> DeviceNotificationStatus
  {
    guard Bundle.main.bundleIdentifier != nil else { return .unavailable("在应用程序包内启用通知") }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let settings = await center.notificationSettings()
    guard
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    else {
      return settings.authorizationStatus == .denied ? .denied : .needsPermission
    }
    let namespace = SHA256.hash(data: Data(scope.utf8)).prefix(8).map {
      String(format: "%02x", $0)
    }.joined()
    let prefix = "relay." + namespace + "."
    let now = Date()
    let eligible = state.entries.filter { e in
      guard let due = e.change.due, state.reminderIsCurrent(e),
        [actor, "*"].contains(e.change.recipient ?? "")
      else { return false }
      return e.change.reference == nil || due <= now
    }.sorted { ($0.change.due ?? now) < ($1.change.due ?? now) }
    let key = "relay.registeredNotifications"
    var registered = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    let planned = eligible.filter { e in
      (e.change.due ?? now) > now || !registered.contains(prefix + e.id.uuidString)
    }.prefix(48)
    let pending = await center.pendingNotificationRequests()
    let currentIDs = Set(pending.map(\.identifier))
    // Keep an already registered due notification until the OS actually delivers it.
    let valid = Set(eligible.map { prefix + $0.id.uuidString })
    center.removePendingNotificationRequests(
      withIdentifiers: currentIDs.filter { $0.hasPrefix("relay.") && !valid.contains($0) })
    for e in planned {
      let id = prefix + e.id.uuidString
      guard !currentIDs.contains(id), let due = e.change.due else { continue }
      let body = UNMutableNotificationContent()
      body.title = state.items[e.change.itemID]?.title ?? "Relay 回看提醒"
      body.body = e.change.note ?? "回看事项进展"
      body.sound = .default
      body.userInfo = ["itemID": e.change.itemID]
      let trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: max(1, due.timeIntervalSinceNow), repeats: false)
      try await center.add(UNNotificationRequest(identifier: id, content: body, trigger: trigger))
      registered.insert(id)
      UserDefaults.standard.set(Array(registered), forKey: key)
    }
    return .authorized
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
