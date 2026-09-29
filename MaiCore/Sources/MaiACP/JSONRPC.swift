import Foundation
import MaiCore

/// One JSON-RPC 2.0 message. A request carries an id and a method, a
/// notification a method alone, and a response an id with a result or error.
public struct JSONRPCMessage: Codable, Equatable, Sendable {
  public var id: JSONValue?
  public var method: String?
  public var params: JSONValue?
  public var result: JSONValue?
  public var error: JSONRPCError?

  public init(
    id: JSONValue? = nil,
    method: String? = nil,
    params: JSONValue? = nil,
    result: JSONValue? = nil,
    error: JSONRPCError? = nil
  ) {
    self.id = id
    self.method = method
    self.params = params
    self.result = result
    self.error = error
  }

  public static func request(id: Int, method: String, params: JSONValue?) -> JSONRPCMessage {
    JSONRPCMessage(id: .integer(id), method: method, params: params)
  }

  public static func notification(_ method: String, params: JSONValue?) -> JSONRPCMessage {
    JSONRPCMessage(method: method, params: params)
  }

  public static func response(id: JSONValue, result: JSONValue) -> JSONRPCMessage {
    JSONRPCMessage(id: id, result: result)
  }

  public static func failure(id: JSONValue?, error: JSONRPCError) -> JSONRPCMessage {
    JSONRPCMessage(id: id ?? .null, error: error)
  }

  public var isRequest: Bool { method != nil && id != nil }
  public var isNotification: Bool { method != nil && id == nil }
  public var isResponse: Bool { method == nil && id != nil }

  private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params, result, error }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(JSONValue.self, forKey: .id)
    method = try container.decodeIfPresent(String.self, forKey: .method)
    params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
    error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("2.0", forKey: .jsonrpc)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encodeIfPresent(method, forKey: .method)
    try container.encodeIfPresent(params, forKey: .params)
    // A response needs a result key even when the result is null.
    if method == nil, error == nil { try container.encode(result ?? .null, forKey: .result) }
    try container.encodeIfPresent(error, forKey: .error)
  }
}

public struct JSONRPCError: Codable, Equatable, Sendable, LocalizedError {
  public static let parseError = -32700
  public static let invalidRequest = -32600
  public static let methodNotFound = -32601
  public static let invalidParams = -32602
  public static let internalError = -32603
  /// ACP's "authentication required", returned by agents that need a login.
  public static let authRequired = -32000

  public var code: Int
  public var message: String
  public var data: JSONValue?

  public init(code: Int, message: String, data: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }

  public static func methodNotFound(_ method: String) -> JSONRPCError {
    JSONRPCError(code: methodNotFound, message: "Method not found: \(method)")
  }

  public static func invalidParams(_ message: String) -> JSONRPCError {
    JSONRPCError(code: invalidParams, message: message)
  }

  public static func internalError(_ message: String) -> JSONRPCError {
    JSONRPCError(code: internalError, message: message)
  }

  public var errorDescription: String? { "\(message) (\(code))" }
}

/// A bidirectional stream of JSON-RPC messages. Both ACP directions and the
/// MCP server ride on the same abstraction; only the peers' handlers differ.
public protocol JSONRPCTransport: Sendable {
  /// Every message the other side sends, until the stream closes.
  func messages() -> AsyncStream<JSONRPCMessage>
  func send(_ message: JSONRPCMessage) throws
  func close()
}

/// Newline-delimited JSON over a pair of file handles: this process's stdio
/// when serving an IDE, or a child process's pipes when driving an agent.
public final class StdioJSONRPCTransport: JSONRPCTransport, @unchecked Sendable {
  private let input: FileHandle
  private let output: FileHandle
  private let process: Process?
  private let writeLock = NSLock()
  private let stateLock = NSLock()
  private var continuation: AsyncStream<JSONRPCMessage>.Continuation?
  private var stream: AsyncStream<JSONRPCMessage>?
  private var isClosed = false
  private var reachedEOF = false
  /// The last lines of the child's stderr, so a failure can say why.
  private var errorTail: [String] = []

  public init(input: FileHandle, output: FileHandle, process: Process? = nil) {
    self.input = input
    self.output = output
    self.process = process
  }

  /// Serves whoever started this process.
  public static func standardIO() -> StdioJSONRPCTransport {
    StdioJSONRPCTransport(input: .standardInput, output: .standardOutput)
  }

  /// Starts a child and speaks to it over its pipes. Commands without a slash
  /// are resolved through `env`, as a shell would.
  public static func spawn(
    command: String,
    arguments: [String] = [],
    environment: [String: String]? = nil,
    workingDirectory: URL? = nil
  ) throws -> StdioJSONRPCTransport {
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    let executable = NSString(string: command).expandingTildeInPath
    if executable.contains("/") {
      child.executableURL = URL(fileURLWithPath: executable).standardizedFileURL
      child.arguments = arguments
    } else {
      child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      child.arguments = [executable] + arguments
    }
    if let environment { child.environment = environment }
    child.currentDirectoryURL = workingDirectory
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = stderr
    try child.run()
    #if os(macOS)
      _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    #endif
    let transport = StdioJSONRPCTransport(
      input: stdout.fileHandleForReading,
      output: stdin.fileHandleForWriting,
      process: child)
    transport.drainErrors(from: stderr.fileHandleForReading)
    return transport
  }

  public var isRunning: Bool { !stateLock.withLock { isClosed || reachedEOF } && (process?.isRunning ?? true) }

  private var isClosedNow: Bool { stateLock.withLock { isClosed } }

  /// What the child wrote to stderr recently, for error messages.
  public var recentErrorOutput: String {
    stateLock.withLock { errorTail.joined(separator: "\n") }
  }

  public func messages() -> AsyncStream<JSONRPCMessage> {
    let state: (
      stream: AsyncStream<JSONRPCMessage>,
      created: AsyncStream<JSONRPCMessage>.Continuation?,
      shouldStart: Bool
    ) = stateLock.withLock {
      if let stream { return (stream, nil, false) }
      let (stream, continuation) = AsyncStream<JSONRPCMessage>.makeStream(
        bufferingPolicy: .unbounded)
      self.stream = stream
      self.continuation = continuation
      return (stream, continuation, !isClosed)
    }
    if state.shouldStart {
      startReading()
    } else {
      state.created?.finish()
    }
    return state.stream
  }

  public func send(_ message: JSONRPCMessage) throws {
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)
    try writeLock.withLock {
      guard !isClosedNow else { throw JSONRPCTransportError.closed }
      try output.write(contentsOf: data)
    }
  }

  public func close() {
    let state: (shouldClose: Bool, pending: AsyncStream<JSONRPCMessage>.Continuation?) =
      stateLock.withLock {
        guard !isClosed else { return (false, nil) }
        isClosed = true
        let pending = continuation
        continuation = nil
        return (true, pending)
      }
    guard state.shouldClose else { return }
    state.pending?.finish()
    try? input.close()
    // A sender holds this lock from the closed-state check through its write.
    // Closing the handle under the same lock prevents close/write races.
    writeLock.withLock { try? output.close() }
    if let process, process.isRunning {
      process.terminate()
      // Give a well-behaved agent a moment to exit before pulling the plug.
      // On Windows terminate() already ends the process outright.
      #if !os(Windows)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
          if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
      #endif
    }
  }

  /// One blocking reader thread per transport: FileHandle's readability
  /// handlers fire on a shared queue and interleave badly under load.
  private func startReading() {
    let thread = Thread { [weak self] in
      guard let self else { return }
      var buffer = Data()
      while true {
        let chunk = self.input.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        // A network peer must not grow an unterminated frame without bound.
        guard buffer.count <= 16 * 1024 * 1024 else { self.close(); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
          let line = buffer[..<newline]
          buffer.removeSubrange(...newline)
          self.deliver(line)
        }
      }
      if !buffer.isEmpty { self.deliver(buffer) }
      self.stateLock.withLock { self.reachedEOF = true }
      self.finishMessages()
    }
    thread.name = "mai.jsonrpc.reader"
    thread.start()
  }

  private func deliver(_ line: Data) {
    let trimmed = line.filter { $0 != 0x0D }
    guard !trimmed.isEmpty, trimmed.first == UInt8(ascii: "{") else { return }
    guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: trimmed) else {
      return
    }
    stateLock.withLock { continuation }?.yield(message)
  }

  private func finishMessages() {
    let pending = stateLock.withLock { () -> AsyncStream<JSONRPCMessage>.Continuation? in
      let pending = continuation
      continuation = nil
      return pending
    }
    pending?.finish()
  }

  private func drainErrors(from handle: FileHandle) {
    let thread = Thread { [weak self] in
      while let self {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        guard let text = String(data: chunk, encoding: .utf8) else { continue }
        self.stateLock.withLock {
          self.errorTail.append(contentsOf: text.split(separator: "\n").map(String.init))
          if self.errorTail.count > 20 {
            self.errorTail.removeFirst(self.errorTail.count - 20)
          }
        }
      }
    }
    thread.name = "mai.jsonrpc.stderr"
    thread.start()
  }
}

public enum JSONRPCTransportError: LocalizedError, Equatable, Sendable {
  case closed
  case timedOut(String)

  public var errorDescription: String? {
    switch self {
    case .closed: "The JSON-RPC connection is closed."
    case .timedOut(let method): "No reply to \(method) in time."
    }
  }
}

/// Correlates outgoing requests with their replies and dispatches the other
/// side's requests and notifications to handlers. An ACP client and an ACP
/// server are both peers; the handlers are the only difference.
public actor JSONRPCPeer {
  public typealias RequestHandler = @Sendable (String, JSONValue?) async throws -> JSONValue
  public typealias NotificationHandler = @Sendable (String, JSONValue?) async -> Void

  private let transport: any JSONRPCTransport
  private let onRequest: RequestHandler
  private let onNotification: NotificationHandler
  private var nextID = 1
  private struct PendingRequest {
    let continuation: CheckedContinuation<JSONValue, Error>
    var timeout: Task<Void, Never>?
  }

  private var pending: [Int: PendingRequest] = [:]
  private var reader: Task<Void, Never>?
  private var closed = false
  private var incoming: [UUID: Task<Void, Never>] = [:]

  public init(
    transport: any JSONRPCTransport,
    onRequest: @escaping RequestHandler = { method, _ in
      throw JSONRPCError.methodNotFound(method)
    },
    onNotification: @escaping NotificationHandler = { _, _ in }
  ) {
    self.transport = transport
    self.onRequest = onRequest
    self.onNotification = onNotification
  }

  /// Begins reading. Returns once the other side closes the connection, so a
  /// server can `await` it and a client can run it in a task.
  public func run() async {
    for await message in transport.messages() {
      if message.isResponse {
        resolve(message)
      } else if let method = message.method {
        if message.id == nil {
          await onNotification(method, message.params)
        } else {
          dispatch(method: method, message: message)
        }
      }
    }
    let tasks = Array(incoming.values)
    finish()
    for task in tasks { await task.value }
  }

  /// Starts `run` in the background, for peers that also send requests.
  public func start() {
    guard reader == nil else { return }
    reader = Task { await run() }
  }

  public func request(
    _ method: String,
    params: JSONValue? = nil,
    timeout: TimeInterval? = nil
  ) async throws -> JSONValue {
    guard !closed else { throw JSONRPCTransportError.closed }
    let id = nextID
    nextID += 1
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        register(
          id: id, continuation: continuation, method: method, params: params,
          timeout: timeout)
      }
    } onCancel: {
      Task { await self.cancelPending(id: id) }
    }
  }

  public nonisolated func notify(_ method: String, params: JSONValue? = nil) throws {
    try transport.send(.notification(method, params: params))
  }

  public func close() {
    finish()
    transport.close()
  }

  private func register(
    id: Int,
    continuation: CheckedContinuation<JSONValue, Error>,
    method: String,
    params: JSONValue?,
    timeout: TimeInterval?
  ) {
    guard !closed, !Task.isCancelled else {
      continuation.resume(throwing: Task.isCancelled ? CancellationError() : JSONRPCTransportError.closed)
      return
    }
    pending[id] = PendingRequest(continuation: continuation)
    do {
      try transport.send(.request(id: id, method: method, params: params))
    } catch {
      pending[id] = nil
      continuation.resume(throwing: error)
      return
    }
    if let timeout, timeout > 0 {
      let timer = Task { [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        guard !Task.isCancelled else { return }
        await self?.timeoutPending(id: id, method: method)
      }
      pending[id]?.timeout = timer
    }
  }

  private func cancelPending(id: Int) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeout?.cancel()
    request.continuation.resume(throwing: CancellationError())
  }

  private func timeoutPending(id: Int, method: String) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.continuation.resume(throwing: JSONRPCTransportError.timedOut(method))
  }

  private func resolve(_ message: JSONRPCMessage) {
    guard let id = message.id?.intValue, let request = pending.removeValue(forKey: id)
    else { return }
    request.timeout?.cancel()
    if let error = message.error {
      request.continuation.resume(throwing: error)
    } else {
      request.continuation.resume(returning: message.result ?? .null)
    }
  }

  /// Requests run concurrently: an agent may ask for permission while its
  /// prompt is still being answered, and the answer must not wait for it.
  private func dispatch(method: String, message: JSONRPCMessage) {
    guard let id = message.id else {
      Task { await onNotification(method, message.params) }
      return
    }
    let token = UUID()
    incoming[token] = Task { [transport, onRequest] in
      defer { incoming[token] = nil }
      do {
        try Task.checkCancellation()
        let result = try await onRequest(method, message.params)
        try transport.send(.response(id: id, result: result))
      } catch let error as JSONRPCError {
        try? transport.send(.failure(id: id, error: error))
      } catch {
        try? transport.send(
          .failure(id: id, error: .internalError(error.localizedDescription)))
      }
    }
  }

  private func finish() {
    guard !closed else { return }
    closed = true
    reader?.cancel()
    for task in incoming.values { task.cancel() }
    for request in pending.values {
      request.timeout?.cancel()
      request.continuation.resume(throwing: JSONRPCTransportError.closed)
    }
    pending.removeAll()
  }
}
