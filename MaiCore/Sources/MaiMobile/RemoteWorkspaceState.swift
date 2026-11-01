import Foundation
import MaiACP
import MaiStandardTools
import Observation

/// File/console work has its own connection and cancellation scope; chat stays usable.
@MainActor @Observable final class RemoteWorkspaceState {
  private let directory: URL
  private var key = ""
  private var profile: RemoteHostConnection?
  private var preparation: Task<Void, Error>?
  private var connection: WorkspaceConnection?
  private var console: WorkspaceConnection?
  private var fileOperation: Task<Void, Never>?
  private var terminalOperation: Task<Void, Never>?
  private var generation = 0
  private var terminalURL: URL?
  private var buffer = RemoteTerminalBuffer()
  private var entries: [WorkspaceFileEntry] = []
  private var root = ""
  private var path = "."
  private var nextOffset: Int?
  private var writeEnabled = false
  private var filePath = ""
  private var previewPath = ""
  private var previewText: String?
  private var downloadPath = ""
  var busy = false
  var running = false
  var error = ""
  var showHidden = false
  private var consoleVisible = false
  private var filesVisible = false

  init(directory: URL) { self.directory = directory }

  func configure(hostID: String, profile: RemoteHostConnection, cwd: String, preparation: Task<Void, Error>? = nil) {
    let nextKey = [hostID, profile.url.absoluteString, cwd].joined(separator: "\n")
    guard key != nextKey else { return }
    close()
    key = nextKey
    var profile = profile
    profile.cwd = cwd
    self.profile = profile
    self.preparation = preparation
    root = cwd
    path = cwd
    if let id = UUID(uuidString: hostID) {
      let url = RemoteTerminalBuffer.fileURL(hostID: id, endpoint: profile.url, cwd: cwd,
        directory: directory.appendingPathComponent("terminals"))
      terminalURL = url
      buffer = .load(from: url)
    }
  }

  private func load(_ directory: String, append: Bool = false, connection: WorkspaceConnection) async throws {
    let result = try await connection.request(.init(.list, path: directory,
      offset: append ? nextOffset ?? 0 : 0, limit: 200, showHidden: showHidden))
    try Task.checkCancellation()
    guard let listing = result.listing else { throw WorkspaceFileError("Invalid directory listing.") }
    entries = append ? entries + listing.entries : listing.entries
    root = listing.root
    path = listing.path
    nextOffset = listing.nextOffset
    writeEnabled = listing.writeEnabled
  }

  func browse(_ directory: String, append: Bool = false) {
    run { connection in
      try await self.load(directory, append: append, connection: connection)
      self.previewPath = ""
      self.previewText = nil
      if !self.filePath.isEmpty { try? FileManager.default.removeItem(atPath: self.filePath) }
      self.filePath = ""
    }
  }

  func more() { if nextOffset != nil { browse(path, append: true) } }
  func up() { if !root.isEmpty, path != root { browse(URL(fileURLWithPath: path).deletingLastPathComponent().path) } }
  func hidden(_ enabled: Bool) { showHidden = enabled; browse(path) }

  func open(_ path: String, archive: Bool = false) {
    run { connection in
      if archive && !path.lowercased().hasSuffix(".xdc") { throw WorkspaceFileError("Choose a .xdc archive.") }
      let data = try await connection.read(path, maximumSize: 32_000_000)
      try Task.checkCancellation()
      let folder = self.directory.appendingPathComponent("downloads")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let name = URL(fileURLWithPath: path).lastPathComponent
      guard !name.isEmpty, name != ".", name != "..", !name.contains("\\") else {
        throw WorkspaceFileError("Invalid filename.")
      }
      let output = folder.appendingPathComponent(UUID().uuidString + "-" + name)
      try data.write(to: output, options: .atomic)
      if archive { self.downloadPath = output.path }
      else {
        if !self.filePath.isEmpty { try? FileManager.default.removeItem(atPath: self.filePath) }
        self.filePath = output.path
        self.previewPath = path
        self.previewText = data.count <= 1_000_000 && !data.contains(0) ? String(data: data, encoding: .utf8) : nil
      }
    }
  }

  func save(_ text: String) {
    guard writeEnabled, previewText != nil, !previewPath.isEmpty else { return }
    let path = previewPath
    run { connection in
      try await connection.write(path, data: Data(text.utf8))
      try Task.checkCancellation()
      self.previewText = text
      try Data(text.utf8).write(to: URL(fileURLWithPath: self.filePath), options: .atomic)
    }
  }

  func mkdir(_ name: String) {
    guard writeEnabled, !name.isEmpty, name != ".", name != "..",
      !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return }
    let destination = URL(fileURLWithPath: path).appendingPathComponent(name).path
    run { connection in
      _ = try await connection.request(.init(.mkdir, path: destination))
      try await self.load(self.path, connection: connection)
    }
  }

  func upload(_ source: String, name: String) {
    guard writeEnabled, !busy, !name.isEmpty, name != ".", name != "..",
      !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return }
    let destination = URL(fileURLWithPath: path).appendingPathComponent(name).path
    run { connection in
      defer { try? FileManager.default.removeItem(atPath: source) }
      let url = URL(fileURLWithPath: source)
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard size <= 32_000_000 else { throw WorkspaceFileError("Files are limited to 32 MB.") }
      try await connection.write(destination, data: Data(contentsOf: url), overwrite: false)
      try await self.load(self.path, connection: connection)
    }
  }

  func consumeDownload() throws {
    guard !downloadPath.isEmpty else { return }
    try FileManager.default.removeItem(atPath: downloadPath)
    downloadPath = ""
  }

  private func run(_ body: @escaping @MainActor (WorkspaceConnection) async throws -> Void) {
    guard !busy, let profile else { return }
    busy = true
    error = ""
    let attempt = generation
    fileOperation = Task {
      do {
        if profile.backend != .openCode { try await preparation?.value }
        try Task.checkCancellation()
        if connection == nil { connection = try profile.workspace() }
        try await body(connection!)
      } catch {
        guard generation == attempt else { return }
        if !Task.isCancelled { self.error = error.localizedDescription }
        let old = connection
        connection = nil
        await old?.close()
      }
      guard generation == attempt else { return }
      busy = false
      fileOperation = nil
    }
  }

  func execute(_ command: String) {
    let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !running, !command.isEmpty, let profile else { return }
    running = true
    error = ""
    let attempt = generation
    let id = buffer.append(command)
    persist()
    terminalOperation = Task { [self] in
      do {
        if profile.backend != .openCode { try await preparation?.value }
        try Task.checkCancellation()
        if console == nil { console = try profile.workspace() }
        let result = try await console!.run(command) { [weak self] output in
          await self?.output(id, text: output, generation: attempt)
        }
        try Task.checkCancellation()
        guard generation == attempt else { return }
        buffer.update(id, output: result.text, isError: result.isError)
      } catch {
        guard generation == attempt else { return }
        let partial = buffer.entries.last?.output ?? ""
        buffer.update(id, output: partial + "\n" + (Task.isCancelled
          ? "[stopped; remote command may still be running]" : error.localizedDescription), isError: true)
        let old = console
        console = nil
        await old?.close()
      }
      guard generation == attempt else { return }
      running = false
      terminalOperation = nil
      persist()
    }
  }

  private func output(_ id: UUID, text: String, generation attempt: Int) {
    guard generation == attempt else { return }
    buffer.update(id, output: text, isError: false, isComplete: false)
  }

  func show(console: Bool) {
    consoleVisible = console
    filesVisible = !console
  }

  func hide() {
    consoleVisible = false
    filesVisible = false
    stop()
  }

  func stop() { terminalOperation?.cancel() }
  func clear(history: Bool) {
    if history { buffer.clearHistory() }
    else if !running { buffer.clearScrollback() }
    persist()
  }

  private func persist() {
    guard let terminalURL else { return }
    do { try buffer.save(to: terminalURL) }
    catch { self.error = "Could not save terminal history: \(error.localizedDescription)" }
  }

  func close() {
    generation += 1
    fileOperation?.cancel()
    terminalOperation?.cancel()
    buffer.interruptPending()
    persist()
    let files = connection, terminal = console, operation = terminalOperation
    Task {
      await files?.close()
      // Let OpenCode's cancellation handler delete its shell before closing HTTP.
      await operation?.value
      await terminal?.close()
    }
    connection = nil
    console = nil
    fileOperation = nil
    terminalOperation = nil
    profile = nil
    preparation = nil
    key = ""
    terminalURL = nil
    buffer = .init()
    entries = []
    path = "."
    root = ""
    writeEnabled = false
    nextOffset = nil
    previewPath = ""
    previewText = nil
    if !filePath.isEmpty { try? FileManager.default.removeItem(atPath: filePath) }
    filePath = ""
    busy = false
    running = false
    consoleVisible = false
    filesVisible = false
    error = ""
  }

  var snapshot: [String: Any] {
    ["browserPath": path, "browserRoot": root, "workspaceBusy": busy,
      "workspaceError": error, "writeEnabled": writeEnabled, "showHidden": showHidden,
      "hasMoreFiles": nextOffset != nil, "filePath": filePath,
      "previewPath": previewPath, "previewText": (filesVisible ? previewText : nil) as Any? ?? NSNull(),
      "downloadPath": downloadPath, "terminalRunning": running,
      "terminalHistory": consoleVisible ? buffer.history : [],
      "terminalEntries": (consoleVisible ? buffer.entries : []).map {
        ["id": $0.id.uuidString, "command": $0.command, "output": $0.output ?? "",
          "isError": $0.isError, "isComplete": $0.isComplete] as [String: Any]
      },
      "files": entries.map { ["path": $0.path, "name": $0.name, "directory": $0.isDirectory,
        "size": $0.size] as [String: Any] },
    ]
  }
}
