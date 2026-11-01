import Foundation
import MaiCore
import MaiStandardTools

/// One workspace API for local files, ACP/Forwiroh, and OpenCode HTTP hosts.
public enum WorkspaceConnection: Sendable {
  case local(MaiWorkspaceFiles)
  case remote(ACPClient, cwd: String)
  case openCode(OpenCodeWorkspace)

  public func supportsInteractiveTerminal() async throws -> Bool {
    if case .remote(let client, _) = self { return try await client.terminalSupported() }
    return false
  }

  public func openTerminal(columns: Int, rows: Int) async throws -> RemoteTerminalSession {
    guard case .remote(let client, let cwd) = self else {
      throw WorkspaceFileError("This host supports command execution only")
    }
    let result = try await client.terminal([
      "action": .string("open"), "cwd": .string(cwd),
      "columns": .integer(columns), "rows": .integer(rows),
    ])
    guard let id = result.objectValue?["id"]?.stringValue else {
      throw WorkspaceFileError("The host did not open a terminal")
    }
    return RemoteTerminalSession(id: id, client: client)
  }

  public func attachTerminal(id: String) async throws -> RemoteTerminalSession? {
    guard case .remote(let client, _) = self else { return nil }
    let response = try await client.terminal(["action": .string("attach"), "id": .string(id)])
    return response.objectValue?["attached"]?.boolValue == true
      ? RemoteTerminalSession(id: id, client: client) : nil
  }

  public func terminalIDs() async throws -> [String] {
    guard case .remote(let client, _) = self else { return [] }
    let response = try await client.terminal(["action": .string("list")])
    return response.objectValue?["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  public func request(_ request: WorkspaceFileRequest) async throws -> WorkspaceFileResponse {
    try Task.checkCancellation()
    switch self {
    case .local(let files): return try await files.request(request)
    case .remote(let client, let cwd): return try await client.files(cwd: cwd, request: request)
    case .openCode(let workspace): return try await workspace.files(request)
    }
  }

  public func run(_ command: String,
    onOutput: @escaping @Sendable (String) async -> Void = { _ in }
  ) async throws -> ToolResult {
    try Task.checkCancellation()
    switch self {
    case .remote(let client, let cwd):
      let result = try await client.runTool(cwd: cwd,
        call: .init(id: UUID().uuidString, name: "run_shell",
          arguments: .object(["script": .string(command)])))
      await onOutput(result.text)
      return result
    case .openCode(let workspace): return try await workspace.run(command, onOutput: onOutput)
    case .local: throw WorkspaceFileError("Use the local shell to run commands on this device.")
    }
  }

  /// Bounded downloads validate every chunk and never return a silently truncated file.
  public func read(_ path: String, maximumSize: Int) async throws -> Data {
    var data = Data()
    var version: String?
    var size: Int?
    repeat {
      let response = try await request(.init(.read, path: path, offset: data.count,
        limit: min(WorkspaceFileRequest.chunkSize, max(1, maximumSize - data.count)), version: version))
      guard let chunk = response.chunk, chunk.size >= 0, chunk.size <= maximumSize,
        size == nil || size == chunk.size, version == nil || version == chunk.version,
        chunk.data.count <= chunk.size - data.count,
        !chunk.data.isEmpty || chunk.size == data.count else {
        throw WorkspaceFileError("The file changed, exceeds the size limit, or the download was interrupted.")
      }
      version = chunk.version
      size = chunk.size
      data.append(chunk.data)
    } while data.count < (size ?? 0)
    return data
  }

  public func write(_ path: String, data: Data, overwrite: Bool = true) async throws {
    if case .openCode(let workspace) = self {
      guard overwrite else { throw WorkspaceFileError("OpenCode uploads require permission to replace the destination.") }
      try await workspace.write(path, data: data)
      return
    }
    let response = try await request(.init(.uploadBegin, path: path, overwrite: overwrite))
    guard let id = response.transferID else { throw WorkspaceFileError("The host did not start the upload.") }
    do {
      var offset = 0
      while offset < data.count {
        let chunk = Data(data.dropFirst(offset).prefix(WorkspaceFileRequest.chunkSize))
        let response = try await request(.init(.uploadChunk, offset: offset, transferID: id, data: chunk))
        offset += chunk.count
        guard response.bytes == offset else { throw WorkspaceFileError("The host did not accept the complete upload.") }
      }
      _ = try await request(.init(.uploadFinish, offset: offset, transferID: id))
    } catch {
      _ = await Task { try? await self.request(.init(.uploadCancel, transferID: id)) }.value
      throw error
    }
  }

  public func close() async {
    switch self {
    case .local(let files): await files.close()
    case .remote(let client, _): await client.disconnect()
    case .openCode(let workspace): await workspace.close()
    }
  }
}
