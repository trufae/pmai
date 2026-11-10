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
  private var appearance = MacAppearance()

  var body: some Scene {
    WindowGroup("pmai", id: "workspace") {
      MacWorkspaceWindow(backend: backend)
        .modifier(MacWritingToolsDisabled())
        .tint(appearance.accentColor)
        .accentColor(appearance.accentColor)
        .frame(minWidth: 780, minHeight: 520)
        .onAppear { delegate.backend = backend }
    }
    .defaultSize(width: 1180, height: 780)
    .commands {
      MacWorkspaceCommands()
      MacChatFontCommands()
    }
    Settings {
      MacSettingsWindow(backend: backend)
        .modifier(MacWritingToolsDisabled())
        .tint(appearance.accentColor)
        .accentColor(appearance.accentColor)
    }
  }
}

private struct MacWritingToolsDisabled: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.4, *) {
      content.writingToolsBehavior(.disabled).writingToolsAffordanceVisibility(.hidden)
    } else {
      content.writingToolsBehavior(.disabled)
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

private struct MacSidebarVisibilityKey: FocusedValueKey {
  typealias Value = Binding<NavigationSplitViewVisibility>
}

extension FocusedValues {
  var macWorkspace: MacWorkspace? {
    get { self[MacWorkspaceKey.self] }
    set { self[MacWorkspaceKey.self] = newValue }
  }

  var macSidebarVisibility: Binding<NavigationSplitViewVisibility>? {
    get { self[MacSidebarVisibilityKey.self] }
    set { self[MacSidebarVisibilityKey.self] = newValue }
  }
}

private struct MacWorkspaceCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.macWorkspace) private var workspace
  @FocusedBinding(\.macSidebarVisibility) private var sidebarVisibility

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Chat") { workspace?.newChat() }.keyboardShortcut("n")
        .disabled(workspace == nil || workspace?.cwd.isEmpty == true || workspace?.busy == true)
      Button("New Window") { openWindow(id: "workspace") }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Button("Open Workspace…") { workspace?.chooseFolder() }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(workspace == nil)
      Button("Connect to Host…") { workspace?.showConnection = true }
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(workspace == nil)
    }
    CommandGroup(replacing: .sidebar) {
      Button("Toggle Sidebar") {
        withAnimation {
          sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(sidebarVisibility == nil)
      Button("Toggle Conversation Details") {
        withAnimation { workspace?.showInspector.toggle() }
      }
      .keyboardShortcut("o", modifiers: .command)
      .disabled(workspace?.selected == nil)
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
  private var updateCheck: Task<Void, Never>?

  func applicationDidFinishLaunching(_ notification: Notification) {
    updateCheck = Task {
      // A failed background check should never interrupt startup or offline use.
      guard let update = try? await CLIUpdater.availableUpdate(), !Task.isCancelled else { return }
      let alert = NSAlert()
      alert.messageText = "pmai \(update.version) is available"
      alert.informativeText = "Open the GitHub release page to download the new macOS DMG and replace pmai in Applications."
      alert.addButton(withTitle: "Open GitHub")
      alert.addButton(withTitle: "Later")
      if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(update.url)
      }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    updateCheck?.cancel()
    guard !terminating, let backend else { return .terminateNow }
    terminating = true
    Task {
      await backend.close()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
