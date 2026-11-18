import RelayCore
import SwiftUI

@main
struct RelayApp: App {
  @StateObject private var model = WorkspaceModel()
  var body: some Scene {
    WindowGroup {
      WorkspaceView().environmentObject(model)
    }
    #if os(macOS)
      .defaultSize(width: 1100, height: 740)
    #endif
  }
}
