import MaiACP
import MaiCore
import SwiftUI

struct RemoteTerminalLocation: Identifiable {
  let host: RemoteAgentBookmark
  let cwd: String

  var id: String {
    [host.id.uuidString, host.revision?.uuidString ?? "", cwd].joined(separator: ":")
  }
  var title: String { "\(host.name) · \(URL(fileURLWithPath: cwd).lastPathComponent)" }
}

@MainActor
private final class RemoteTerminalSession: ObservableObject {
  @Published var buffer: RemoteTerminalBuffer
  @Published var isRunning = false
  @Published var storageError: String?

  private let location: RemoteTerminalLocation
  private let fileURL: URL
  private var isClosed = false
  private var workspace: WorkspaceConnection?
  private var operation: Task<Void, Never>?

  init(location: RemoteTerminalLocation) {
    self.location = location
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RemoteTerminals", isDirectory: true)
    fileURL = RemoteTerminalBuffer.fileURL(
      hostID: location.host.id, endpoint: location.host.url, cwd: location.cwd, directory: directory
    )
    buffer = .load(from: fileURL)
  }

  @discardableResult
  func run(_ command: String, offline: Bool) -> Bool {
    let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty, !isRunning, !isClosed else { return false }
    let id = buffer.append(command)
    isRunning = true
    save()

    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        isRunning = false
        operation = nil
        if !isClosed { save() }
      }
      do {
        guard !offline else { throw InternetAccessError.offline }
        if workspace == nil { workspace = try location.host.workspaceConnection(cwd: location.cwd) }
        let result = try await workspace!.run(command) { [weak self] output in
          await self?.finish(id, output: output, isError: false, isComplete: false)
        }
        finish(id, output: result.text, isError: result.isError)
      } catch {
        let partial = buffer.entries.last?.output ?? ""
        finish(
          id,
          output: partial + (partial.isEmpty ? "" : "\n")
            + "Error: \(error.localizedDescription)", isError: true)
      }
    }
    return true
  }

  func clear() {
    buffer.clearScrollback()
    save()
  }
  func clearHistory() {
    buffer.clearHistory()
    save()
  }

  func save() {
    do {
      try buffer.save(to: fileURL)
      storageError = nil
    } catch {
      storageError = "Couldn’t save terminal history: \(error.localizedDescription)"
    }
  }

  func close() {
    isClosed = true
    buffer.interruptPending()
    save()
    let operation = operation
    operation?.cancel()
    let workspace = workspace
    self.workspace = nil
    Task {
      await operation?.value
      await workspace?.close()
    }
  }

  private func finish(_ id: UUID, output: String, isError: Bool, isComplete: Bool = true) {
    guard !isClosed else { return }
    buffer.update(id, output: output, isError: isError, isComplete: isComplete)
  }
}

struct RemoteTerminalView: View {
  @EnvironmentObject private var appStore: AppStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  let location: RemoteTerminalLocation
  @StateObject private var terminal: RemoteTerminalSession
  @State private var command = ""
  @State private var historyCursor = RemoteTerminalHistoryCursor()
  @State private var showingHistory = false
  @State private var historySearch = ""
  @State private var followsOutput = true
  @State private var userScrolling = false
  @AppStorage("terminal.fontSize") private var fontSize = 14.0
  @GestureState private var magnification = 1.0
  @FocusState private var commandFocused: Bool

  init(location: RemoteTerminalLocation) {
    self.location = location
    _terminal = StateObject(wrappedValue: RemoteTerminalSession(location: location))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
              Text("\(location.host.name):\(location.cwd)")
                .foregroundStyle(.green).textSelection(.enabled)
              Text("Each command starts in this project directory.")
                .foregroundStyle(.gray)
              ForEach(terminal.buffer.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                  Text("$ \(entry.command)")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                    .contextMenu {
                      Button("Edit Command", systemImage: "pencil") { edit(entry.command) }
                      Button("Run Again", systemImage: "play") { submit(entry.command) }
                        .disabled(terminal.isRunning)
                    }
                  if let output = entry.output, !output.isEmpty {
                    ScrollView(.horizontal) {
                      Text(verbatim: output)
                        .foregroundStyle(entry.isError ? Color.red : Color(white: 0.9))
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                    }
                  }
                  if !entry.isComplete {
                    Text("Running…").foregroundStyle(.gray)
                  }
                }
                .id(entry.id)
              }
              Color.clear.frame(height: 1).id("terminal-bottom")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(terminalFont)
            .padding(12)
          }
          .defaultScrollAnchor(.bottom)
          .scrollDismissesKeyboard(.interactively)
          .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating
          }
          .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 40
          } action: { _, atBottom in
            if userScrolling { followsOutput = atBottom }
          }
          .onChange(of: terminal.buffer.entries.last) { _, _ in
            if followsOutput { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
          }
          .overlay(alignment: .bottomTrailing) {
            if !followsOutput {
              Button("Latest Output", systemImage: "arrow.down") {
                followsOutput = true
                withAnimation { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
              }
              .buttonStyle(.borderedProminent).padding(8)
            }
          }
          .simultaneousGesture(
            MagnifyGesture()
              .updating($magnification) { value, scale, _ in scale = value.magnification }
              .onEnded { value in fontSize = resizedFont(value.magnification) })
        }

        Divider()
        if let error = terminal.storageError {
          Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
        }
        VStack(spacing: 6) {
          HStack {
            Button("Previous Command", systemImage: "arrow.up") { recall(-1) }
              .disabled(terminal.buffer.history.isEmpty || historyCursor.index == 0)
            Button("Next Command", systemImage: "arrow.down") { recall(1) }
              .disabled(historyCursor.index == nil)
            Button("History", systemImage: "clock.arrow.circlepath") { showingHistory = true }
              .disabled(terminal.buffer.history.isEmpty)
            Spacer()
            Text(terminal.isRunning ? "Running" : "Ready").font(.caption).foregroundStyle(.gray)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("$").foregroundStyle(.green)
            TextField("Command", text: $command, axis: .vertical)
              .lineLimit(1...6)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.go)
              .focused($commandFocused)
              .onSubmit { submit() }
              .onKeyPress(.upArrow) {
                recall(-1)
                return .handled
              }
              .onKeyPress(.downArrow) {
                recall(1)
                return .handled
              }
            Button("Run", systemImage: "return") { submit() }
              .labelStyle(.iconOnly)
              .disabled(
                command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || terminal.isRunning)
          }
          .font(terminalFont)
        }
        .padding(12)
      }
      .background(.black)
      .foregroundStyle(Color(white: 0.9))
      .preferredColorScheme(.dark)
      .navigationTitle(location.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) {
          Menu("Terminal", systemImage: "ellipsis.circle") {
            Button("Clear Scrollback", systemImage: "trash", action: terminal.clear)
              .disabled(terminal.buffer.entries.isEmpty || terminal.isRunning)
            Button("Clear History", systemImage: "clock.badge.xmark") {
              historyCursor.reset()
              terminal.clearHistory()
            }
            .disabled(terminal.buffer.history.isEmpty)
          }
        }
      }
      .sheet(isPresented: $showingHistory) { historySheet }
      .onAppear { commandFocused = true }
      .onChange(of: scenePhase) { _, phase in if phase != .active { terminal.save() } }
      .onDisappear { terminal.close() }
    }
  }

  private var terminalFont: Font { .system(size: resizedFont(magnification), design: .monospaced) }

  private func resizedFont(_ scale: Double) -> Double {
    let step = AppearanceSettings.fontSizeStep
    return AppearanceSettings.clampedFontSize((fontSize * max(scale, 0.1) / step).rounded() * step)
  }

  private var historySheet: some View {
    NavigationStack {
      List {
        ForEach(
          terminal.buffer.history.reversed().filter {
            historySearch.isEmpty || $0.localizedCaseInsensitiveContains(historySearch)
          }, id: \.self
        ) { saved in
          VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: saved).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            HStack {
              Button("Edit", systemImage: "pencil") {
                edit(saved)
                showingHistory = false
              }
              Button("Run", systemImage: "play") {
                submit(saved)
                showingHistory = false
              }
              .disabled(terminal.isRunning)
            }
            .buttonStyle(.bordered)
          }
        }
      }
      .searchable(text: $historySearch, prompt: "Search commands")
      .navigationTitle("Command History")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingHistory = false } }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func edit(_ saved: String) {
    historyCursor.reset()
    command = saved
    commandFocused = true
  }

  private func recall(_ direction: Int) {
    command = historyCursor.move(direction, command: command, history: terminal.buffer.history)
    commandFocused = true
  }

  private func submit(_ saved: String? = nil) {
    guard terminal.run(saved ?? command, offline: appStore.settings.isOffline) else { return }
    if saved == nil { command = "" }
    historyCursor.reset()
    followsOutput = true
  }
}
