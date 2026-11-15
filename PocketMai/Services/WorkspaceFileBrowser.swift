import Combine
import Foundation
import MaiACP
import MaiStandardTools

enum FileBrowserLocation: Identifiable {
  case local(FileWorkspaceContext)
  case remote(RemoteAgentBookmark, cwd: String)

  var id: String {
    switch self {
    case .local(let context): "local:\(context.rootURL.path)"
    case .remote(let host, let cwd): "\(host.id):\(host.revision?.uuidString ?? ""):\(cwd)"
    }
  }
  var title: String {
    switch self {
    case .local(let context): context.displayName
    case .remote(let host, let cwd):
      cwd.isEmpty ? host.name : "\(host.name) · \(URL(fileURLWithPath: cwd).lastPathComponent)"
    }
  }
  var root: String {
    switch self {
    case .local(let context): context.rootURL.path
    case .remote(_, let cwd): cwd
    }
  }
  var isRemote: Bool { if case .remote = self { true } else { false } }

  @MainActor func connection(browsingFolders: Bool = false) async throws -> FileBrowserConnection {
    switch self {
    case .local(let context):
      return .local(
        MaiWorkspaceFiles(
          configuration: .init(
            rootURL: context.rootURL, displayName: context.displayName,
            isSecurityScoped: context.isSecurityScoped,
            hiddenRootEntryNames: context.hidesModelsFolder ? ["Models"] : [])))
    case .remote(let host, let cwd):
      return try await host.workspaceConnection(cwd: cwd, browsingFolders: browsingFolders)
    }
  }
}

typealias FileBrowserConnection = WorkspaceConnection

struct BrowserFile: Identifiable {
  let id = UUID()
  let url: URL
  let originalPath: String
  let size: Int
  let isPartial: Bool

  static func textContent(_ data: Data, isPartial: Bool = false) -> String? {
    guard !data.contains(0) else { return nil }
    if let text = String(data: data, encoding: .utf8) { return text }
    // A bounded preview may end in the middle of a UTF-8 character.
    if isPartial {
      for count in 1...min(3, data.count) {
        if let text = String(data: data.dropLast(count), encoding: .utf8) { return text }
      }
    }
    return nil
  }
}

@MainActor
final class WorkspaceFileBrowser: ObservableObject {
  static let previewLimit = 16 * 1024 * 1024
  nonisolated private static let transferQueue = DispatchQueue(
    label: "io.github.trufae.mai.file-transfers", qos: .utility)

  nonisolated private static func disk<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      transferQueue.async { continuation.resume(with: Result(catching: operation)) }
    }
  }
  let location: FileBrowserLocation
  let browsingFolders: Bool
  private let isOffline: () -> Bool
  private var connection: FileBrowserConnection?
  private var temporaryFolders: [URL] = []
  private(set) var operation: Task<Void, Never>?
  private var saveOperation: Task<Void, Error>?
  @Published private(set) var path: String
  @Published private(set) var root: String
  @Published private(set) var entries: [WorkspaceFileEntry] = []
  @Published private(set) var nextOffset: Int?
  @Published private(set) var hasLoaded = false
  @Published private(set) var writeEnabled = true
  @Published private(set) var isBusy = false
  @Published private(set) var status: String?
  @Published private(set) var progress: Double?
  @Published var error: String?
  @Published var preview: BrowserFile?
  @Published var download: BrowserFile?
  @Published var showHidden = false

  init(location: FileBrowserLocation, browsingFolders: Bool = false,
    isOffline: @escaping () -> Bool = { false })
  {
    self.location = location
    self.browsingFolders = browsingFolders
    self.isOffline = isOffline
    path = location.root
    root = location.root
  }

  private var parentFolder: String? {
    if browsingFolders { return RemoteWorkspacePath.parent(of: path) }
    return path == root ? nil : URL(fileURLWithPath: path).deletingLastPathComponent().path
  }

  var canGoUp: Bool { !isBusy && parentFolder != nil }

  func browse(_ directory: String? = nil, append: Bool = false) {
    run(browsingFolders ? "Loading folders…" : "Loading files…") {
      try await self.load(directory ?? self.path, append: append)
    }
  }

  func goUp() { if let parentFolder { browse(parentFolder) } }

  func createDirectory(_ name: String) {
    run("Creating folder…") {
      guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
        !name.contains("\0")
      else {
        throw WorkspaceFileError("Enter a folder name without path separators.")
      }
      _ = try await self.request(
        .init(.mkdir, path: URL(fileURLWithPath: self.path).appendingPathComponent(name).path))
      try await self.load(self.path)
    }
  }

  func open(_ entry: WorkspaceFileEntry) {
    if entry.isDirectory {
      browse(entry.path)
    } else {
      run("Preparing preview…") { self.preview = try await self.fetch(entry, preview: true) }
    }
  }

  func save(_ entry: WorkspaceFileEntry) {
    run("Downloading \(entry.name)…") {
      self.download = try await self.fetch(entry, preview: false)
    }
  }

  func upload(_ urls: [URL], overwrite: Bool = false) {
    run("Uploading files…") {
      for (index, url) in urls.enumerated() {
        try Task.checkCancellation()
        self.status = "Uploading \(url.lastPathComponent) (\(index + 1)/\(urls.count))…"
        try await self.uploadFile(url, overwrite: overwrite)
      }
      try await self.load(self.path)
    }
  }

  func update(_ file: BrowserFile, text: String) async throws {
    guard !isBusy else {
      throw WorkspaceFileError("Wait for the current file operation to finish.")
    }
    guard writeEnabled else { throw WorkspaceFileError("This workspace is read only.") }
    guard !file.isPartial else { throw WorkspaceFileError("Partial previews cannot be edited.") }
    guard preview?.id == file.id else {
      throw WorkspaceFileError("Open the file again to edit it.")
    }
    isBusy = true
    status = "Saving \(file.url.lastPathComponent)…"
    let task = Task {
      let url = file.url
      try await Self.disk { try Data(text.utf8).write(to: url, options: .atomic) }
      try Task.checkCancellation()
      try await self.uploadFile(file.url, destination: file.originalPath, overwrite: true)
      try? await self.load(self.path)
    }
    saveOperation = task
    defer {
      saveOperation = nil
      isBusy = false
      status = nil
      progress = nil
    }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func cancel() {
    operation?.cancel()
    saveOperation?.cancel()
    if let connection { Task { await connection.close() } }
    connection = nil
  }

  func close() {
    cancel()
    for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
    temporaryFolders.removeAll()
  }

  func clearPreview() {
    release(preview)
    preview = nil
  }
  func clearDownload() {
    release(download)
    download = nil
  }

  private func release(_ file: BrowserFile?) {
    guard let file else { return }
    let folder = file.url.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: folder)
    temporaryFolders.removeAll { $0 == folder }
  }

  private func run(_ status: String, _ body: @escaping @MainActor () async throws -> Void) {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    self.status = status
    operation = Task {
      defer {
        isBusy = false
        self.status = nil
        progress = nil
        operation = nil
      }
      do { try await body() } catch is CancellationError {} catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }

  private func activeConnection() async throws -> FileBrowserConnection {
    try Task.checkCancellation()
    guard !location.isRemote || !isOffline() else {
      throw WorkspaceFileError("Turn off Airplane Mode to access remote files.")
    }
    if let connection { return connection }
    let connection = try await location.connection(browsingFolders: browsingFolders)
    try Task.checkCancellation()
    self.connection = connection
    return connection
  }

  private func request(_ request: WorkspaceFileRequest) async throws -> WorkspaceFileResponse {
    let response = try await activeConnection().request(request)
    try Task.checkCancellation()
    return response
  }

  private func load(_ directory: String, append: Bool = false) async throws {
    let offset = append ? nextOffset ?? 0 : 0
    let listing: WorkspaceFileListing
    if browsingFolders {
      listing = try await activeConnection().listFolders(
        path: directory, scope: root, offset: offset, showHidden: showHidden)
      try Task.checkCancellation()
    } else {
      let response = try await request(
        .init(.list, path: directory, offset: offset, limit: 200, showHidden: showHidden))
      guard let files = response.listing else {
        throw WorkspaceFileError("The host returned an invalid directory listing.")
      }
      listing = files
    }
    root = listing.root
    path = listing.path
    writeEnabled = listing.writeEnabled
    let page = browsingFolders ? listing.entries.filter(\.isDirectory) : listing.entries
    entries = append ? entries + page : page
    nextOffset = listing.nextOffset
    hasLoaded = true
  }

  private func fetch(_ entry: WorkspaceFileEntry, preview: Bool) async throws -> BrowserFile {
    guard !entry.name.isEmpty, entry.name != ".", entry.name != "..",
      !entry.name.contains("/"), !entry.name.contains("\\"), !entry.name.contains("\0")
    else {
      throw WorkspaceFileError("The host returned an invalid filename.")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pmai-file-\(UUID())")
    try await Self.disk {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    temporaryFolders.append(folder)
    var completed = false
    defer {
      if !completed {
        try? FileManager.default.removeItem(at: folder)
        temporaryFolders.removeAll { $0 == folder }
      }
    }
    let destination = folder.appendingPathComponent(entry.name)
    let handle = try await Self.disk {
      guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
        throw WorkspaceFileError("Could not create the downloaded file.")
      }
      return try FileHandle(forWritingTo: destination)
    }
    defer { try? handle.close() }
    var offset = 0
    var version: String?
    var size = entry.size
    repeat {
      let limit = preview && offset == 0 ? 64 * 1024 : WorkspaceFileRequest.chunkSize
      let result = try await request(
        .init(.read, path: entry.path, offset: offset, limit: limit, version: version))
      guard let chunk = result.chunk, chunk.size >= 0,
        !chunk.data.isEmpty || offset == chunk.size
      else { throw WorkspaceFileError("The file changed or the download was interrupted.") }
      version = chunk.version
      size = chunk.size
      try await Self.disk { try handle.write(contentsOf: chunk.data) }
      try Task.checkCancellation()
      offset += chunk.data.count
      progress = size == 0 ? 1 : Double(offset) / Double(size)
      if preview && size > Self.previewLimit { break }
    } while offset < size
    completed = true
    return BrowserFile(
      url: destination, originalPath: entry.path, size: size, isPartial: offset < size)
  }

  private func uploadFile(_ url: URL, destination: String? = nil, overwrite: Bool) async throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let (handle, size) = try await Self.disk {
      let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard info.isRegularFile == true else {
        throw WorkspaceFileError("Select regular files to upload.")
      }
      return (try FileHandle(forReadingFrom: url), info.fileSize)
    }
    defer { try? handle.close() }
    let destination =
      destination ?? URL(fileURLWithPath: path).appendingPathComponent(url.lastPathComponent).path
    let response = try await request(.init(.uploadBegin, path: destination, overwrite: overwrite))
    guard let id = response.transferID, let connection else {
      throw WorkspaceFileError("The host did not start the upload.")
    }
    var offset = 0
    do {
      while let data = try await Self.disk({ try handle.read(upToCount: WorkspaceFileRequest.chunkSize) }), !data.isEmpty {
        let response = try await request(
          .init(.uploadChunk, offset: offset, transferID: id, data: data))
        offset += data.count
        guard response.bytes == offset else {
          throw WorkspaceFileError("The host did not accept the complete upload chunk.")
        }
        progress = Double(offset) / Double(max(size ?? 1, 1))
      }
      _ = try await request(.init(.uploadFinish, offset: offset, transferID: id))
    } catch {
      // Cleanup must also run after task cancellation, without the cancelled task's context.
      _ = await Task { try? await connection.request(.init(.uploadCancel, transferID: id)) }.value
      throw error
    }
  }
}
