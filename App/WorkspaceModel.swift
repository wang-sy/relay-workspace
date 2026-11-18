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
  @Published var problem: String?
  @Published private(set) var notificationStatus = DeviceNotificationStatus.reading
  @Published private(set) var notificationRequestError: String?
  @Published var actor: String {
    didSet { UserDefaults.standard.set(actor, forKey: "relay.actor") }
  }
  private let alerts = LocalAlerts()
  private var grant: URL?
  private var ready = false
  private var started = false
  private var generation = 0
  private var readSerial = 0

  init() {
    #if os(macOS)
      let defaultActor = NSUserName()
    #else
      let defaultActor = "我"
    #endif
    actor = UserDefaults.standard.string(forKey: "relay.actor") ?? defaultActor
  }

  func start() async {
    guard !started else { return }
    started = true
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
        try attach(url)
      } catch {
        problem = "请在工作空间设置中重新选择共享文件夹。\(error.localizedDescription)"
        return
      }
    } else {
      ready = true
      do { try await Task.detached { try Journal.local.installExampleIfEmpty() }.value } catch {
        problem = error.localizedDescription
        return
      }
    }
    await refresh()
  }

  private func attach(_ url: URL) throws {
    let scoped = url.startAccessingSecurityScopedResource()
    do {
      #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
      #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
      #endif
      let bookmark = try url.bookmarkData(
        options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
      _ = try Journal(url).read()
      UserDefaults.standard.set(bookmark, forKey: "relay.folder")
    } catch {
      if scoped { url.stopAccessingSecurityScopedResource() }
      throw error
    }
    grant?.stopAccessingSecurityScopedResource()
    grant = scoped ? url : nil
    root = url
    ready = true
    generation += 1
    state = Workspace()
  }

  func select(_ url: URL?) async {
    do {
      if let url {
        try attach(url)
      } else {
        UserDefaults.standard.removeObject(forKey: "relay.folder")
        grant?.stopAccessingSecurityScopedResource()
        grant = nil
        generation += 1
        root = Journal.local.root
        ready = true
        state = Workspace()
      }
      await refresh()
    } catch { problem = error.localizedDescription }
  }

  func refresh() async {
    guard ready else { return }
    let version = generation
    let journal = Journal(root)
    readSerial += 1
    let serial = readSerial
    let snapshot: Workspace
    do {
      snapshot = try await Task.detached(priority: .utility) { try journal.read() }.value
    } catch {
      if version == generation, serial == readSerial { problem = error.localizedDescription }
      return
    }
    guard version == generation, serial == readSerial else { return }
    state = snapshot
    do {
      let status = try await alerts.reconcile(snapshot, actor: actor, root: root)
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
    guard ready else { throw RelayError("请先选择可用的工作空间") }
    let journal = Journal(root)
    let writer = actor.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await Task.detached {
      try journal.append(change, id: id, actor: writer, source: "Relay App")
    }.value
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
  func reconcile(_ state: Workspace, actor: String, root: URL) async throws
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
    let namespace = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map {
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
