import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// OpenCode v2's native HTTP API. OpenTunnel is only the HTTPS transport;
/// it does not turn the server into an ACP gateway.
public actor OpenCodeClient: RemoteSessionClient {
  private let http: OpenCodeHTTP
  private let cwd: String
  private var sessionID: String?
  private var closed = false
  private var prompting = false
  private var history: [JSONValue] = []
  public private(set) var isConnected = false
  private let onUpdate: (@Sendable (JSONValue) async -> Void)?
  private let onPermission: (@Sendable (JSONValue) async throws -> String?)?

  public init(
    connection: OpenCodeConnection, sessionID: String? = nil,
    configuration: URLSessionConfiguration = .ephemeral,
    onUpdate: (@Sendable (JSONValue) async -> Void)? = nil,
    onPermission: (@Sendable (JSONValue) async throws -> String?)? = nil
  ) {
    http = OpenCodeHTTP(url: connection.url, token: connection.token, configuration: configuration)
    cwd = connection.cwd
    self.sessionID = sessionID
    self.onUpdate = onUpdate
    self.onPermission = onPermission
  }

  deinit { http.close() }

  public func workspace() async throws -> ACPWorkspaceSnapshot? {
    try checkOpen()
    let projects = try await http.request(["api", "project"])
    guard let projects = projects.arrayValue else { throw invalidResponse() }
    var snapshot = ACPWorkspaceSnapshot()
    snapshot.canManageSessions = true
    for project in projects {
      guard let fields = project.objectValue, let directory = fields["canonical"]?.stringValue
      else {
        throw invalidResponse()
      }
      let paths = [directory] + (fields["sandboxes"]?.arrayValue ?? []).compactMap(\.stringValue)
      for path in paths where !snapshot.folders.contains(where: { $0.cwd == path }) {
        snapshot.folders.append(
          .init(
            cwd: path,
            name: path == directory
              ? fields["name"]?.stringValue
                ?? URL(fileURLWithPath: path).lastPathComponent
              : URL(fileURLWithPath: path).lastPathComponent))
      }
    }
    var cursor: String?
    var seen = Set<String>()
    repeat {
      var query = [
        URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "parentID", value: "null"),
      ]
      if let cursor { query.append(.init(name: "cursor", value: cursor)) }
      let page = try await http.request(["api", "session"], query: query)
      guard let sessions = page.objectValue?["data"]?.arrayValue else { throw invalidResponse() }
      for session in sessions {
        guard let fields = session.objectValue, let id = fields["id"]?.stringValue,
          let directory = fields["location"]?.objectValue?["directory"]?.stringValue
        else { throw invalidResponse() }
        if fields["time"]?.objectValue?["archived"]?.numberValue != nil { continue }
        snapshot.sessions.append(
          .init(
            sessionID: id, cwd: directory, title: fields["title"]?.stringValue ?? "OpenCode chat",
            updatedAt: fields["time"]?.objectValue?["updated"]?.numberValue.map {
              Date(timeIntervalSince1970: $0 / 1000)
            }))
        if !snapshot.folders.contains(where: { $0.cwd == directory }) {
          snapshot.folders.append(
            .init(cwd: directory, name: URL(fileURLWithPath: directory).lastPathComponent))
        }
      }
      cursor = page.objectValue?["cursor"]?.objectValue?["next"]?.stringValue
      if let cursor, !seen.insert(cursor).inserted { throw invalidResponse() }
    } while cursor != nil
    try checkOpen()
    isConnected = true
    return snapshot
  }

  public func connect() async throws -> String {
    try checkOpen()
    if sessionID == nil {
      guard !cwd.isEmpty else {
        throw JSONRPCError.invalidParams(
          "Choose an OpenCode project before starting a conversation.")
      }
      let result = try await http.request(
        ["api", "session"], method: "POST",
        body: .object([
          "location": .object(["directory": .string(cwd)])
        ]))
      guard let id = result.objectValue?["data"]?.objectValue?["id"]?.stringValue else {
        throw invalidResponse()
      }
      sessionID = id
    }
    let id = sessionID!
    _ = try await refreshHistory(id, full: true)
    try checkOpen()
    isConnected = true
    return id
  }

  public func manageSession(_ id: String, cwd: String, title: String?) async throws {
    try checkOpen()
    _ = try await http.request(
      ["api", "session", id], method: title == nil ? "DELETE" : "PATCH",
      body: title.map { .object(["title": .string($0)]) })
  }

  public func prompt(
    _ text: String, emit: @escaping @Sendable (ProviderEvent) async -> Void
  ) async throws -> ProviderStopReason {
    try checkOpen()
    guard isConnected, !prompting, let id = sessionID else {
      throw JSONRPCError.invalidParams("Connect to an idle OpenCode session first.")
    }
    prompting = true
    defer { prompting = false }
    do {
      // Admission returns before execution finishes. Never resend this POST on a
      // network failure: the server may already have accepted and run the prompt.
      _ = try await http.request(
        ["api", "session", id, "prompt"], method: "POST",
        body: .object(["text": .string(text)]))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { [http] in
          _ = try await http.request(
            ["api", "experimental", "session", id, "wait"], method: "POST", timeout: 600)
        }
        group.addTask { [self] in
          while true {
            try Task.checkCancellation()
            _ = try await refreshHistory(id)
            try await answerPermissions(id)
            try await Task.sleep(for: .seconds(1))
          }
        }
        defer { group.cancelAll() }
        try await group.next()
      }
      let history = try await refreshHistory(id, full: true)
      let idle = history.last { $0.objectValue?["type"]?.stringValue == "idle" }
      if idle?.objectValue?["outcome"]?.stringValue == "failed" {
        throw JSONRPCError.internalError(
          idle?.objectValue?["error"]?.objectValue?["message"]?.stringValue
            ?? "OpenCode session failed.")
      }
      return idle?.objectValue?["outcome"]?.stringValue == "interrupted" ? .cancelled : .stop
    } catch {
      isConnected = false
      if Task.isCancelled {
        // Cancellation must still reach the host after the caller's task is cancelled.
        let http = http
        _ = await Task {
          try? await http.request(["api", "session", id, "interrupt"], method: "POST")
        }.value
        throw CancellationError()
      }
      throw error
    }
  }

  public func disconnect() async {
    closed = true
    isConnected = false
    if prompting, let sessionID {
      _ = try? await http.request(["api", "session", sessionID, "interrupt"], method: "POST")
    }
    http.close()
  }

  private func checkOpen() throws {
    try Task.checkCancellation()
    if closed { throw CancellationError() }
  }

  private func invalidResponse() -> JSONRPCError {
    .invalidParams(
      "Unexpected OpenCode response. This connection requires the OpenCode v2 HTTP API.")
  }

  private func refreshHistory(_ id: String, full: Bool = false) async throws -> [JSONValue] {
    if full {
      var messages: [JSONValue] = []
      var cursor: String?
      var seen = Set<String>()
      repeat {
        var query = [URLQueryItem(name: "limit", value: "200")]
        if let cursor {
          query.append(.init(name: "cursor", value: cursor))
        } else {
          query.append(.init(name: "order", value: "asc"))
        }
        let response = try await http.request(["api", "session", id, "message"], query: query)
        guard let page = response.objectValue?["data"]?.arrayValue else { throw invalidResponse() }
        messages += page
        cursor = response.objectValue?["cursor"]?.objectValue?["next"]?.stringValue
        if let cursor, !seen.insert(cursor).inserted { throw invalidResponse() }
      } while cursor != nil
      history = messages
    } else {
      let response = try await http.request(["api", "session", id, "context"])
      guard let active = response.objectValue?["data"]?.arrayValue else { throw invalidResponse() }
      var indices = Dictionary(
        history.enumerated().compactMap { index, message in
          message.objectValue?["id"]?.stringValue.map { ($0, index) }
        }, uniquingKeysWith: { first, _ in first })
      for message in active {
        guard let messageID = message.objectValue?["id"]?.stringValue else {
          throw invalidResponse()
        }
        if let index = indices[messageID] {
          history[index] = message
        } else {
          indices[messageID] = history.count
          history.append(message)
        }
      }
    }
    try checkOpen()
    // Context is a snapshot, including partially generated text and tool state.
    // Stable message/part IDs let the app replace it without duplicating deltas.
    var messages: [JSONValue] = []
    for message in history {
      guard let fields = message.objectValue, let messageID = fields["id"]?.stringValue,
        let type = fields["type"]?.stringValue
      else { continue }
      let created = fields["time"]?.objectValue?["created"] ?? .null
      if type == "user" {
        messages.append(
          .object([
            "remoteID": .string(messageID), "role": .string("user"),
            "text": fields["text"] ?? .string(""), "created": created,
          ]))
      } else if type == "assistant" {
        for (index, part) in (fields["content"]?.arrayValue ?? []).enumerated() {
          guard let part = part.objectValue, let kind = part["type"]?.stringValue else { continue }
          var entry: [String: JSONValue] = [
            "remoteID": .string("\(messageID):\(index)"), "created": created,
            "role": .string(kind == "reasoning" ? "thought" : "assistant"),
            "text": part["text"] ?? .string(""),
          ]
          if kind == "tool" {
            let state = part["state"]?.objectValue ?? [:]
            let content = (state["content"]?.arrayValue ?? []).compactMap {
              $0.objectValue?["text"]?.stringValue
            }
            entry["role"] = .string("tool")
            entry["toolID"] = part["id"]
            entry["status"] = state["status"]
            entry["text"] = .string(
              ([part["name"]?.stringValue ?? "Tool"] + content
                + [state["error"]?.objectValue?["message"]?.stringValue].compactMap { $0 })
                .joined(separator: "\n"))
          }
          messages.append(.object(entry))
        }
      }
    }
    await onUpdate?(
      .object([
        "sessionUpdate": .string("_pmai/message_snapshot"), "messages": .array(messages),
      ]))
    return history
  }

  private func answerPermissions(_ id: String) async throws {
    let response = try await http.request(["api", "session", id, "permission"])
    guard let requests = response.objectValue?["data"]?.arrayValue else { throw invalidResponse() }
    for request in requests {
      guard let fields = request.objectValue, let requestID = fields["id"]?.stringValue else {
        throw invalidResponse()
      }
      let choices = [
        ("once", "Allow once", "allow_once"), ("always", "Always allow", "allow_always"),
        ("reject", "Reject", "reject_once"),
      ]
      let reply = try await onPermission?(
        .object([
          "toolCall": .object([
            "title": fields["action"] ?? .string("Tool permission"),
            "resources": fields["resources"] ?? .array([]),
            "metadata": fields["metadata"] ?? .null,
          ]),
          "options": .array(
            choices.map {
              .object([
                "optionId": .string($0.0), "name": .string($0.1), "kind": .string($0.2),
              ])
            }),
        ]))
      try checkOpen()
      let decision = choices.contains { $0.0 == reply } ? reply! : "reject"
      _ = try await http.request(
        ["api", "session", id, "permission", requestID, "reply"],
        method: "POST", body: .object(["decision": .string(decision)]))
    }
  }
}
