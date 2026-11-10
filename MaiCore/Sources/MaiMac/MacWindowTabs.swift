import AppKit
import Observation
import SwiftUI

@MainActor
final class MacWindowLaunch: ObservableObject {
  let workspace: MacWorkspace

  init(workspace: MacWorkspace) {
    self.workspace = workspace
  }
}

/// Each native tab has its own navigation, while the backend owns shared chats.
@MainActor @Observable
final class MacWindowTabs: NSObject {
  private struct Entry {
    weak var window: NSWindow?
    let workspace: MacWorkspace
    let controller: NSWindowController?
  }

  @ObservationIgnored private var windows: [ObjectIdentifier: Entry] = [:]
  @ObservationIgnored private var pending: [UUID: MacWindowLaunch] = [:]
  private var closed: [MacWorkspace] = []

  var canReopen: Bool { !closed.isEmpty }

  override init() {
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)),
      name: NSWindow.willCloseNotification, object: nil)
  }

  func launch(for id: UUID?, backend: MacBackend) -> MacWindowLaunch {
    if let id, let launch = pending[id] { return launch }
    return MacWindowLaunch(workspace: MacWorkspace(backend: backend))
  }

  func newTab(backend: MacBackend, openWindow: (UUID) -> Void) {
    let parent = activeWindow
    let workspace = MacWorkspace(backend: backend, inheriting: parent.flatMap {
      windows[ObjectIdentifier($0)]?.workspace
    })
    open(workspace, beside: parent, openWindow: openWindow)
  }

  func reopenLast(openWindow: (UUID) -> Void) {
    guard let workspace = closed.popLast() else { return }
    open(workspace, beside: activeWindow, openWindow: openWindow)
  }

  func selectTab(at index: Int) {
    guard let tabs = activeWindow?.tabbedWindows, tabs.indices.contains(index) else { return }
    tabs[index].makeKeyAndOrderFront(nil)
  }

  private var activeWindow: NSWindow? {
    for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
      if windows[ObjectIdentifier(window)] != nil { return window }
    }
    return nil
  }

  private func open(_ workspace: MacWorkspace, beside parent: NSWindow?, openWindow: (UUID) -> Void) {
    if let parent {
      // Join the native group before showing the tab. SwiftUI's openWindow
      // presents a standalone window before its content mounts.
      let launch = MacWindowLaunch(workspace: workspace)
      let window = NSWindow(contentRect: parent.contentRect(forFrameRect: parent.frame),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: true)
      window.contentMinSize = NSSize(width: 780, height: 520)
      window.collectionBehavior = .fullScreenPrimary
      window.toolbarStyle = .unified
      let controller = NSWindowController(window: window)
      attach(window, launch: launch, requestID: nil, controller: controller)
      window.contentViewController = NSHostingController(rootView:
        MacWorkspaceContent(tabs: self, launch: launch, requestID: nil))
      parent.addTabbedWindow(window, ordered: .above)
      window.makeKeyAndOrderFront(nil)
      return
    }
    let id = UUID()
    pending[id] = MacWindowLaunch(workspace: workspace)
    openWindow(id)
  }

  func attach(_ window: NSWindow, launch: MacWindowLaunch, requestID: UUID?,
    controller: NSWindowController? = nil) {
    let key = ObjectIdentifier(window)
    guard windows[key] == nil else { return }
    window.tabbingIdentifier = "pmai-workspace"
    window.tabbingMode = .automatic
    windows[key] = Entry(window: window, workspace: launch.workspace, controller: controller)
    if let requestID { pending[requestID] = nil }
  }

  @objc private func windowClosed(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
    // Keep navigation and the selected conversation, including its unsent draft.
    // Closing a tab never stops or disconnects the shared conversation.
    closed.append(entry.workspace)
  }
}

struct MacWindowTabBridge: NSViewRepresentable {
  let tabs: MacWindowTabs
  let launch: MacWindowLaunch
  let requestID: UUID?
  let title: String

  func makeNSView(context: Context) -> WindowProbe { WindowProbe() }

  func updateNSView(_ view: WindowProbe, context: Context) {
    view.attach = { window in
      tabs.attach(window, launch: launch, requestID: requestID)
      if window.title != title { window.title = title }
      if window.tab.title != title { window.tab.title = title }
    }
    view.updateWindow()
  }

  final class WindowProbe: NSView {
    var attach: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateWindow()
    }
    func updateWindow() {
      // The registry is not observed; registration need not schedule another render.
      guard let window else { return }
      attach?(window)
    }
  }
}
