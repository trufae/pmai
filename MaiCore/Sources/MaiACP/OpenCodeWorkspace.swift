import Foundation
import MaiCore
import MaiStandardTools

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Location-scoped operations do not create chats or invoke a model.
public actor OpenCodeWorkspace {
  private let http: OpenCodeHTTP
  private let root: String
  private let query: [URLQueryItem]

  public init(connection: OpenCodeConnection, browsingFolders: Bool = false,
    configuration: URLSessionConfiguration = .ephemeral) throws
  {
    guard browsingFolders || !connection.cwd.isEmpty else {
      throw WorkspaceFileError("Choose an OpenCode project first.")
    }
    http = OpenCodeHTTP(url: connection.url, token: connection.token, configuration: configuration)
    root = browsingFolders ? connection.cwd : URL(fileURLWithPath: connection.cwd).standardized.path
    query = connection.cwd.isEmpty ? [] : [.init(name: "location[directory]", value: connection.cwd)]
  }

  deinit { http.close() }
  public func close() { http.close() }

  public func files(_ request: WorkspaceFileRequest) async throws -> WorkspaceFileResponse {
    guard request.offset >= 0, request.limit > 0, request.limit <= WorkspaceFileRequest.chunkSize,
      request.offset <= Int.max - request.limit,
      !request.path.contains("\0")
    else { throw WorkspaceFileError("Invalid file path or range.") }
    let path = try resolve(request.path)
    switch request.operation {
    case .list:
      return try await list(request, path: path, foldersOnly: false)
    case .read:
      guard path != root else { throw WorkspaceFileError("Choose a file to open.") }
      let relative = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
      let (data, response) = try await http.download(
        ["api", "fs", "read"] + relative.split(separator: "/").map(String.init), query: query,
        headers: ["Accept": "application/octet-stream",
          "Range": "bytes=\(request.offset)-\(request.offset + request.limit - 1)"], accepting: [416])
      let version = response.value(forHTTPHeaderField: "ETag")
        ?? response.value(forHTTPHeaderField: "Last-Modified") ?? ""
      guard request.version == nil || request.version == version else {
        throw WorkspaceFileError("The file changed during download. Try again.")
      }
      if response.statusCode == 416 {
        guard request.offset == 0, response.value(forHTTPHeaderField: "Content-Range") == "bytes */0" else {
          throw WorkspaceFileError("The file changed during download. Try again.")
        }
        return .init(chunk: .init(data: Data(), size: 0, version: version))
      }
      if response.statusCode == 206 {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
          range.hasPrefix("bytes \(request.offset)-"),
          let size = range.split(separator: "/").last.flatMap({ Int($0) }),
          size >= request.offset + data.count, data.count <= request.limit
        else { throw invalidResponse() }
        return .init(chunk: .init(data: data, size: size, version: version))
      }
      // Empty files and servers without Range support return the whole file.
      guard request.offset <= data.count else { throw invalidResponse() }
      return .init(chunk: .init(
        data: Data(data.dropFirst(request.offset).prefix(request.limit)), size: data.count, version: version))
    default:
      throw WorkspaceFileError("OpenCode file browsing is read only.")
    }
  }

  func listFolders(_ request: WorkspaceFileRequest) async throws -> WorkspaceFileResponse {
    guard request.offset >= 0,
      request.path.isEmpty || RemoteWorkspacePath.isAbsolute(request.path)
    else { throw WorkspaceFileError("Enter an absolute folder path.") }
    return try await list(request, path: request.path.isEmpty ? nil : request.path, foldersOnly: true)
  }

  private func list(_ request: WorkspaceFileRequest, path: String?, foldersOnly: Bool)
    async throws -> WorkspaceFileResponse
  {
    // The listing API can browse parents and siblings at the same OpenCode location.
    let items = path.map { [URLQueryItem(name: "path", value: $0)] } ?? []
    let response = try await http.request(["api", "fs", "list"], query: query + items)
    let fields = response.objectValue
    let base = (foldersOnly ? fields?["location"]?.objectValue?["directory"]?.stringValue : nil) ?? root
    guard let nodes = fields?["data"]?.arrayValue,
      let directory = RemoteWorkspacePath.resolve(path ?? base, relativeTo: base)
    else { throw invalidResponse() }
    let entries = try nodes.compactMap { node -> WorkspaceFileEntry? in
      let fields = node.objectValue
      guard let relative = fields?["path"]?.stringValue,
        let type = fields?["type"]?.stringValue, ["file", "directory"].contains(type),
        let child = RemoteWorkspacePath.resolve(relative, relativeTo: base),
        RemoteWorkspacePath.parent(of: child) == directory,
        let name = child.split(separator: "/").last
      else { throw invalidResponse() }
      if (foldersOnly && type != "directory") || (!request.showHidden && name.hasPrefix(".")) {
        return nil
      }
      return .init(path: child, name: String(name), isDirectory: type == "directory", size: -1)
    }.sorted {
      if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    let start = min(request.offset, entries.count)
    let end = start + min(request.limit, 500, entries.count - start)
    return .init(listing: .init(
      root: foldersOnly ? directory : root, path: directory, writeEnabled: false,
      entries: Array(entries[start..<end]), nextOffset: end < entries.count ? end : nil))
  }

  private func resolve(_ path: String) throws -> String {
    guard !path.contains("\0") else { throw WorkspaceFileError("Invalid file path.") }
    // Resolve the workspace base before normalizing ..; some Foundation versions
    // otherwise discard leading .. from a relative URL instead of escaping the root.
    let path = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root, isDirectory: true))
      .absoluteURL.standardized.path
    guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else {
      throw WorkspaceFileError("The path is outside this workspace.")
    }
    return path
  }

  /// OpenCode's binary write endpoint replaces files; it has no exclusive-create option.
  public func write(_ path: String, data: Data) async throws {
    let path = try resolve(path)
    guard path != root else { throw WorkspaceFileError("Choose a file to write.") }
    _ = try await http.download(["api", "experimental", "fs", "write"], method: "POST",
      query: query + [.init(name: "path", value: path)], timeout: 120, data: data)
  }

  public func run(_ command: String, onOutput: @escaping @Sendable (String) async -> Void = { _ in })
    async throws -> ToolResult
  {
    let created = try await http.request(
      ["api", "shell"], method: "POST",
      body: .object(["command": .string(command), "cwd": .string(root), "timeout": .number(120_000)]),
      query: query)
    guard let id = created.objectValue?["data"]?.objectValue?["id"]?.stringValue else {
      throw invalidResponse()
    }
    do {
      var output = ""
      var cursor = 0
      while true {
        try Task.checkCancellation()
        // Check completion before reading so the final page includes all output.
        let state = try await http.request(["api", "shell", id], query: query)
        guard let status = state.objectValue?["data"]?.objectValue?["status"]?.stringValue else {
          throw invalidResponse()
        }
        var size = cursor
        repeat {
          let page = try await http.request(["api", "shell", id, "output"], query: query + [
            .init(name: "cursor", value: String(cursor)), .init(name: "limit", value: "65536"),
          ])
          guard let fields = page.objectValue?["data"]?.objectValue,
            let text = fields["output"]?.stringValue,
            let next = fields["cursor"]?.intValue, let total = fields["size"]?.intValue,
            next >= cursor, next <= total, next > cursor || next == total
          else { throw invalidResponse() }
          output += text
          cursor = next
          size = total
          await onOutput(output)
        } while cursor < size
        if status != "running" {
          let exit = state.objectValue?["data"]?.objectValue?["exit"]?.intValue
          let failed = status != "exited" || exit != 0
          if failed { output += "\n[\(status), exit \(exit.map(String.init) ?? "unknown")]" }
          _ = try await http.request(["api", "shell", id], method: "DELETE", query: query)
          return .init(callID: id, text: output, isError: failed)
        }
        try await Task.sleep(for: .milliseconds(250))
      }
    } catch {
      let http = http, query = query
      _ = await Task { try? await http.request(["api", "shell", id], method: "DELETE", query: query) }.value
      throw error
    }
  }

  private func invalidResponse() -> WorkspaceFileError {
    WorkspaceFileError("OpenCode returned an invalid workspace response.")
  }
}
