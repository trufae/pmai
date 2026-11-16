import Foundation
#if os(macOS) || os(Linux) || os(Windows)
  #if canImport(Musl)
    import Musl
  #elseif canImport(Glibc)
    import Glibc
  #elseif canImport(Darwin)
    import Darwin
  #endif

  /// Asks an external agent for its own limits by running the one command it
  /// already answers — `/usage` for Claude Code, `/status` for Codex — over the
  /// same ACP the agent speaks to pmai. The agent owns its login and reports
  /// what its subscription has left, so pmai never reads a token that belongs
  /// to another program.
  ///
  /// The exchange opens a throwaway session, sends the command, keeps the reply
  /// text, and ends the process. A provider reached over the network answers
  /// `_pmai/status` on its host instead, so this runs only where a process can
  /// be started.
  public enum MeteredAgentStatus {
    public static let codex = "codex"
    public static let claude = "claude"

    /// The backend a configured command names: `codex-acp`, `claude-agent-acp`,
    /// or a path to either.
    public static func backend(command: String) -> String? {
      let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
      if name.contains("codex") { return codex }
      if name.contains("claude") { return claude }
      return nil
    }

    /// The command that makes an agent print its limits, or nil for an agent
    /// that has none.
    static func usageCommand(for backend: String) -> String? {
      switch backend {
      case codex: return "/status"
      case claude: return "/usage"
      default: return nil
      }
    }

    public static func status(
      command: String,
      arguments: [String] = [],
      provider: String,
      workingDirectory: URL? = nil
    ) async throws -> MaiProviderStatus? {
      guard let backend = backend(command: command),
        let usageCommand = usageCommand(for: backend),
        let executable = try? LocalExecutable.resolve(command)
      else { return nil }
      let text = try await run(
        executable: executable, arguments: arguments, command: usageCommand,
        workingDirectory: workingDirectory)
      var status = backend == codex
        ? parseCodex(text, provider: provider) : parseClaude(text, provider: provider)
      // Nothing recognised: the agent still said something useful, so show its
      // own words rather than claiming there is no data.
      if status.limits.isEmpty, status.balances.isEmpty {
        let quoted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quoted.isEmpty else { return nil }
        status.note = String(quoted.prefix(600))
      }
      return status
    }

    // MARK: - ACP exchange

    private static func run(
      executable: String, arguments: [String], command: String, workingDirectory: URL?
    ) async throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.currentDirectoryURL = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      process.standardError = FileHandle.nullDevice
      let input = Pipe()
      let output = Pipe()
      process.standardInput = input
      process.standardOutput = output
      try process.run()
      defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
      }
      let session = ACPCommandSession(handle: output.fileHandleForReading)
      defer { session.close() }

      var nextID = 0
      func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let body: [String: Any] = [
          "jsonrpc": "2.0", "id": id, "method": method, "params": params.mapValues(\.jsonObject),
        ]
        try input.fileHandleForWriting.write(
          contentsOf: try JSONSerialization.data(withJSONObject: body) + Data("\n".utf8))
        return try await session.response(id: id, timeout: 40)
      }
      _ = try await call("initialize", [
        "protocolVersion": .integer(1), "clientCapabilities": .object([:]),
      ])
      let created = try await call("session/new", [
        "cwd": .string(process.currentDirectoryURL?.path ?? "/"),
        "mcpServers": .array([]),
      ])
      guard let sessionID = created.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue
      else { throw MaiProviderStatusError.unsupportedResponse }
      // The reply arrives as `session/update` chunks while this request waits;
      // the session collects them and the request only marks the end.
      _ = try await call("session/prompt", [
        "sessionId": .string(sessionID),
        "prompt": .array([.object(["type": .string("text"), "text": .string(command)])]),
      ])
      return session.text
    }

    // MARK: - Parsing

    /// Claude's answer names each window, the share used, and the reset:
    /// `**5-hour limit** — **46%** · Resets Nov 16, 9:10 PM GMT+1`.
    static func parseClaude(_ text: String, provider: String) -> MaiProviderStatus {
      var status = MaiProviderStatus(provider: provider)
      for line in text.components(separatedBy: .newlines) {
        guard let used = firstPercent(in: line) else { continue }
        let lower = line.lowercased()
        let name: String
        if lower.contains("5-hour") || lower.contains("session") {
          name = "session"
        } else if lower.contains("weekly") {
          // `Weekly · Fable` is one model's share of the same week;
          // `Weekly · all models` is the week itself.
          let scope = modelName(in: line)
          name = scope.contains("all model") ? "weekly" : "week \(scope)"
        } else {
          continue
        }
        status.limits[name] = .init(
          remainingPercent: max(0, 100 - used), resetsText: resetText(in: line))
      }
      return status
    }

    /// Codex already reports what is left:
    /// `**codex Weekly limit:** 0% left (resets 08:15 on Nov 18)`.
    static func parseCodex(_ text: String, provider: String) -> MaiProviderStatus {
      var status = MaiProviderStatus(provider: provider)
      for line in text.components(separatedBy: .newlines) {
        let lower = line.lowercased()
        guard lower.contains("limit"), let percent = firstPercent(in: line) else { continue }
        let name = lower.contains("weekly") ? "weekly" : "session"
        status.limits[name] = .init(
          remainingPercent: max(0, lower.contains("left") ? percent : 100 - percent),
          resetsText: resetText(in: line))
      }
      if let value = firstValue(after: "Account:", in: text) {
        status.plan = value.components(separatedBy: "(").first?
          .trimmingCharacters(in: .whitespaces)
      }
      return status
    }

    /// `46` from `**46%**`.
    static func firstPercent(in line: String) -> Double? {
      guard let range = line.range(
        of: #"[0-9]+(?:\.[0-9]+)?\s*%"#, options: .regularExpression)
      else { return nil }
      return Double(line[range].filter { $0.isNumber || $0 == "." })
    }

    /// The words that follow `Resets` or `resets`.
    static func resetText(in line: String) -> String? {
      guard let range = line.range(
        of: #"[Rr]esets?\s+[^)\n]+"#, options: .regularExpression)
      else { return nil }
      return String(line[range])
        .replacingOccurrences(of: #"^[Rr]esets?\s+"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }

    /// The model a scoped weekly line is about: `Weekly · Fable` is Fable.
    private static func modelName(in line: String) -> String {
      let cleaned = line.replacingOccurrences(of: "*", with: "")
      guard let separator = cleaned.range(of: "·") else { return "model" }
      return cleaned[separator.upperBound...].components(separatedBy: "—").first?
        .trimmingCharacters(in: .whitespaces).lowercased() ?? "model"
    }

    private static func firstValue(after label: String, in text: String) -> String? {
      for line in text.components(separatedBy: .newlines) where line.contains(label) {
        return line.components(separatedBy: label).last?
          .replacingOccurrences(of: "*", with: "")
          .trimmingCharacters(in: .whitespaces)
      }
      return nil
    }
  }

  /// One JSON-RPC line protocol over an agent's stdout, enough for three calls.
  /// This is not an ACP feature set: it frames requests, resolves the answer
  /// that matches each id, and collects the text of the prompt.
  final class ACPCommandSession: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var waiting: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var settled: [Int: JSONValue] = [:]
    private var collected = ""
    private let handle: FileHandle

    init(handle: FileHandle) {
      self.handle = handle
      handle.readabilityHandler = { [weak self] handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        self?.consume(chunk)
      }
    }

    var text: String { lock.withLock { collected } }

    func close() {
      handle.readabilityHandler = nil
      let waiting = lock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
        let all = Array(self.waiting.values)
        self.waiting.removeAll()
        return all
      }
      for continuation in waiting {
        continuation.resume(throwing: MaiProviderStatusError.unsupportedResponse)
      }
    }

    /// The answer with this id, waiting for it when it has not arrived.
    func response(id: Int, timeout: TimeInterval) async throws -> JSONValue {
      if let answer = lock.withLock({ settled.removeValue(forKey: id) }) { return answer }
      return try await withThrowingTaskGroup(of: JSONValue.self) { group in
        group.addTask { try await self.wait(id: id) }
        group.addTask {
          try await Task.sleep(for: .seconds(timeout))
          throw MaiProviderStatusError.unsupportedResponse
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
          throw MaiProviderStatusError.unsupportedResponse
        }
        return first
      }
    }

    private func wait(id: Int) async throws -> JSONValue {
      try await withCheckedThrowingContinuation { continuation in
        if let answer = lock.withLock({ settled.removeValue(forKey: id) }) {
          continuation.resume(returning: answer)
        } else {
          lock.withLock { waiting[id] = continuation }
        }
      }
    }

    private func consume(_ chunk: Data) {
      var ready: [(Int, JSONValue)] = []
      var replies: [String] = []
      lock.withLock {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
          let line = Data(pending[..<newline])
          pending.removeSubrange(...newline)
          guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
          else { continue }
          if let update = object["params"] as? [String: Any],
            let fields = update["update"] as? [String: Any],
            fields["sessionUpdate"] as? String == "agent_message_chunk",
            let content = fields["content"] as? [String: Any],
            let text = content["text"] as? String
          {
            replies.append(text)
          }
          if let id = object["id"] as? Int,
            let value = try? JSONDecoder().decode(JSONValue.self, from: line)
          {
            ready.append((id, value))
          }
        }
        collected += replies.joined()
      }
      for (id, value) in ready {
        let continuation = lock.withLock { waiting.removeValue(forKey: id) }
        if let continuation {
          continuation.resume(returning: value)
        } else {
          lock.withLock { settled[id] = value }
        }
      }
    }
  }
#endif
