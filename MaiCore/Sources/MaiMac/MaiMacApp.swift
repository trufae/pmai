import AppKit
import MaiCLI
import SwiftUI

/// The app is also its own stdio worker. There is only one copy of the engine
/// in the bundle, and worker startup never initializes AppKit or a window.
@main
enum MaiMacEntry {
  @MainActor static func main() async {
    if CommandLine.arguments.dropFirst().contains(where: { !$0.hasPrefix("-psn_") }) {
      await MaiCLI.main()
    } else {
      MaiMacApp.main()
    }
  }
}

@MainActor
struct MaiMacApp: App {
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
  @State private var workspace = MacWorkspace()

  var body: some Scene {
    Window("pmai", id: "workspace") {
      MacWorkspaceView(workspace: workspace)
        .frame(minWidth: 780, minHeight: 520)
        .task { delegate.workspace = workspace; await workspace.restore() }
    }
    .defaultSize(width: 1180, height: 780)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Chat") { workspace.newChat() }.keyboardShortcut("n")
          .disabled(workspace.cwd.isEmpty || workspace.busy)
        Button("Open Workspace…") { workspace.chooseFolder() }.keyboardShortcut("o")
        Button("Connect to Host…") { workspace.showConnection = true }
          .keyboardShortcut("k", modifiers: [.command, .shift])
      }
      CommandMenu("Conversation") {
        Button("Stop Response") { workspace.selected?.stop() }.keyboardShortcut(".")
          .disabled(workspace.selected?.busy != true)
        Button("Refresh Conversations") { Task { await workspace.refresh() } }
          .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Open in Terminal") { workspace.openTerminal() }
          .disabled(workspace.hostID != nil || workspace.cwd.isEmpty)
      }
      SidebarCommands()
    }
    Settings {
      MacSettingsView(workspace: workspace)
    }
  }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  weak var workspace: MacWorkspace?
  private var terminating = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating, let workspace else { return .terminateNow }
    terminating = true
    Task {
      await workspace.close()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
