import MaiACP
import MaiCore
import SwiftTerm
import SwiftUI

struct RemoteTerminalLocation: Identifiable {
  let host: RemoteAgentBookmark
  let cwd: String
  var id: String { [host.id.uuidString, host.revision?.uuidString ?? "", cwd].joined(separator: ":") }
  var title: String { "\(host.name) · \(URL(fileURLWithPath: cwd).lastPathComponent)" }
}

@MainActor
private final class RemoteTerminalController: ObservableObject {
  let id: UUID
  private let archiveURL: URL
  private var remoteID: String?
  private var offset = 0
  private var transcript = Data()
  private var location: RemoteTerminalLocation?
  private struct Archive: Codable {
    var remoteID: String?
    var offset: Int
    var transcript: Data
  }

  init(id: UUID, directory: URL) {
    self.id = id
    archiveURL = directory.appendingPathComponent(id.uuidString + ".session.json")
    if let data = try? Data(contentsOf: archiveURL), let archive = try? JSONDecoder().decode(Archive.self, from: data) {
      remoteID = archive.remoteID
      offset = archive.offset
      transcript = archive.transcript
    }
  }

  func replay() { view?.feed(byteArray: Array(transcript)[...]) }
  private func persist() throws {
    try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(Archive(remoteID: remoteID, offset: offset, transcript: transcript))
      .write(to: archiveURL, options: .atomic)
  }

  @Published var status = "Connecting…"
  @Published var error: String?
  weak var view: SwiftTerm.TerminalView?
  private var workspace: WorkspaceConnection?
  private var shell: RemoteTerminalSession?
  private var reader: Task<Void, Never>?
  private var writer: Task<Void, Never>?
  private var retry: Task<Void, Never>?
  private var command = ""
  private var historyCursor = RemoteTerminalHistoryCursor()
  private var fallback = false
  private var running = false
  private var closed = false
  private var size = (columns: 80, rows: 24)
  private var buffer = RemoteTerminalBuffer()
  private var historyFile: URL?
  private var outputCursor = ""

  func start(_ location: RemoteTerminalLocation, offline: Bool) {
    guard reader == nil, workspace == nil, !closed else { return }
    self.location = location
    reader = Task {
      defer { reader = nil }
      do {
        guard !offline else { throw InternetAccessError.offline }
        let workspace = try location.host.workspaceConnection(cwd: location.cwd, resumeID: id.uuidString)
        self.workspace = workspace
        if try await workspace.supportsInteractiveTerminal() {
          var attached: RemoteTerminalSession?
          if remoteID == nil { remoteID = try await workspace.terminalIDs().first }
          if let remoteID { attached = try await workspace.attachTerminal(id: remoteID) }
          let resumed = attached != nil
          if attached == nil {
            attached = try await workspace.openTerminal(columns: size.columns, rows: size.rows)
            remoteID = attached?.id
            offset = 0
            transcript = Data()
            view?.feed(text: "\u{1b}c")
          }
          let shell = attached!
          self.shell = shell
          try persist()
          try Task.checkCancellation()
          status = "Connected"
          if resumed { try await shell.resize(columns: size.columns == 1000 ? 999 : size.columns + 1, rows: size.rows) }
          try await shell.resize(columns: size.columns, rows: size.rows)
          while !Task.isCancelled {
            let chunk = try await shell.read(after: offset)
            try Task.checkCancellation()
            view?.feed(byteArray: Array(chunk.data)[...])
            transcript.append(chunk.data)
            // Keep recent output for repainting after an app restart. The PTY
            // itself and unread output stay on the host.
            if transcript.count > 2 * 1024 * 1024 {
              transcript = Data(transcript.suffix(1024 * 1024))
              if let newline = transcript.firstIndex(of: 10) { transcript.removeSubrange(...newline) }
            }
            offset = chunk.offset ?? offset + chunk.data.count
            try persist()
            if let code = chunk.exitCode {
              status = "Exited (\(code))"
              await shell.close()
              self.shell = nil
              remoteID = nil
              try persist()
              break
            }
          }
        } else {
          fallback = true
          status = "Command mode"
          loadHistory(location)
          feed("\r\nCommand mode: each command starts in \(location.cwd).\r\nInteractive programs require a pmai host with terminal support.\r\n")
          prompt()
        }
      } catch {
        if !closed && !Task.isCancelled { self.error = error.localizedDescription; status = "Disconnected" }
        await workspace?.close()
        workspace = nil
        shell = nil
        if !closed && !Task.isCancelled {
          retry?.cancel()
          retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !self.closed else { return }
            self.reconnect(offline: false)
          }
        }
      }
    }
  }

  func resize(columns: Int, rows: Int) {
    guard columns > 0, rows > 0 else { return }
    size = (min(1000, columns), min(1000, rows))
    enqueue { [weak self] in
      guard let self, let shell = self.shell else { return }
      try await shell.resize(columns: self.size.columns, rows: self.size.rows)
    }
  }

  func send(_ data: Data) {
    guard !closed else { return }
    if let shell { enqueue { try await shell.send(data) } }
    else if fallback { input(data) }
  }

  private func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
    let previous = writer
    writer = Task { [weak self] in
      await previous?.value
      guard let self, !self.closed, !Task.isCancelled else { return }
      do { try await action() } catch {
        if !self.closed { self.error = error.localizedDescription }
      }
    }
  }

  private func input(_ data: Data) {
    if running {
      if data.contains(3) { reader?.cancel() }
      return
    }
    let text = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\u{1b}[200~", with: "")
      .replacingOccurrences(of: "\u{1b}[201~", with: "")
    if text == "\u{1b}[A" || text == "\u{1b}[B" {
      command = historyCursor.move(text.hasSuffix("A") ? -1 : 1, command: command, history: buffer.history)
      redrawCommand()
      return
    }
    // This mode has no remote line discipline: unsupported control sequences
    // must never become commands, including bracketed-paste delimiters.
    if text.hasPrefix("\u{1b}") { return }
    if text.count > 1, text.contains("\n") || text.contains("\r") {
      let pasted = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      command.append(pasted)
      feed(pasted)
      return
    }
    for character in text {
      switch character {
      case "\r", "\n":
        feed("\r\n")
        let saved = command
        command = ""
        historyCursor.reset()
        run(saved)
        return
      case "\u{7f}", "\u{8}":
        if !command.isEmpty { command.removeLast(); redrawCommand() }
      case "\u{3}": command = ""; feed("^C\r\n"); prompt()
      case "\u{15}": command = ""; redrawCommand()
      default:
        if !character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
          command.append(character)
          feed(String(character))
        }
      }
    }
  }

  private func run(_ command: String) {
    guard let workspace, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { prompt(); return }
    let id = buffer.append(command)
    saveHistory()
    running = true
    status = "Running"
    reader = Task {
      do {
        let result = try await workspace.run(command) { [weak self] output in await self?.showOutput(output) }
        showOutput(result.text)
        buffer.update(id, output: result.text, isError: result.isError)
      } catch {
        if !closed {
          let message = Task.isCancelled ? "[stopped waiting; remote command may still be running]" : "Error: \(error.localizedDescription)"
          feed("\r\n" + message)
          buffer.update(id, output: outputCursor + "\n" + message, isError: true)
        }
      }
      guard !closed else { return }
      running = false
      outputCursor = ""
      status = "Command mode"
      saveHistory()
      feed("\r\n")
      prompt()
    }
  }

  private func showOutput(_ output: String) {
    guard !closed else { return }
    if output.hasPrefix(outputCursor) { feed(String(output.dropFirst(outputCursor.count))) }
    else { feed("\r\n" + output) }
    outputCursor = output
  }

  private func loadHistory(_ location: RemoteTerminalLocation) {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RemoteTerminals", isDirectory: true)
    let file = RemoteTerminalBuffer.fileURL(hostID: location.host.id, endpoint: location.host.url,
      cwd: location.cwd, directory: directory)
    historyFile = file
    buffer = .load(from: file)
    for entry in buffer.entries {
      feed("$ \(entry.command)\r\n")
      if let output = entry.output { feed(output + "\r\n") }
    }
  }

  private func saveHistory() {
    guard let historyFile else { return }
    do { try buffer.save(to: historyFile) } catch { self.error = "Couldn’t save history: \(error.localizedDescription)" }
  }

  private func feed(_ text: String) {
    view?.feed(text: text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
  }
  private func prompt() { feed("$ ") }
  private func redrawCommand() { feed("\r\u{1b}[2K$ " + command) }

  func reconnect(offline: Bool) {
    guard let location else { return }
    closed = false
    error = nil
    if workspace == nil { start(location, offline: offline) }
  }

  func endSession(offline: Bool) async -> Bool {
    guard !offline, let location else { error = "Connect to the host before closing this session."; return false }
    closed = true
    retry?.cancel()
    writer?.cancel()
    reader?.cancel()
    await reader?.value
    await writer?.value
    do {
      let connection = try location.host.workspaceConnection(cwd: location.cwd, resumeID: id.uuidString)
      // Each tab owns a resumable worker. Closing all also covers a lost open reply.
      if case .remote(let client, _) = connection, try await client.terminalSupported() {
        _ = try await client.terminal(["action": .string("close_all")])
      }
      await connection.close()
      remoteID = nil
      try persist()
      closed = false
      close()
      return true
    } catch { closed = false; self.error = error.localizedDescription; return false }
  }

  func close() {
    guard !closed else { return }
    closed = true
    retry?.cancel()
    reader?.cancel()
    writer?.cancel()
    buffer.interruptPending()
    saveHistory()
    let workspace = workspace
    self.workspace = nil
    shell = nil
    Task { await workspace?.close() }
  }
}

@MainActor
private final class RemoteTerminalDeck: ObservableObject {
  @Published var tabs: [RemoteTerminalController]
  @Published var selected: UUID
  private let index: URL
  private let directory: URL

  init(location: RemoteTerminalLocation) {
    directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RemoteTerminals", isDirectory: true)
    index = RemoteTerminalBuffer.fileURL(hostID: location.host.id, endpoint: location.host.url,
      cwd: location.cwd, directory: directory).appendingPathExtension("tabs")
    let saved = (try? Data(contentsOf: index)).flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? []
    let ids = saved.isEmpty ? [UUID()] : Array(saved.prefix(8))
    let sessionDirectory = directory
    tabs = ids.map { RemoteTerminalController(id: $0, directory: sessionDirectory) }
    selected = ids[0]
    save()
  }
  func add() {
    guard tabs.count < 8 else { return }
    let controller = RemoteTerminalController(id: UUID(), directory: directory)
    tabs.append(controller)
    selected = controller.id
    save()
  }
  func remove(_ tab: RemoteTerminalController, offline: Bool) async {
    guard await tab.endSession(offline: offline) else { return }
    tabs.removeAll { $0.id == tab.id }
    if selected == tab.id { selected = tabs.first?.id ?? UUID() }
    save()
  }
  private func save() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(tabs.map(\.id)).write(to: index, options: .atomic)
    } catch { tabs.first?.error = "Couldn’t save terminal tabs: \(error.localizedDescription)" }
  }
}

struct RemoteTerminalView: View {
  @EnvironmentObject private var appStore: AppStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  let location: RemoteTerminalLocation
  @StateObject private var deck: RemoteTerminalDeck
  @AppStorage("terminal.fontSize") private var fontSize = 14.0
  @State private var pinchBase: Double?
  @State private var keyboardVisible = false
  private var active: RemoteTerminalController? { deck.tabs.first { $0.id == deck.selected } }

  init(location: RemoteTerminalLocation) {
    self.location = location
    _deck = StateObject(wrappedValue: RemoteTerminalDeck(location: location))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button("Done") { dismiss() }
        Spacer(minLength: 0)
        Text(location.title).font(.caption).lineLimit(1)
        Spacer(minLength: 0)
        Menu("Terminal", systemImage: "ellipsis.circle") {
          Picker("Session", selection: $deck.selected) {
            ForEach(Array(deck.tabs.enumerated()), id: \.element.id) { index, tab in
              Text("Terminal \(index + 1)").tag(tab.id)
            }
          }
          Button("New Terminal", systemImage: "plus") { deck.add() }.disabled(deck.tabs.count >= 8)
          Button("Close Terminal", systemImage: "xmark", role: .destructive) {
            if let active { Task { await deck.remove(active, offline: appStore.settings.isOffline) } }
          }.disabled(active == nil || appStore.settings.isOffline)
          Divider()
          Button("Reconnect", systemImage: "arrow.clockwise") { active?.reconnect(offline: appStore.settings.isOffline) }
          Button(keyboardVisible ? "Hide Keyboard" : "Show Keyboard", systemImage: "keyboard") {
            guard let view = active?.view else { return }
            if keyboardVisible { view.resignFirstResponder() } else { view.becomeFirstResponder() }
          }
        }
      }
      .padding(.horizontal, 12).frame(height: 38)
      ZStack {
        if deck.tabs.isEmpty {
          Button("New Terminal", systemImage: "plus") { deck.add() }
        }
        ForEach(deck.tabs, id: \.id) { tab in
          TerminalSurface(controller: tab, location: location, offline: appStore.settings.isOffline,
            fontSize: fontSize, active: deck.selected == tab.id)
            .opacity(deck.selected == tab.id ? 1 : 0)
            .allowsHitTesting(deck.selected == tab.id)
            .accessibilityHidden(deck.selected != tab.id)
            .zIndex(deck.selected == tab.id ? 1 : 0)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .simultaneousGesture(MagnifyGesture()
        .onChanged { value in
          if pinchBase == nil { pinchBase = fontSize }
          fontSize = min(32, max(8, (pinchBase ?? fontSize) * value.magnification))
        }
        .onEnded { _ in fontSize = fontSize.rounded(); pinchBase = nil })
      if let active { TerminalStatus(controller: active) }
    }
    .background(.black).foregroundStyle(.white)
    .buttonStyle(.plain)
    .interactiveDismissDisabled()
    .presentationDetents([.large])
    .presentationDragIndicator(.hidden)
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in keyboardVisible = true }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardVisible = false }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { for tab in deck.tabs { tab.reconnect(offline: appStore.settings.isOffline) } }
    }
    .onChange(of: appStore.settings.isOffline) { _, offline in
      for tab in deck.tabs { if offline { tab.close() } else { tab.reconnect(offline: false) } }
    }
    .onDisappear { for tab in deck.tabs { tab.close() } }
  }
}

private struct TerminalStatus: View {
  @ObservedObject var controller: RemoteTerminalController
  var body: some View {
    if let error = controller.error {
      Text(error).font(.caption2).foregroundStyle(.red).padding(4)
    } else if controller.status != "Connected" {
      Text(controller.status).font(.caption2).foregroundStyle(.secondary).padding(2)
    }
  }
}

private struct TerminalSurface: UIViewRepresentable {
  let controller: RemoteTerminalController
  let location: RemoteTerminalLocation
  let offline: Bool
  let fontSize: Double
  let active: Bool
  func makeCoordinator() -> Coordinator { Coordinator(controller) }
  func makeUIView(context: Context) -> SwiftTerm.TerminalView {
    let view = SwiftTerm.TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
    view.terminalDelegate = context.coordinator
    view.nativeBackgroundColor = .black
    view.nativeForegroundColor = .white
    view.inputAccessoryView = TerminalKeyBar(terminal: view)
    controller.view = view
    controller.replay()
    controller.start(location, offline: offline)
    return view
  }
  func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
    if view.font.pointSize != fontSize { view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    if context.coordinator.wasActive != active {
      context.coordinator.wasActive = active
      if !active { view.resignFirstResponder() }
    }
  }
  static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
    coordinator.controller.close()
    view.terminalDelegate = nil
    closeRenderer(view)
  }
  private static func closeRenderer(_ view: SwiftTerm.TerminalView) {
    guard !view.updateUiClosed() else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { closeRenderer(view) }
  }

  @MainActor final class Coordinator: NSObject, TerminalViewDelegate {
    let controller: RemoteTerminalController
    var wasActive = false
    init(_ controller: RemoteTerminalController) { self.controller = controller }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
      controller.resize(columns: newCols, rows: newRows)
    }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { controller.send(Data(data)) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
      guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
      UIApplication.shared.open(url)
    }
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
  }
}

/// A single row scrolls on narrow phones rather than shrinking its touch targets.
private final class TerminalKeyBar: UIInputView {
  private weak var terminal: SwiftTerm.TerminalView?
  private final class Observation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
  }
  private var observers: [Observation] = []
  init(terminal: SwiftTerm.TerminalView) {
    self.terminal = terminal
    super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 40), inputViewStyle: .keyboard)
    allowsSelfSizing = true
    let scroll = UIScrollView()
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 2
    scroll.showsHorizontalScrollIndicator = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: 40),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 3),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -3),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
    func button(_ title: String, label: String, action: @escaping (UIButton) -> Void) -> UIButton {
      let button = UIButton(type: .system)
      var config = UIButton.Configuration.tinted()
      config.title = title
      config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var result = incoming
        result.font = UIFont.preferredFont(forTextStyle: .caption1)
        return result
      }
      button.configuration = config
      button.accessibilityLabel = label
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
      button.addAction(UIAction { [weak button] _ in if let button { action(button) } }, for: .touchUpInside)
      stack.addArrangedSubview(button)
      return button
    }
    let ctrl = button("Ctrl", label: "Control modifier") { [weak terminal] button in
      terminal?.controlModifier.toggle()
      button.isSelected = terminal?.controlModifier == true
    }
    let alt = button("Alt", label: "Alt modifier") { [weak terminal] button in
      terminal?.metaModifier.toggle()
      button.isSelected = terminal?.metaModifier == true
    }
    for (title, label, bytes) in [
      ("Esc", "Escape", "\u{1b}"), ("Tab", "Tab", "\t"),
      ("←", "Left arrow", "\u{1b}[D"), ("↓", "Down arrow", "\u{1b}[B"),
      ("↑", "Up arrow", "\u{1b}[A"), ("→", "Right arrow", "\u{1b}[C"),
      ("PgUp", "Page Up", "\u{1b}[5~"), ("PgDn", "Page Down", "\u{1b}[6~"),
    ] {
      _ = button(title, label: label) { [weak terminal] _ in
        switch title {
        case "←": terminal?.sendKeyLeft()
        case "↓": terminal?.sendKeyDown()
        case "↑": terminal?.sendKeyUp()
        case "→": terminal?.sendKeyRight()
        default: terminal?.send(data: Array(bytes.utf8)[...])
        }
      }
    }
    for (name, button) in [(Notification.Name.terminalViewControlModifierReset, ctrl), (.terminalViewMetaModifierReset, alt)] {
      observers.append(Observation(NotificationCenter.default.addObserver(forName: name, object: terminal, queue: .main) { [weak button] _ in
        MainActor.assumeIsolated { button?.isSelected = false }
      }))
    }
  }
  required init?(coder: NSCoder) { nil }
}
