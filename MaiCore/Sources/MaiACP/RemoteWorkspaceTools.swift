import Foundation
import MaiCore
import MaiStandardTools

public struct RemoteWorkspaceHost: Sendable {
  public let id: String
  public let connection: RemoteHostConnection
  public init(id: String, connection: RemoteHostConnection) {
    self.id = id
    self.connection = connection
  }
}

/// The host supplies only explicitly enabled destinations. Resolve them again
/// on every call so deleting a host or switching access off revokes agent use.
public actor RemoteWorkspaceTools {
  private let hosts: @Sendable () async throws -> [RemoteWorkspaceHost]
  private struct Session {
    let owner: String
    let host: String
    let connection: WorkspaceConnection
    let terminal: RemoteTerminalSession
  }
  private var sessions: [String: Session] = [:]
  private var opening = 0

  public init(hosts: @escaping @Sendable () async throws -> [RemoteWorkspaceHost]) {
    self.hosts = hosts
  }

  public static let definitions: [ToolDefinition] = [
    .init(name: "remote_hosts", description: "List remote hosts explicitly enabled for this device's agents. Use their IDs with remote_run, remote_files and remote_terminal. Credentials are never returned.",
      parameters: [], annotations: .init(readOnly: true, approval: .automatic, requiresInternet: true)),
    .init(name: "remote_run", description: "Execute a shell command on an enabled remote host, without SSH or a remote model. Starts in the host's configured workspace each time. For interactive or persistent programs use remote_terminal on a pmai host.",
      parameters: [
        .init(name: "host", type: "string", description: "Host ID or unique name from remote_hosts", required: true),
        .init(name: "command", type: "string", description: "Shell command to execute remotely", required: true),
      ], annotations: .init(requiresInternet: true)),
    .init(name: "remote_files", description: "Read, list, write or mkdir in an enabled remote workspace. Host file permissions apply. Reads and writes are limited to 1 MB. Text is UTF-8; use encoding=base64 for binary content.",
      parameters: [
        .init(name: "host", type: "string", description: "Host ID or unique name", required: true),
        .init(name: "action", type: "string", description: "list, read, write or mkdir", required: true),
        .init(name: "path", type: "string", description: "Path relative to the host's workspace", required: true),
        .init(name: "content", type: "string", description: "Content for write; replaces the destination", required: false),
        .init(name: "encoding", type: "string", description: "utf8 (default) or base64", required: false),
        .init(name: "offset", type: "integer", description: "Next listing offset returned by list", required: false),
      ], annotations: .init(requiresInternet: true)),
    .init(name: "remote_terminal", description: "Control a persistent Unix PTY on an enabled pmai host: open, read, write, resize or close. Use the returned session ID on subsequent calls. read waits for output or exit (up to 15 seconds) and returns raw base64 bytes plus readable text. write sends text verbatim, including control characters, or base64 data. Close when finished. Sessions are private to this local conversation. OpenCode supports remote_run instead.",
      parameters: [
        .init(name: "host", type: "string", description: "Host ID or unique name", required: true),
        .init(name: "action", type: "string", description: "open, read, write, resize or close", required: true),
        .init(name: "session", type: "string", description: "ID returned by open", required: false),
        .init(name: "text", type: "string", description: "Raw input for write, e.g. ls\n or \u{1b}:q!\n for vim", required: false),
        .init(name: "data", type: "string", description: "Base64 input instead of text", required: false),
        .init(name: "columns", type: "integer", description: "Terminal columns; default 80", required: false),
        .init(name: "rows", type: "integer", description: "Terminal rows; default 24", required: false),
      ], annotations: .init(requiresInternet: true)),
  ]

  public nonisolated func tools() -> [any AgentTool] {
    Self.definitions.map { definition in
      ClosureTool(definition: definition) { arguments, context in
        let owner = (AgentCommandScope.current?.sessionID
          ?? AgentExecutionScope.current?.sessionID ?? context.run.runID.uuidString)
          + ":" + context.run.agentID
        return try await self.call(definition.name, arguments: arguments, owner: owner)
      }
    }
  }

  public func revoke(host id: String) async {
    let previous = sessions.filter { $0.value.host == id }
    for key in previous.keys { sessions[key] = nil }
    for session in previous.values { await session.connection.close() }
  }

  public func call(_ name: String, arguments: JSONValue, owner: String) async throws -> ToolOutput {
    try Task.checkCancellation()
    let enabled = try await hosts()
    let enabledIDs = Set(enabled.map(\.id))
    let revoked = sessions.filter { !enabledIDs.contains($0.value.host) }
    for key in revoked.keys { sessions[key] = nil }
    for session in revoked.values { await session.connection.close() }
    if name == "remote_hosts" {
      return json(.array(enabled.map { host in .object([
        "id": .string(host.id), "name": .string(host.connection.name),
        "cwd": .string(host.connection.cwd),
        "backend": .string(host.connection.backend == .openCode ? "opencode" : "pmai"),
      ]) }))
    }
    let fields = arguments.objectValue ?? [:]
    let target = fields["host"]?.stringValue ?? ""
    let matches = enabled.filter { $0.id == target || $0.connection.name.caseInsensitiveCompare(target) == .orderedSame }
    guard matches.count == 1, let host = matches.first else {
      throw WorkspaceFileError("Host is not enabled for agent access. Use remote_hosts and enable the host in Remote Hosts or /remote tools HOST on.")
    }
    if name == "remote_terminal" { return try await terminal(fields, host: host, owner: owner) }
    let connection = try host.connection.workspace()
    do {
      let result: ToolOutput
      switch name {
      case "remote_run":
        guard let command = fields["command"]?.stringValue, !command.isEmpty else {
          throw WorkspaceFileError("A command is required")
        }
        let output = try await connection.run(command)
        result = .init(content: output.content, structuredContent: output.structuredContent, isError: output.isError)
      case "remote_files": result = try await files(fields, connection: connection)
      default: throw AgentToolError.unavailable(name)
      }
      await connection.close()
      return result
    } catch {
      await connection.close()
      throw error
    }
  }

  private func files(_ fields: [String: JSONValue], connection: WorkspaceConnection) async throws -> ToolOutput {
    let path = fields["path"]?.stringValue ?? "."
    let encoding = fields["encoding"]?.stringValue ?? "utf8"
    guard ["utf8", "base64"].contains(encoding) else { throw WorkspaceFileError("Use utf8 or base64 encoding") }
    switch fields["action"]?.stringValue {
    case "list":
      let response = try await connection.request(.init(.list, path: path,
        offset: fields["offset"]?.intValue ?? 0, limit: 200, showHidden: true))
      return try encoded(response)
    case "read":
      let data = try await connection.read(path, maximumSize: 1024 * 1024)
      if encoding == "base64" { return json(.object(["content": .string(data.base64EncodedString()), "encoding": .string(encoding)])) }
      guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceFileError("Binary file; read with encoding=base64") }
      return .init(text: text)
    case "write":
      guard let content = fields["content"]?.stringValue, content.utf8.count <= 1400 * 1024 else {
        throw WorkspaceFileError("Provide content of at most 1 MB")
      }
      guard let data = encoding == "base64" ? Data(base64Encoded: content) : content.data(using: .utf8),
        data.count <= 1024 * 1024 else { throw WorkspaceFileError("Invalid or oversized file content") }
      try await connection.write(path, data: data)
      return .init(text: "Wrote \(data.count) bytes to \(path)")
    case "mkdir": return try encoded(try await connection.request(.init(.mkdir, path: path)))
    default: throw WorkspaceFileError("Choose list, read, write or mkdir")
    }
  }

  private func terminal(_ fields: [String: JSONValue], host: RemoteWorkspaceHost, owner: String) async throws -> ToolOutput {
    if fields["action"] == .string("open") {
      guard sessions.count + opening < 16 else { throw WorkspaceFileError("Close an existing terminal first") }
      opening += 1
      defer { opening -= 1 }
      let connection = try host.connection.workspace()
      do {
        let shell = try await connection.openTerminal(columns: fields["columns"]?.intValue ?? 80,
          rows: fields["rows"]?.intValue ?? 24)
        try Task.checkCancellation()
        guard try await hosts().contains(where: { $0.id == host.id }) else {
          throw WorkspaceFileError("Agent access to this host was revoked while connecting")
        }
        let id = UUID().uuidString.lowercased()
        sessions[id] = Session(owner: owner, host: host.id, connection: connection, terminal: shell)
        return json(.object(["session": .string(id)]))
      } catch { await connection.close(); throw error }
    }
    guard let id = fields["session"]?.stringValue, let session = sessions[id],
      session.owner == owner, session.host == host.id else {
      throw WorkspaceFileError("Unknown terminal in this conversation")
    }
    do {
      switch fields["action"]?.stringValue {
      case "read":
        let chunk = try await session.terminal.read()
        var result: [String: JSONValue] = ["data": .string(chunk.data.base64EncodedString()),
          "text": .string(String(decoding: chunk.data, as: UTF8.self))]
        if let exit = chunk.exitCode {
          result["exitCode"] = .integer(exit)
          sessions[id] = nil
          await session.connection.close()
        }
        return json(.object(result))
      case "write":
        let data: Data
        if let encoded = fields["data"]?.stringValue, let decoded = Data(base64Encoded: encoded) { data = decoded }
        else if let text = fields["text"]?.stringValue { data = Data(text.utf8) }
        else { throw WorkspaceFileError("Provide text or base64 data") }
        guard data.count <= 64 * 1024 else { throw WorkspaceFileError("Send at most 64 KB at a time") }
        try await session.terminal.send(data)
      case "resize": try await session.terminal.resize(columns: fields["columns"]?.intValue ?? 80, rows: fields["rows"]?.intValue ?? 24)
      case "close": sessions[id] = nil; await session.connection.close()
      default: throw WorkspaceFileError("Choose open, read, write, resize or close")
      }
      return .init(text: "OK")
    } catch {
      // A cancelled or failed operation must not leave an unattended job alive.
      sessions[id] = nil
      await session.connection.close()
      throw error
    }
  }

  private func encoded<T: Encodable>(_ value: T) throws -> ToolOutput {
    json(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)))
  }
  private func json(_ value: JSONValue) -> ToolOutput { .init(content: [.text(value.compactJSONString)], structuredContent: value) }
}
