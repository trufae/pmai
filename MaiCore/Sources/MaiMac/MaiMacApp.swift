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
  @State private var backend = MacBackend()

  var body: some Scene {
    WindowGroup("pmai", id: "workspace") {
      MacWorkspaceWindow(backend: backend)
        .frame(minWidth: 780, minHeight: 520)
        .onAppear { delegate.backend = backend }
    }
    .defaultSize(width: 1180, height: 780)
    .commands {
      MacWorkspaceCommands()
      SidebarCommands()
      MacChatFontCommands()
    }
    Settings {
      MacSettingsWindow(backend: backend)
    }
  }
}

private struct MacWorkspaceWindow: View {
  @State private var workspace: MacWorkspace
  @Environment(\.appearsActive) private var appearsActive

  init(backend: MacBackend) {
    _workspace = State(initialValue: MacWorkspace(backend: backend))
  }

  var body: some View {
    MacWorkspaceView(workspace: workspace)
      .focusedSceneValue(\.macWorkspace, workspace)
      .task { await workspace.restore() }
      .onChange(of: appearsActive, initial: true) { _, active in
        if active { workspace.backend.activeWorkspace = workspace }
      }
  }
}

private struct MacSettingsWindow: View {
  let backend: MacBackend
  @State private var fallbackWorkspace: MacWorkspace

  init(backend: MacBackend) {
    self.backend = backend
    _fallbackWorkspace = State(initialValue: MacWorkspace(backend: backend))
  }

  var body: some View {
    MacSettingsView(workspace: backend.activeWorkspace ?? fallbackWorkspace)
  }
}

private struct MacWorkspaceKey: FocusedValueKey {
  typealias Value = MacWorkspace
}

extension FocusedValues {
  var macWorkspace: MacWorkspace? {
    get { self[MacWorkspaceKey.self] }
    set { self[MacWorkspaceKey.self] = newValue }
  }
}

private struct MacWorkspaceCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.macWorkspace) private var workspace

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Chat") { workspace?.newChat() }.keyboardShortcut("n")
        .disabled(workspace == nil || workspace?.cwd.isEmpty == true || workspace?.busy == true)
      Button("New Window") { openWindow(id: "workspace") }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Button("Open Workspace…") { workspace?.chooseFolder() }.keyboardShortcut("o")
        .disabled(workspace == nil)
      Button("Connect to Host…") { workspace?.showConnection = true }
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(workspace == nil)
    }
    CommandMenu("Conversation") {
      Button("Stop Response") { workspace?.selected?.stop() }.keyboardShortcut(".")
        .disabled(workspace?.selected?.busy != true)
      Button("Refresh Conversations") { Task { await workspace?.refresh() } }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(workspace == nil)
      Button("Open in Terminal") { workspace?.openTerminal() }
        .disabled(workspace == nil || workspace?.hostID != nil || workspace?.cwd.isEmpty == true)
    }
  }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  weak var backend: MacBackend?
  private var terminating = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating, let backend else { return .terminateNow }
    terminating = true
    Task {
      await backend.close()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
