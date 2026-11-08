import Foundation
import MaiACP
import MaiCore

actor CLIAppSession {
  private let runtime: AgentRuntime
  private let scope: AgentExecutionScope
  private let fileAccessLog: FileAccessLog
  private let terminal: TerminalWriter
  private let ask: @Sendable (String) async throws -> String
  private var request: AgentRequest
  private var active: Task<JSONValue, any Error>?
  private var directCalls = 0
  private var closed = false

  init(
    runtime: AgentRuntime, request: AgentRequest, scope: AgentExecutionScope,
    fileAccessLog: FileAccessLog, terminal: TerminalWriter,
    ask: @escaping @Sendable (String) async throws -> String
  ) {
    self.runtime = runtime
    self.request = request
    self.scope = scope
    self.fileAccessLog = fileAccessLog
    self.terminal = terminal
    self.ask = ask
  }

  func close() {
    closed = true
    active?.cancel()
  }

  func handle(_ message: JSONRPCMessage) async throws -> JSONRPCMessage? {
    guard let id = message.id else { return nil }
    guard !closed, active == nil else {
      throw JSONRPCError.internalError("App session is busy or closed")
    }
    let task = Task {
      try await AgentExecutionScope.$current.withValue(scope) {
        try await FileAccessLog.$current.withValue(fileAccessLog) {
          try await perform(message)
        }
      }
    }
    active = task
    defer { active = nil }
    return .response(id: id, result: try await task.value)
  }

  private func perform(_ message: JSONRPCMessage) async throws -> JSONValue {
    let params = message.params?.objectValue ?? [:]
    let emit: AgentEventHandler = { [terminal] event in
      switch event {
      case .toolStarted, .toolFinished: await terminal.consume(event)
      default: break
      }
    }
    switch message.method {
    case "chat/context":
      return .object([
        "sessionId": .string(scope.sessionID), "agent": .string(request.agentID),
        "provider": .string(request.provider.rawValue), "model": .string(request.model),
        "messages": .array(request.messages.map {
          .object(["role": .string($0.role.rawValue), "text": .string($0.text)])
        }),
      ])
    case "chat/prompt":
      guard let text = params["text"]?.stringValue, !text.isEmpty else {
        throw JSONRPCError.invalidParams("Expected a prompt in text")
      }
      var next = request
      next.messages.append(.user(text))
      let result = try await runtime.run(next, emit: emit)
      request.messages = result.transcript
      return .object(["text": .string(result.response.text)])
    case "tools/list":
      let tools = try await runtime.appToolDefinitions(for: request)
      return .object(["tools": .array(tools.map {
        .object(["name": .string($0.name), "description": .string($0.description),
          "inputSchema": $0.inputSchema])
      })])
    case "tools/call":
      guard let name = params["name"]?.stringValue else {
        throw JSONRPCError.invalidParams("Expected a tool name")
      }
      guard directCalls < request.limits.maxToolCalls else {
        throw JSONRPCError.internalError("App tool call limit reached")
      }
      directCalls += 1
      let call = ToolCall(id: UUID().uuidString, name: name, arguments: params["arguments"] ?? .object([:]))
      let result = try await runtime.callAppTool(call, request: request, emit: emit)
      return .object(["text": .string(result.text), "isError": .bool(result.isError),
        "structuredContent": result.structuredContent ?? .null])
    case "user/ask":
      guard let text = params["text"]?.stringValue, !text.isEmpty else {
        throw JSONRPCError.invalidParams("Expected a question in text")
      }
      return .object(["text": .string(try await ask(text))])
    default:
      throw JSONRPCError.methodNotFound(message.method ?? "")
    }
  }
}

extension CLIAppSession {
  static func launch(
    directory: String, arguments: [String], bridge: CLIAppSession, terminal: TerminalWriter
  ) async {
    let server = LoopbackJSONRPCServer()
    let files = FileManager.default
    let scratch = files.temporaryDirectory.appendingPathComponent("pmai-app-output-\(UUID())", isDirectory: true)
    defer { try? files.removeItem(at: scratch) }
    do {
      let url = try await server.start(handle: bridge.handle)
      #if os(Windows)
        try files.createDirectory(at: scratch, withIntermediateDirectories: false)
      #else
        try files.createDirectory(at: scratch, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      #endif
      let log = scratch.appendingPathComponent("output")
      try Data().write(to: log)
      let output = try FileHandle(forUpdating: log)
      defer { try? output.close() }
      let status = try await CLIApp.run(directory: directory, arguments: arguments,
        environment: ProcessInfo.processInfo.environment, input: .nullDevice,
        output: output, diagnostics: output, sessionURL: url)
      await bridge.close()
      try output.seek(toOffset: 0)
      if let data = try output.read(upToCount: 1_048_576), !data.isEmpty {
        await terminal.line(String(decoding: data, as: UTF8.self))
      }
      if status != 0, !Task.isCancelled {
        await terminal.line("App exited with status \(status).", to: .standardError)
      }
    } catch is CancellationError {
      // The REPL already reported the interrupt.
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
    await bridge.close()
    await server.close()
  }
}
