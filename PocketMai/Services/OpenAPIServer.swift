import Foundation
import Network

enum OpenAPIServerRuntimeState: Equatable, Sendable {
  case stopped
  case starting(Int)
  case running(Int)
  case failed(String)

  var isRunning: Bool {
    if case .running = self { return true }
    return false
  }

  var isActive: Bool {
    switch self {
    case .starting, .running:
      return true
    case .stopped, .failed:
      return false
    }
  }

  var port: Int? {
    switch self {
    case .starting(let port), .running(let port):
      return port
    case .stopped, .failed:
      return nil
    }
  }
}

struct OpenAPIServerHTTPRequest: Sendable {
  var method: String
  var path: String
  var queryItems: [String: String]
  var headers: [String: String]
  var body: Data

  func decodedBody<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: body)
  }
}

struct OpenAPIServerHTTPResponse: Sendable {
  var statusCode: Int
  var reason: String
  var headers: [String: String]
  var body: Data
  var stream: AsyncThrowingStream<Data, Error>? = nil

  static func json(
    _ object: Any,
    statusCode: Int = 200,
    headers: [String: String] = [:]
  ) -> OpenAPIServerHTTPResponse {
    do {
      let data = try JSONSerialization.data(withJSONObject: object)
      return OpenAPIServerHTTPResponse(
        statusCode: statusCode,
        reason: reasonPhrase(for: statusCode),
        headers: ["Content-Type": "application/json"] + headers,
        body: data)
    } catch {
      return Self.error(statusCode: 500, message: "Could not encode JSON response.")
    }
  }

  static func text(
    _ text: String,
    statusCode: Int = 200,
    contentType: String = "text/plain; charset=utf-8"
  ) -> OpenAPIServerHTTPResponse {
    OpenAPIServerHTTPResponse(
      statusCode: statusCode,
      reason: reasonPhrase(for: statusCode),
      headers: ["Content-Type": contentType],
      body: Data(text.utf8))
  }

  static func error(statusCode: Int, message: String) -> OpenAPIServerHTTPResponse {
    json(["error": message], statusCode: statusCode)
  }

  func serialized(chunked: Bool = true) -> Data {
    var responseHeaders = headers
    if stream == nil {
      responseHeaders["Content-Length"] = "\(body.count)"
    } else if chunked {
      responseHeaders["Transfer-Encoding"] = "chunked"
    }
    responseHeaders["Connection"] = "close"
    responseHeaders["Access-Control-Allow-Origin"] = "*"
    responseHeaders["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    responseHeaders["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"

    var head = "\(chunked ? "HTTP/1.1" : "HTTP/1.0") \(statusCode) \(reason)\r\n"
    for (key, value) in responseHeaders.sorted(by: { $0.key < $1.key }) {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"

    var data = Data(head.utf8)
    data.append(body)
    return data
  }

  private static func reasonPhrase(for statusCode: Int) -> String {
    switch statusCode {
    case 200: return "OK"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 413: return "Payload Too Large"
    case 429: return "Too Many Requests"
    case 502: return "Bad Gateway"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 409: return "Conflict"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default: return "OK"
    }
  }
}

private func + (lhs: [String: String], rhs: [String: String]) -> [String: String] {
  lhs.merging(rhs) { _, new in new }
}

final class OpenAPIServer: @unchecked Sendable {
  typealias RequestHandler = @Sendable (OpenAPIServerHTTPRequest) async -> OpenAPIServerHTTPResponse
  typealias StateHandler = @Sendable (OpenAPIServerRuntimeState) -> Void

  private let queue = DispatchQueue(label: "app.pocketmai.openapi-server")
  private var listener: NWListener?
  private var connections: [UUID: OpenAPIServerConnection] = [:]
  private var stateHandler: StateHandler?
  private var generation = UUID()

  func start(
    port: Int,
    requestHandler: @escaping RequestHandler,
    stateHandler: @escaping StateHandler
  ) {
    queue.async { [weak self] in
      self?.startOnQueue(
        port: port,
        requestHandler: requestHandler,
        stateHandler: stateHandler)
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.stopOnQueue(reportStopped: true)
    }
  }

  private func startOnQueue(
    port: Int,
    requestHandler: @escaping RequestHandler,
    stateHandler: @escaping StateHandler
  ) {
    stopOnQueue(reportStopped: false)
    self.stateHandler = stateHandler
    let activeGeneration = UUID()
    generation = activeGeneration
    stateHandler(.starting(port))

    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
      stateHandler(.failed("Invalid port \(port)."))
      return
    }

    do {
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      let listener = try NWListener(using: parameters, on: nwPort)
      self.listener = listener

      listener.stateUpdateHandler = { [weak self] state in
        self?.handleListenerState(state, port: port, generation: activeGeneration)
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(
          connection,
          requestHandler: requestHandler,
          generation: activeGeneration)
      }
      listener.start(queue: queue)
    } catch {
      stateHandler(.failed(error.localizedDescription))
    }
  }

  private func stopOnQueue(reportStopped: Bool) {
    generation = UUID()
    listener?.cancel()
    listener = nil
    let activeConnections = Array(connections.values)
    connections.removeAll()
    for connection in activeConnections {
      connection.cancel()
    }
    if reportStopped {
      stateHandler?(.stopped)
    }
  }

  private func handleListenerState(_ state: NWListener.State, port: Int, generation: UUID) {
    guard generation == self.generation else { return }
    switch state {
    case .ready:
      stateHandler?(.running(port))
    case .failed(let error):
      stopOnQueue(reportStopped: false)
      stateHandler?(.failed(error.localizedDescription))
    case .cancelled:
      stateHandler?(.stopped)
    default:
      break
    }
  }

  private func accept(
    _ connection: NWConnection,
    requestHandler: @escaping RequestHandler,
    generation: UUID
  ) {
    guard generation == self.generation else {
      connection.cancel()
      return
    }
    let id = UUID()
    let handler = OpenAPIServerConnection(
      id: id,
      connection: connection,
      queue: queue,
      requestHandler: requestHandler
    ) { [weak self] id in
      self?.connections[id] = nil
    }
    connections[id] = handler
    handler.start()
  }
}

private final class OpenAPIServerConnection: @unchecked Sendable {
  private let id: UUID
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let requestHandler: OpenAPIServer.RequestHandler
  private let onFinish: @Sendable (UUID) -> Void
  private var buffer = Data()
  private var didFinish = false
  private var supportsChunked = true
  private var didCleanup = false
  private var requestTask: Task<Void, Never>?

  init(
    id: UUID,
    connection: NWConnection,
    queue: DispatchQueue,
    requestHandler: @escaping OpenAPIServer.RequestHandler,
    onFinish: @escaping @Sendable (UUID) -> Void
  ) {
    self.id = id
    self.connection = connection
    self.queue = queue
    self.requestHandler = requestHandler
    self.onFinish = onFinish
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      if case .failed = state {
        self.finish()
      } else if case .cancelled = state {
        self.finish()
      }
    }
    connection.start(queue: queue)
    receiveNext()
  }

  func cancel() {
    requestTask?.cancel()
    connection.cancel()
    finish()
  }

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self, !self.didFinish else { return }

      if let data, !data.isEmpty {
        self.buffer.append(data)
      }

      do {
        if let request = try self.parsedRequestIfComplete() {
          self.didFinish = true
          self.requestTask = Task {
            let response = await self.requestHandler(request)
            await self.send(response)
          }
          return
        }
      } catch {
        self.didFinish = true
        self.requestTask = Task {
          await self.send(.error(statusCode: 400, message: error.localizedDescription))
        }
        return
      }

      if error != nil || isComplete {
        self.finish()
        return
      }

      self.receiveNext()
    }
  }

  private func sendPart(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }

  private func send(_ response: OpenAPIServerHTTPResponse) async {
    do {
      try await sendPart(response.serialized(chunked: supportsChunked))
      if let stream = response.stream {
        for try await chunk in stream {
          try Task.checkCancellation()
          guard !chunk.isEmpty else { continue }
          if supportsChunked {
            var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
            framed.append(chunk)
            framed.append(Data("\r\n".utf8))
            try await sendPart(framed)
          } else {
            try await sendPart(chunk)
          }
        }
        if supportsChunked { try await sendPart(Data("0\r\n\r\n".utf8)) }
      }
    } catch { /* Headers may already be sent; close an interrupted audio stream. */  }
    queue.async { [weak self] in
      self?.connection.cancel()
      self?.finish()
    }
  }

  private func finish() {
    guard !didCleanup else { return }
    didCleanup = true
    requestTask?.cancel()
    requestTask = nil
    didFinish = true
    onFinish(id)
  }

  private func parsedRequestIfComplete() throws -> OpenAPIServerHTTPRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard buffer.count <= 26 * 1024 * 1024 else { throw OpenAPIServerParseError.invalidRequest }
    guard let headerRange = buffer.range(of: delimiter) else {
      guard buffer.count <= 65536 else { throw OpenAPIServerParseError.invalidRequest }
      return nil
    }
    let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      throw OpenAPIServerParseError.invalidRequest
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw OpenAPIServerParseError.invalidRequest
    }
    let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard requestParts.count == 3 else {
      throw OpenAPIServerParseError.invalidRequest
    }

    supportsChunked = requestParts[2] != "HTTP/1.0"
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !key.isEmpty {
        headers[key] = value
      }
    }

    guard headers["transfer-encoding"] == nil,
      let contentLength = Int(headers["content-length"] ?? "0"),
      contentLength >= 0, contentLength <= 25 * 1024 * 1024
    else {
      throw OpenAPIServerParseError.invalidRequest
    }
    let bodyStart = headerRange.upperBound
    let bodyEnd = bodyStart + contentLength
    guard buffer.count >= bodyEnd else { return nil }

    let rawPath = requestParts[1]
    let components = URLComponents(string: rawPath)
    let path = components?.path.isEmpty == false ? components?.path ?? rawPath : rawPath
    var queryItems: [String: String] = [:]
    for item in components?.queryItems ?? [] {
      if let value = item.value {
        queryItems[item.name] = value
      }
    }
    let body = contentLength > 0 ? buffer.subdata(in: bodyStart..<bodyEnd) : Data()

    return OpenAPIServerHTTPRequest(
      method: requestParts[0].uppercased(),
      path: path,
      queryItems: queryItems,
      headers: headers,
      body: body)
  }
}

private enum OpenAPIServerParseError: LocalizedError {
  case invalidRequest

  var errorDescription: String? {
    switch self {
    case .invalidRequest:
      return "Invalid HTTP request."
    }
  }
}

struct OpenAPIServerInboundMessage: Decodable, Sendable {
  var role: String
  var content: String

  enum CodingKeys: String, CodingKey {
    case role, content
  }

  init(role: String, content: String) {
    self.role = role
    self.content = content
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    role = (try? c.decode(String.self, forKey: .role)) ?? "user"
    if let text = try? c.decode(String.self, forKey: .content) {
      content = text
      return
    }
    if let parts = try? c.decode([OpenAPIServerContentPart].self, forKey: .content) {
      content = parts.compactMap(\.text).joined(separator: "\n")
      return
    }
    content = ""
  }
}

private struct OpenAPIServerContentPart: Decodable {
  var type: String?
  var text: String?
}

struct OpenAPIServerCompletionInput: Sendable {
  var model: String?
  var messages: [OpenAPIServerInboundMessage]
  var prompt: String?
  var system: String?
  var stream: Bool

  var latestUserText: String {
    if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return prompt
    }
    return messages.last(where: { $0.role.caseInsensitiveCompare("user") == .orderedSame })?
      .content
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
  }

  func chatMessagesForProxy() -> [ChatMessage] {
    var result: [ChatMessage] = []
    if let system,
      !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      result.append(ChatMessage(role: .system, text: system))
    }
    result.append(
      contentsOf: messages.compactMap { message in
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch message.role.lowercased() {
        case "system":
          return ChatMessage(role: .system, text: text)
        case "assistant":
          return ChatMessage(role: .assistant, text: text)
        case "tool":
          return ChatMessage(role: .tool, text: text)
        default:
          return ChatMessage(role: .user, text: text)
        }
      })
    if result.isEmpty {
      let text = latestUserText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        result.append(ChatMessage(role: .user, text: text))
      }
    }
    return result
  }
}

struct OpenAPIServerToolRun: Sendable {
  var name: String
  var argumentsJSON: String
  var result: String
  var isError: Bool
}

struct OpenAPIServerCompletionOutput: Sendable {
  var text: String
  var model: String
  var toolRuns: [OpenAPIServerToolRun] = []
}

struct OpenAPIServerOllamaChatRequest: Decodable, Sendable {
  var model: String?
  var messages: [OpenAPIServerInboundMessage]
  var stream: Bool?
}

struct OpenAPIServerOllamaGenerateRequest: Decodable, Sendable {
  var model: String?
  var prompt: String?
  var system: String?
  var stream: Bool?
}

struct OpenAPIServerOpenAIChatRequest: Decodable, Sendable {
  var model: String?
  var messages: [OpenAPIServerInboundMessage]
  var stream: Bool?
}
