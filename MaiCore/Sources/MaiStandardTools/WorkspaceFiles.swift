import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Android)
  import Android
#endif

public struct WorkspaceFileEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let name: String
  public let isDirectory: Bool
  public let isSymbolicLink: Bool
  public let size: Int
  public let modifiedAt: Date?
}

public struct WorkspaceFileListing: Codable, Sendable {
  public let root: String
  public let path: String
  public let writeEnabled: Bool
  public let entries: [WorkspaceFileEntry]
  public let nextOffset: Int?
}

public struct WorkspaceFileChunk: Codable, Sendable {
  public let data: Data
  public let size: Int
  public let version: String
}

/// A bounded filesystem operation, shared by local browsers and ACP clients.
public struct WorkspaceFileRequest: Codable, Sendable {
  public enum Operation: String, Codable, Sendable {
    case list, read, mkdir, uploadBegin, uploadChunk, uploadFinish, uploadCancel
  }
  public static let chunkSize = 512 * 1024
  public var operation: Operation
  public var path: String
  public var offset: Int
  public var limit: Int
  public var showHidden: Bool
  public var overwrite: Bool
  public var transferID: UUID?
  public var data: Data?
  public var version: String?

  public init(
    _ operation: Operation, path: String = ".", offset: Int = 0, limit: Int = chunkSize,
    showHidden: Bool = false, overwrite: Bool = false, transferID: UUID? = nil,
    data: Data? = nil, version: String? = nil
  ) {
    self.operation = operation
    self.path = path
    self.offset = offset
    self.limit = limit
    self.showHidden = showHidden
    self.overwrite = overwrite
    self.transferID = transferID
    self.data = data
    self.version = version
  }
}

public struct WorkspaceFileResponse: Codable, Sendable {
  public var listing: WorkspaceFileListing?
  public var chunk: WorkspaceFileChunk?
  public var transferID: UUID?
  public var bytes: Int?

  public init(
    listing: WorkspaceFileListing? = nil, chunk: WorkspaceFileChunk? = nil,
    transferID: UUID? = nil, bytes: Int? = nil
  ) {
    self.listing = listing
    self.chunk = chunk
    self.transferID = transferID
    self.bytes = bytes
  }
}

public struct WorkspaceFileError: LocalizedError, Sendable {
  public let message: String
  public var errorDescription: String? { message }
  public init(_ message: String) { self.message = message }
}

/// Uses the Files tools' path authorization, including symlinks and host policy.
/// Uploads stay private until complete; disconnect/cancel removes their staging files.
public actor MaiWorkspaceFiles {
  private struct Upload {
    let path: String
    let folder: URL
    let file: URL
    let handle: FileHandle
    let overwrite: Bool
    var bytes = 0
  }
  private let configuration: MaiFileWorkspaceConfiguration
  private var uploads: [UUID: Upload] = [:]

  public init(configuration: MaiFileWorkspaceConfiguration) {
    self.configuration = configuration
  }

  deinit {
    for upload in uploads.values {
      try? upload.handle.close()
      try? FileManager.default.removeItem(at: upload.folder)
    }
  }

  public func close() {
    for id in Array(uploads.keys) { cancel(id) }
  }

  public func request(_ request: WorkspaceFileRequest) async throws -> WorkspaceFileResponse {
    try Task.checkCancellation()
    if request.operation == .uploadCancel {
      guard let id = request.transferID else { throw WorkspaceFileError("Missing transfer ID.") }
      cancel(id)
      return .init()
    }
    #if os(macOS) || os(iOS)
      let access =
        configuration.isSecurityScoped
        && configuration.rootURL.startAccessingSecurityScopedResource()
      defer { if access { configuration.rootURL.stopAccessingSecurityScopedResource() } }
    #endif
    let transfer = request.transferID.flatMap { uploads[$0] }
    let path = transfer?.path ?? request.path
    guard path.utf8.count <= 4096, !path.contains("\0"), request.offset >= 0 else {
      throw WorkspaceFileError("Invalid file path or offset.")
    }
    let authorized = try await configuration.authorizing(
      paths: [path], operation: request.operation.rawValue)
    let workspace = try MaiFileWorkspace(configuration: authorized)
    let reads = request.operation == .list || request.operation == .read
    guard reads || configuration.writeEnabled else {
      throw WorkspaceFileError("This workspace is read only.")
    }
    let url = try workspace.resolve(
      path, allowRoot: request.operation == .list,
      mustExist: reads, preserveWhitespace: true)
    guard MaiFileAccessPolicy.contains(url, in: workspace.rootURL) else {
      throw WorkspaceFileError("The path is outside this workspace.")
    }
    let root = workspace.rootURL.path
    let relative = url.path == root ? "" : String(url.path.dropFirst(root.count + 1))
    if let first = relative.split(separator: "/").first,
      configuration.hiddenRootEntryNames.contains(String(first))
    {
      throw WorkspaceFileError("This folder is managed by the app.")
    }
    switch request.operation {
    case .list:
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
        directory.boolValue
      else {
        throw WorkspaceFileError("Choose a directory to browse.")
      }
      let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey,
      ]
      let children = try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: request.showHidden ? [] : [.skipsHiddenFiles])
      let entries = children.compactMap { child -> WorkspaceFileEntry? in
        guard
          !(url.path == root
            && configuration.hiddenRootEntryNames.contains(child.lastPathComponent)),
          MaiFileAccessPolicy.contains(child.resolvingSymlinksInPath(), in: workspace.rootURL),
          (try? workspace.resolve(
            child.path, allowRoot: false, mustExist: true, preserveWhitespace: true)) != nil,
          let values = try? child.resolvingSymlinksInPath().resourceValues(forKeys: keys),
          values.isDirectory == true || values.isRegularFile == true
        else { return nil }
        return .init(
          path: child.path, name: child.lastPathComponent,
          isDirectory: values.isDirectory == true,
          isSymbolicLink: (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
            == true,
          size: values.fileSize ?? 0, modifiedAt: values.contentModificationDate)
      }.sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      let start = min(request.offset, entries.count)
      let end = start + min(max(request.limit, 1), 500, entries.count - start)
      return .init(
        listing: .init(
          root: root, path: url.path, writeEnabled: configuration.writeEnabled,
          entries: Array(entries[start..<end]),
          nextOffset: end < entries.count ? end : nil))
    case .read:
      guard request.limit > 0, request.limit <= WorkspaceFileRequest.chunkSize else {
        throw WorkspaceFileError(
          "File chunks must be between 1 and \(WorkspaceFileRequest.chunkSize) bytes.")
      }
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
      ])
      guard values.isRegularFile == true else {
        throw WorkspaceFileError("Only regular files can be previewed or downloaded.")
      }
      let size = values.fileSize ?? 0
      let version = "\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
      guard request.version == nil || request.version == version else {
        throw WorkspaceFileError("The file changed during download. Try again.")
      }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(request.offset))
      let data = try handle.read(upToCount: request.limit) ?? Data()
      return .init(chunk: .init(data: data, size: size, version: version))
    case .mkdir:
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      return .init()
    case .uploadBegin:
      guard uploads.count < 4 else {
        throw WorkspaceFileError("Finish or cancel an existing upload first.")
      }
      try validateDestination(url, overwrite: request.overwrite)
      let id = UUID()
      let folder = configuration.temporaryDirectoryURL.appendingPathComponent("pmai-upload-\(id)")
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let file = folder.appendingPathComponent("data")
      do {
        guard
          FileManager.default.createFile(
            atPath: file.path, contents: nil,
            attributes: [.posixPermissions: 0o600])
        else { throw WorkspaceFileError("Could not start upload.") }
        uploads[id] = Upload(
          path: path, folder: folder, file: file,
          handle: try FileHandle(forWritingTo: file), overwrite: request.overwrite)
      } catch {
        try? FileManager.default.removeItem(at: folder)
        throw error
      }
      return .init(transferID: id, bytes: 0)
    case .uploadChunk:
      guard let id = request.transferID, var upload = uploads[id], let data = request.data,
        data.count <= WorkspaceFileRequest.chunkSize, request.offset == upload.bytes
      else {
        throw WorkspaceFileError("Invalid upload chunk or offset.")
      }
      try upload.handle.write(contentsOf: data)
      upload.bytes += data.count
      uploads[id] = upload
      return .init(bytes: upload.bytes)
    case .uploadFinish:
      guard let id = request.transferID, let upload = uploads[id], request.offset == upload.bytes
      else {
        throw WorkspaceFileError("Incomplete or unknown upload.")
      }
      try validateDestination(url, overwrite: upload.overwrite)
      try upload.handle.synchronize()
      let staging = url.deletingLastPathComponent().appendingPathComponent(".pmai-upload-\(id)")
      defer { try? FileManager.default.removeItem(at: staging) }
      try FileManager.default.copyItem(at: upload.file, to: staging)
      if upload.overwrite {
        #if os(Windows)
          if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
          } else {
            try FileManager.default.moveItem(at: staging, to: url)
          }
        #else
          guard rename(staging.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
        #endif
      } else {
        try FileManager.default.moveItem(at: staging, to: url)
      }
      cancel(id)
      return .init(bytes: upload.bytes)
    case .uploadCancel:
      return .init()
    }
  }

  private func validateDestination(_ url: URL, overwrite: Bool) throws {
    var directory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) {
      guard overwrite, !directory.boolValue else {
        throw WorkspaceFileError("A file or folder with this name already exists.")
      }
    }
    guard
      FileManager.default.fileExists(
        atPath: url.deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue
    else {
      throw WorkspaceFileError("The destination directory no longer exists.")
    }
  }

  private func cancel(_ id: UUID) {
    guard let upload = uploads.removeValue(forKey: id) else { return }
    try? upload.handle.close()
    try? FileManager.default.removeItem(at: upload.folder)
  }
}
