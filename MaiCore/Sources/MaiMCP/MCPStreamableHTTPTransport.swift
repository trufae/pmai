import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum MCPStreamableHTTPTransport {
  private static let protocolVersion = "2025-11-25"
  private static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  private static let protocolVersionHeader = "MCP-Protocol-Version"
  private static let sessionIDHeader = "Mcp-Session-Id"
  private static let sessions = MCPSessionStore()

  // MARK: - Public API

  public struct Catalog: Sendable {
    public var tools: [ToolDefinition]
    public var resources: [MCPResourceDescriptor]
    public var serverName: String?
    public var protocolVersion: String?

    public init(
      tools: [ToolDefinition],
      resources: [MCPResourceDescriptor],
      serverName: String?,
      protocolVersion: String?
    ) {
      self.tools = tools
      self.resources = resources
      self.serverName = serverName
      self.protocolVersion = protocolVersion
    }
  }

  public static func fetchCatalog(
    server: MCPServerConfiguration,
    session: URLSession = .shared
  ) async throws -> Catalog {
    let handshake = try await ensureSession(for: server, session: session)
    var firstError: Error?

    let tools: [ToolDefinition]
    do {
      tools = try await fetchTools(server: server, session: session)
    } catch {
      if isMethodNotFound(error) {
        tools = []
      } else {
        firstError = error
        tools = []
      }
    }

    let resources: [MCPResourceDescriptor]
    do {
      resources = try await fetchResources(server: server, session: session)
    } catch {
      if isMethodNotFound(error) {
        resources = []
      } else {
        firstError = firstError ?? error
        resources = []
      }
    }

    if tools.isEmpty, resources.isEmpty, let firstError {
      throw firstError
    }
    return Catalog(
      tools: tools,
      resources: resources,
      serverName: handshake.serverName,
      protocolVersion: handshake.protocolVersion)
  }

  public static func fetchTools(
    server: MCPServerConfiguration,
    session: URLSession = .shared
  ) async throws
    -> [ToolDefinition]
  {
    var definitions: [ToolDefinition] = []
    var cursor: String?
    repeat {
      let params = cursor.map { ["cursor": JSONValue.string($0)] }
      let result = try await sendResult(
        server: server, method: "tools/list", params: params, session: session)
      for value in result.objectValue?["tools"]?.arrayValue ?? [] {
        guard let tool = value.objectValue,
          let name = tool["name"]?.stringValue,
          !name.isEmpty
        else { continue }
        let annotations = tool["annotations"]?.objectValue ?? [:]
        let destructive = annotations["destructiveHint"]?.boolValue ?? false
        definitions.append(
          ToolDefinition(
            name: name,
            description: tool["description"]?.stringValue ?? "",
            inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")]),
            annotations: ToolAnnotations(
              title: annotations["title"]?.stringValue,
              readOnly: annotations["readOnlyHint"]?.boolValue ?? false,
              destructive: destructive,
              idempotent: annotations["idempotentHint"]?.boolValue ?? false,
              openWorld: annotations["openWorldHint"]?.boolValue ?? true,
              approval: destructive ? .dangerous : server.defaultApproval, requiresInternet: true)))
      }
      cursor = result.objectValue?["nextCursor"]?.stringValue
    } while cursor?.isEmpty == false
    return definitions
  }

  public static func fetchResources(
    server: MCPServerConfiguration,
    session: URLSession = .shared
  ) async throws
    -> [MCPResourceDescriptor]
  {
    var resources: [MCPResourceDescriptor] = []
    var cursor: String?
    repeat {
      let params = cursor.map { ["cursor": JSONValue.string($0)] }
      let result = try await sendResult(
        server: server, method: "resources/list", params: params, session: session)
      for value in result.objectValue?["resources"]?.arrayValue ?? [] {
        guard let resource = value.objectValue,
          let uri = resource["uri"]?.stringValue,
          !uri.isEmpty
        else { continue }
        resources.append(
          MCPResourceDescriptor(
            uri: uri,
            name: resource["name"]?.stringValue ?? "",
            description: resource["description"]?.stringValue ?? "",
            mimeType: resource["mimeType"]?.stringValue))
      }
      cursor = result.objectValue?["nextCursor"]?.stringValue
    } while cursor?.isEmpty == false
    return resources
  }

  public static func readResource(
    server: MCPServerConfiguration,
    uri: String,
    session: URLSession = .shared
  ) async throws -> [ContentPart] {
    let result = try await sendResult(
      server: server,
      method: "resources/read",
      params: ["uri": .string(uri)],
      session: session)
    let content = try (result.objectValue?["contents"]?.arrayValue ?? []).map(mcpContent)
    return content.isEmpty ? [.text("(empty resource)")] : content
  }

  public static func callTool(
    server: MCPServerConfiguration,
    name: String,
    arguments: JSONValue,
    session: URLSession = .shared
  ) async throws -> ToolOutput {
    let result: JSONValue
    do {
      result = try await sendResult(
        server: server,
        method: "tools/call",
        params: ["name": .string(name), "arguments": arguments],
        session: session)
    } catch let error as MCPPartialOutputError {
      return error.toolOutput
    }
    let content = try (result.objectValue?["content"]?.arrayValue ?? []).map(mcpContent)
    return ToolOutput(
      content: content.isEmpty ? [.text("(no output)")] : content,
      structuredContent: result.objectValue?["structuredContent"],
      isError: result.objectValue?["isError"]?.boolValue ?? false)
  }

  public static func resetSession(for serverID: String, session: URLSession = .shared) async {
    if let cached = await sessions.remove(serverID) {
      await terminate(cached, using: session)
    }
  }

  public static func resetAllSessions(session: URLSession = .shared) async {
    let staleSessions = await sessions.removeAll()
    for staleSession in staleSessions {
      await terminate(staleSession, using: session)
    }
  }

  public static func isAvailabilityFailure(_ error: Error) -> Bool {
    if let error = error as? MCPPartialOutputError {
      return isAvailabilityFailure(error.underlying)
    }
    if error is URLError {
      return true
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      return true
    }
    if error is DecodingError {
      return true
    }
    if error is MCPHTTPError {
      return true
    }
    if error is MCPStreamableHTTPError || error is MCPLegacySSETransportError {
      return true
    }
    if let error = error as? MCPClientError {
      switch error {
      case .invalidURL, .invalidResponse:
        return true
      case .httpError, .rpcError:
        return false
      }
    }
    return false
  }

  // MARK: - Session and request lifecycle

  private static func send(
    server: MCPServerConfiguration,
    method: String,
    params: [String: JSONValue]? = nil,
    session: URLSession,
    retryingInvalidSession: Bool = true
  ) async throws -> Data {
    let handshake = try await ensureSession(for: server, session: session)
    do {
      let response = try await sendRaw(
        server: server,
        method: method,
        params: params,
        sessionID: handshake.sessionID,
        negotiatedProtocolVersion: handshake.protocolVersion,
        session: session)
      if let raw = jsonObject(from: response.data),
        let error = responseError(from: raw)
      {
        if retryingInvalidSession && error.isInvalidSessionID {
          await sessions.remove(server.id)
          return try await send(
            server: server,
            method: method,
            params: params,
            session: session,
            retryingInvalidSession: false)
        }
        throw error
      }
      return response.data
    } catch {
      if retryingInvalidSession && isInvalidSessionID(error) {
        await sessions.remove(server.id)
        return try await send(
          server: server,
          method: method,
          params: params,
          session: session,
          retryingInvalidSession: false)
      }
      throw error
    }
  }

  private static func ensureSession(for server: MCPServerConfiguration, session: URLSession)
    async throws
    -> MCPHandshake
  {
    if looksLikeLegacySSEURL(server.url.absoluteString) {
      throw MCPLegacySSETransportError()
    }
    let baseURL = try normalizedBaseURL(for: server).absoluteString
    if let cached = await sessions.session(
      for: server.id,
      baseURL: baseURL,
      authorizationHeader: authorizationHeader(for: server))
    {
      return cached.handshake
    }

    var initialized: (response: MCPHTTPResponse, requestedVersion: String)?
    var lastError: Error?
    for requestedVersion in supportedProtocolVersions {
      do {
        let response = try await sendRaw(
          server: server,
          method: "initialize",
          params: initializeParams(protocolVersion: requestedVersion),
          sessionID: nil,
          negotiatedProtocolVersion: requestedVersion,
          session: session)
        if let raw = jsonObject(from: response.data), let error = responseError(from: raw) {
          if error.isUnsupportedProtocolVersion {
            lastError = error
            continue
          }
          throw error
        }
        initialized = (response, requestedVersion)
        break
      } catch let error as MCPHTTPError where error.isUnsupportedProtocolVersion {
        lastError = error
      } catch {
        lastError = error
        break
      }
    }
    guard let initialized else {
      if let error = lastError as? MCPHTTPError, error.isPossibleLegacySSEEndpoint,
        await endpointUsesLegacySSE(server: server, session: session)
      {
        throw MCPLegacySSETransportError()
      }
      throw lastError ?? MCPStreamableHTTPError.missingResponse
    }

    let response = initialized.response
    let metadata = initializeMetadata(from: response.data)
    let negotiatedProtocolVersion = metadata.protocolVersion ?? initialized.requestedVersion
    let handshake = MCPHandshake(
      sessionID: response.sessionID,
      protocolVersion: negotiatedProtocolVersion,
      serverName: metadata.serverName)
    try await sendInitializedNotification(
      server: server,
      sessionID: response.sessionID,
      negotiatedProtocolVersion: negotiatedProtocolVersion,
      session: session)
    await sessions.set(
      handshake,
      for: server.id,
      baseURL: baseURL,
      authorizationHeader: authorizationHeader(for: server))
    return handshake
  }

  private static func sendInitializedNotification(
    server: MCPServerConfiguration,
    sessionID: String?,
    negotiatedProtocolVersion: String?,
    session: URLSession
  )
    async throws
  {
    let response = try await sendRaw(
      server: server,
      method: "notifications/initialized",
      params: nil,
      sessionID: sessionID,
      isNotification: true,
      negotiatedProtocolVersion: negotiatedProtocolVersion,
      session: session)
    if let raw = jsonObject(from: response.data),
      let error = responseError(from: raw)
    {
      throw error
    }
  }

  private static func sendRaw(
    server: MCPServerConfiguration,
    method: String,
    params: [String: JSONValue]? = nil,
    sessionID: String?,
    isNotification: Bool = false,
    negotiatedProtocolVersion: String?,
    session: URLSession
  ) async throws -> MCPHTTPResponse {
    let url = try normalizedBaseURL(for: server)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(
      negotiatedProtocolVersion ?? protocolVersion,
      forHTTPHeaderField: protocolVersionHeader)
    applyHeaders(for: server, to: &request)
    if let sessionID, !sessionID.isEmpty {
      request.setValue(sessionID, forHTTPHeaderField: sessionIDHeader)
    }
    request.timeoutInterval = server.timeout
    let requestID = isNotification ? nil : Int.random(in: 1...Int(Int32.max))
    var params = params
    if let requestID, method == "tools/call" || method == "resources/read" {
      var values = params ?? [:]
      var meta = values["_meta"]?.objectValue ?? [:]
      meta["progressToken"] = .integer(requestID)
      values["_meta"] = .object(meta)
      params = values
    }
    let body = JSONRPCRequest(
      id: requestID,
      method: method,
      params: params)
    request.httpBody = try JSONEncoder().encode(body)
    return try await perform(
      request,
      server: server,
      expectedResponseID: body.id,
      sessionID: sessionID,
      protocolVersion: negotiatedProtocolVersion ?? protocolVersion,
      session: session)
  }

  private static func perform(
    _ request: URLRequest,
    server: MCPServerConfiguration,
    expectedResponseID: Int?,
    sessionID: String?,
    protocolVersion: String,
    session: URLSession
  ) async throws -> MCPHTTPResponse {
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      let data = try await collect(bytes)
      return MCPHTTPResponse(data: data, sessionID: nil)
    }
    let returnedSessionID = normalizedHeader(
      http.value(forHTTPHeaderField: sessionIDHeader))
    guard (200..<300).contains(http.statusCode) else {
      let data = try await collect(bytes)
      let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
      throw MCPHTTPError(
        statusCode: http.statusCode,
        body: snippet,
        hadSessionID: sessionID != nil,
        hadAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil)
    }

    if http.statusCode == 202 {
      return MCPHTTPResponse(data: Data(), sessionID: returnedSessionID)
    }
    guard expectedResponseID != nil else {
      _ = try await collect(bytes)
      return MCPHTTPResponse(data: Data(), sessionID: returnedSessionID)
    }

    switch contentType(from: http) {
    case "application/json":
      let data = try await collect(bytes)
      guard !data.isEmpty else {
        throw MCPStreamableHTTPError.missingResponse
      }
      if let expectedResponseID {
        try validateJSONResponse(data, expectedResponseID: expectedResponseID)
      }
      return MCPHTTPResponse(data: data, sessionID: returnedSessionID)
    case "text/event-stream":
      guard let expectedResponseID else {
        throw MCPStreamableHTTPError.unexpectedEventStream
      }
      let data = try await responseFromEventStream(
        bytes,
        expectedResponseID: expectedResponseID,
        server: server,
        sessionID: sessionID ?? returnedSessionID,
        protocolVersion: protocolVersion,
        timeout: request.timeoutInterval,
        session: session)
      return MCPHTTPResponse(data: data, sessionID: returnedSessionID)
    default:
      let data = try await collect(bytes)
      let type = normalizedHeader(http.value(forHTTPHeaderField: "Content-Type")) ?? "missing"
      let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
      throw MCPStreamableHTTPError.unsupportedContentType(type, snippet)
    }
  }

  // MARK: - Streamable HTTP responses

  private static func responseFromEventStream(
    _ bytes: URLSession.AsyncBytes,
    expectedResponseID: Int,
    server: MCPServerConfiguration,
    sessionID: String?,
    protocolVersion: String,
    timeout: TimeInterval,
    session: URLSession
  ) async throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    var currentBytes = bytes
    var output = MCPPartialOutput()
    do {
      while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        let outcome = try await consumeEventStream(
          currentBytes,
          expectedResponseID: expectedResponseID,
          server: server,
          sessionID: sessionID,
          protocolVersion: protocolVersion,
          timeout: remaining,
          session: session,
          output: &output)
        switch outcome {
        case .response(let data):
          return data
        case .reconnect(let eventID, let retryMilliseconds):
          let delay = TimeInterval(retryMilliseconds ?? 1_000) / 1_000
          let remainingAfterDelay = deadline.timeIntervalSinceNow - delay
          guard remainingAfterDelay > 0 else { throw URLError(.timedOut) }
          if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
          }
          currentBytes = try await resumeEventStream(
            server: server,
            eventID: eventID,
            sessionID: sessionID,
            protocolVersion: protocolVersion,
            timeout: remainingAfterDelay,
            session: session)
        }
      }
    } catch {
      try Task.checkCancellation()
      throw output.preserving(error)
    }
  }

  private static func consumeEventStream(
    _ bytes: URLSession.AsyncBytes,
    expectedResponseID: Int,
    server: MCPServerConfiguration,
    sessionID: String?,
    protocolVersion: String,
    timeout: TimeInterval,
    session: URLSession,
    output: inout MCPPartialOutput
  ) async throws -> MCPEventStreamOutcome {
    var parser = MCPServerSentEventParser()
    var line = Data()
    var afterCarriageReturn = false
    var lastEventID: String?
    var retryMilliseconds: Int?
    do {
      // AsyncBytes.lines can omit empty lines on Darwin, but SSE uses them
      // to delimit events. Preserve LF, CRLF, and CR framing explicitly.
      for try await byte in bytes {
        if byte == 0x0A, afterCarriageReturn {
          afterCarriageReturn = false
          continue
        }
        afterCarriageReturn = byte == 0x0D
        guard byte == 0x0A || byte == 0x0D else {
          guard line.count < 16 * 1_024 * 1_024 else {
            throw MCPStreamableHTTPError.responseTooLarge
          }
          line.append(byte)
          continue
        }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        guard let event = try parser.consume(line: text) else { continue }
        if let eventID = event.id { lastEventID = eventID.isEmpty ? nil : eventID }
        if let retry = event.retryMilliseconds { retryMilliseconds = retry }
        if let response = try await processEvent(
          event,
          expectedResponseID: expectedResponseID,
          server: server,
          sessionID: sessionID,
          protocolVersion: protocolVersion,
          timeout: timeout,
          session: session,
          output: &output)
        {
          return .response(response)
        }
      }
      if !line.isEmpty {
        _ = try parser.consume(line: String(decoding: line, as: UTF8.self))
      }
      if let event = try parser.finish() {
        if let eventID = event.id { lastEventID = eventID.isEmpty ? nil : eventID }
        if let retry = event.retryMilliseconds { retryMilliseconds = retry }
        if let response = try await processEvent(
          event,
          expectedResponseID: expectedResponseID,
          server: server,
          sessionID: sessionID,
          protocolVersion: protocolVersion,
          timeout: timeout,
          session: session,
          output: &output)
        {
          return .response(response)
        }
      }
    } catch {
      let nsError = error as NSError
      guard lastEventID != nil,
        error is URLError || nsError.domain == NSURLErrorDomain
      else {
        throw error
      }
    }
    guard let lastEventID else {
      throw MCPStreamableHTTPError.missingResponse
    }
    return .reconnect(eventID: lastEventID, retryMilliseconds: retryMilliseconds)
  }

  private static func processEvent(
    _ event: MCPServerSentEvent,
    expectedResponseID: Int,
    server: MCPServerConfiguration,
    sessionID: String?,
    protocolVersion: String,
    timeout: TimeInterval,
    session: URLSession,
    output: inout MCPPartialOutput
  ) async throws -> Data? {
    if event.isLegacyEndpointEvent {
      throw MCPLegacySSETransportError()
    }
    guard let message = try event.jsonRPCMessage() else { return nil }
    if let method = message.method, message.id == nil,
      let envelope = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)),
      let params = envelope.objectValue?["params"]?.objectValue
    {
      if method != "notifications/progress"
        || params["progressToken"] == .integer(expectedResponseID)
      {
        output.record(method: method, params: params)
      }
      return nil
    }
    if let method = message.method, let id = message.id {
      try await sendServerRequestResponse(
        server: server,
        requestID: id,
        method: method,
        sessionID: sessionID,
        protocolVersion: protocolVersion,
        timeout: timeout,
        session: session)
      return nil
    }
    guard message.method == nil, message.id == .integer(expectedResponseID) else {
      return nil
    }
    return try JSONSerialization.data(withJSONObject: message.object, options: [.sortedKeys])
  }

  private static func resumeEventStream(
    server: MCPServerConfiguration,
    eventID: String,
    sessionID: String?,
    protocolVersion: String,
    timeout: TimeInterval,
    session: URLSession
  ) async throws -> URLSession.AsyncBytes {
    var request = URLRequest(url: try normalizedBaseURL(for: server))
    request.httpMethod = "GET"
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(eventID, forHTTPHeaderField: "Last-Event-ID")
    request.setValue(protocolVersion, forHTTPHeaderField: protocolVersionHeader)
    applyHeaders(for: server, to: &request)
    if let sessionID, !sessionID.isEmpty {
      request.setValue(sessionID, forHTTPHeaderField: sessionIDHeader)
    }
    request.timeoutInterval = timeout
    let (bytes, rawResponse) = try await session.bytes(for: request)
    guard let response = rawResponse as? HTTPURLResponse else { return bytes }
    guard (200..<300).contains(response.statusCode) else {
      let data = try await collect(bytes)
      let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
      throw MCPHTTPError(
        statusCode: response.statusCode,
        body: snippet,
        hadSessionID: sessionID != nil,
        hadAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil)
    }
    guard contentType(from: response) == "text/event-stream" else {
      let data = try await collect(bytes)
      let type = normalizedHeader(response.value(forHTTPHeaderField: "Content-Type")) ?? "missing"
      let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
      throw MCPStreamableHTTPError.unsupportedContentType(type, snippet)
    }
    return bytes
  }

  private static func validateJSONResponse(_ data: Data, expectedResponseID: Int) throws {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["jsonrpc"] as? String == "2.0"
    else {
      throw MCPStreamableHTTPError.invalidJSONRPCMessage
    }
    guard object["method"] == nil,
      object["id"].flatMap(MCPJSONRPCID.init(jsonValue:)) == .integer(expectedResponseID)
    else {
      throw MCPStreamableHTTPError.mismatchedResponseID
    }
  }

  private static func sendServerRequestResponse(
    server: MCPServerConfiguration,
    requestID: MCPJSONRPCID,
    method: String,
    sessionID: String?,
    protocolVersion: String,
    timeout: TimeInterval,
    session: URLSession
  ) async throws {
    let response = JSONRPCClientResponse(
      id: requestID,
      result: method == "ping" ? [:] : nil,
      error: method == "ping"
        ? nil
        : JSONRPCClientResponse.ErrorPayload(
          code: -32601,
          message: "Method not supported by this client: \(method)"))
    var request = URLRequest(url: try normalizedBaseURL(for: server))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(protocolVersion, forHTTPHeaderField: protocolVersionHeader)
    applyHeaders(for: server, to: &request)
    if let sessionID, !sessionID.isEmpty {
      request.setValue(sessionID, forHTTPHeaderField: sessionIDHeader)
    }
    request.timeoutInterval = timeout
    request.httpBody = try JSONEncoder().encode(response)
    let (data, rawResponse) = try await session.data(for: request)
    guard let http = rawResponse as? HTTPURLResponse else { return }
    guard http.statusCode == 202 else {
      let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
      throw MCPHTTPError(
        statusCode: http.statusCode,
        body: snippet,
        hadSessionID: sessionID != nil,
        hadAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil)
    }
  }

  private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
    var data = Data()
    data.reserveCapacity(4096)
    for try await byte in bytes {
      guard data.count < 16 * 1_024 * 1_024 else {
        throw MCPStreamableHTTPError.responseTooLarge
      }
      data.append(byte)
    }
    return data
  }

  private static func contentType(from response: HTTPURLResponse) -> String? {
    response.value(forHTTPHeaderField: "Content-Type")?
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func normalizedHeader(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func looksLikeLegacySSEURL(_ value: String) -> Bool {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return false
    }
    return url.pathComponents.last?.lowercased() == "sse"
  }

  private static func endpointUsesLegacySSE(
    server: MCPServerConfiguration,
    session: URLSession
  ) async -> Bool {
    guard let url = try? normalizedBaseURL(for: server) else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    applyHeaders(for: server, to: &request)
    request.timeoutInterval = min(server.timeout, 3)
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        contentType(from: http) == "text/event-stream"
      else {
        return false
      }
      var parser = MCPServerSentEventParser()
      for try await line in bytes.lines {
        if let event = try parser.consume(line: line) {
          return event.isLegacyEndpointEvent
        }
      }
      return try parser.finish()?.isLegacyEndpointEvent == true
    } catch {
      return false
    }
  }

  private static func terminate(_ cached: MCPSession, using session: URLSession) async {
    guard let sessionID = cached.handshake.sessionID,
      !sessionID.isEmpty,
      let url = URL(string: cached.baseURL)
    else {
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(
      cached.handshake.protocolVersion ?? protocolVersion,
      forHTTPHeaderField: protocolVersionHeader)
    request.setValue(sessionID, forHTTPHeaderField: sessionIDHeader)
    if let authorizationHeader = cached.authorizationHeader {
      request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    }
    request.timeoutInterval = 3
    _ = try? await session.data(for: request)
  }

  // MARK: - MCP payloads

  private static func normalizedBaseURL(for server: MCPServerConfiguration) throws -> URL {
    guard let scheme = server.url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      server.url.host?.isEmpty == false
    else {
      throw MCPClientError.invalidURL(server.url.absoluteString)
    }
    return server.url
  }

  private static func authorizationHeader(for server: MCPServerConfiguration) -> String? {
    server.headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
  }

  private static func applyHeaders(for server: MCPServerConfiguration, to request: inout URLRequest)
  {
    for (name, value) in server.headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
  }

  private static func initializeParams(protocolVersion: String) -> [String: JSONValue] {
    [
      "protocolVersion": .string(protocolVersion),
      "capabilities": .object([:]),
      "clientInfo": .object([
        "name": .string("MaiCore"),
        "version": .string("0.1"),
      ]),
    ]
  }

  private static func responseError(from raw: [String: Any]) -> MCPResponseError? {
    guard let err = raw["error"] as? [String: Any] else { return nil }
    let message = (err["message"] as? String) ?? "unknown"
    return MCPResponseError(code: err["code"] as? Int, message: message)
  }

  private static func initializeMetadata(from data: Data) -> (
    protocolVersion: String?, serverName: String?
  ) {
    guard let raw = jsonObject(from: data),
      let result = raw["result"] as? [String: Any]
    else {
      return (nil, nil)
    }
    let protocolVersion = result["protocolVersion"] as? String
    let serverInfo = result["serverInfo"] as? [String: Any]
    let title = (serverInfo?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = (serverInfo?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (protocolVersion, title?.isEmpty == false ? title : name)
  }

  private static func isInvalidSessionID(_ error: Error) -> Bool {
    if let error = error as? MCPPartialOutputError {
      return isInvalidSessionID(error.underlying)
    }
    if let error = error as? MCPHTTPError {
      return error.isInvalidSessionID
    }
    if let error = error as? MCPResponseError {
      return error.isInvalidSessionID
    }
    return error.localizedDescription.localizedCaseInsensitiveContains("invalid session")
  }

  private static func isMethodNotFound(_ error: Error) -> Bool {
    if let error = error as? MCPResponseError {
      return error.isMethodNotFound
    }
    return error.localizedDescription.localizedCaseInsensitiveContains("method not found")
  }

  private static func jsonObject(from data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func sendResult(
    server: MCPServerConfiguration,
    method: String,
    params: [String: JSONValue]? = nil,
    session: URLSession
  ) async throws -> JSONValue {
    let data = try await send(
      server: server, method: method, params: params, session: session)
    guard !data.isEmpty else { return .null }
    let envelope: JSONValue
    do {
      envelope = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw MCPClientError.invalidResponse("MCP returned a non-JSON response.")
    }
    guard let object = envelope.objectValue else {
      throw MCPClientError.invalidResponse("MCP returned an invalid JSON-RPC envelope.")
    }
    if let error = object["error"]?.objectValue {
      throw MCPClientError.rpcError(
        code: error["code"]?.intValue,
        message: error["message"]?.stringValue ?? "Unknown MCP error.")
    }
    return object["result"] ?? .null
  }

  private static func mcpContent(_ value: JSONValue) throws -> ContentPart {
    guard let object = value.objectValue else { return .text(value.compactJSONString) }
    switch object["type"]?.stringValue {
    case "text":
      return .text(object["text"]?.stringValue ?? "")
    case "image":
      guard let raw = object["data"]?.stringValue, let data = Data(base64Encoded: raw) else {
        throw MCPClientError.invalidResponse("MCP image content has invalid base64 data.")
      }
      return .image(
        ImageContent(
          source: .data(data),
          mimeType: object["mimeType"]?.stringValue ?? "application/octet-stream"))
    case "audio":
      guard let raw = object["data"]?.stringValue, let data = Data(base64Encoded: raw) else {
        throw MCPClientError.invalidResponse("MCP audio content has invalid base64 data.")
      }
      return .audio(
        AudioContent(
          source: .data(data),
          mimeType: object["mimeType"]?.stringValue ?? "application/octet-stream"))
    case "resource", "resource_link":
      let resource = object["resource"]?.objectValue ?? object
      return .resource(
        ResourceContent(
          uri: resource["uri"]?.stringValue ?? "",
          name: resource["name"]?.stringValue,
          mimeType: resource["mimeType"]?.stringValue,
          text: resource["text"]?.stringValue,
          blob: resource["blob"]?.stringValue.flatMap { Data(base64Encoded: $0) }))
    default:
      return .text(value.compactJSONString)
    }
  }
}

// MARK: - Server-Sent Event framing

public struct MCPServerSentEvent: Equatable, Sendable {
  public var event: String?
  public var data: String
  public var id: String?
  public var retryMilliseconds: Int? = nil

  public init(event: String?, data: String, id: String?, retryMilliseconds: Int? = nil) {
    self.event = event
    self.data = data
    self.id = id
    self.retryMilliseconds = retryMilliseconds
  }

  public var isLegacyEndpointEvent: Bool {
    event?.trimmingCharacters(in: .whitespacesAndNewlines)
      .localizedCaseInsensitiveCompare("endpoint") == .orderedSame
  }

  fileprivate func jsonRPCMessage() throws -> MCPIncomingJSONRPCMessage? {
    let payload = data.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else { return nil }
    guard let payloadData = payload.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    else {
      throw MCPStreamableHTTPError.invalidEventData
    }
    guard object["jsonrpc"] as? String == "2.0" else {
      throw MCPStreamableHTTPError.invalidJSONRPCMessage
    }
    let id = object["id"].flatMap(MCPJSONRPCID.init(jsonValue:))
    return MCPIncomingJSONRPCMessage(
      object: object,
      id: id,
      method: object["method"] as? String)
  }
}

public struct MCPServerSentEventParser: Sendable {
  private static let maximumEventBytes = 16 * 1_024 * 1_024
  private var event: String?
  private var dataLines: [String] = []
  private var id: String?
  private var retryMilliseconds: Int?
  private var hasPendingRetry = false
  private var byteCount = 0

  public init() {}

  public mutating func consume(line: String) throws -> MCPServerSentEvent? {
    byteCount += line.utf8.count + 1
    guard byteCount <= Self.maximumEventBytes else {
      throw MCPStreamableHTTPError.responseTooLarge
    }
    guard !line.isEmpty else { return dispatch() }
    guard !line.hasPrefix(":") else { return nil }
    let field: Substring
    var value: Substring
    if let colon = line.firstIndex(of: ":") {
      field = line[..<colon]
      value = line[line.index(after: colon)...]
      if value.first == " " { value = value.dropFirst() }
    } else {
      field = Substring(line)
      value = ""
    }
    switch field {
    case "event": event = String(value)
    case "data": dataLines.append(String(value))
    case "id" where !value.contains("\0"): id = String(value)
    case "retry":
      if let retry = Int(value), retry >= 0 {
        retryMilliseconds = retry
        hasPendingRetry = true
      }
    default: break
    }
    return nil
  }

  public mutating func finish() throws -> MCPServerSentEvent? {
    dispatch()
  }

  private mutating func dispatch() -> MCPServerSentEvent? {
    defer {
      event = nil
      dataLines.removeAll(keepingCapacity: true)
      hasPendingRetry = false
      byteCount = 0
    }
    guard !dataLines.isEmpty || event != nil || hasPendingRetry else { return nil }
    return MCPServerSentEvent(
      event: event,
      data: dataLines.joined(separator: "\n"),
      id: id,
      retryMilliseconds: retryMilliseconds)
  }
}

private enum MCPEventStreamOutcome {
  case response(Data)
  case reconnect(eventID: String, retryMilliseconds: Int?)
}

private struct MCPIncomingJSONRPCMessage {
  var object: [String: Any]
  var id: MCPJSONRPCID?
  var method: String?
}

private enum MCPJSONRPCID: Codable, Equatable, Sendable {
  case integer(Int)
  case number(Double)
  case string(String)

  init?(jsonValue: Any) {
    if let string = jsonValue as? String {
      self = .string(string)
      return
    }
    guard let number = jsonValue as? NSNumber else { return nil }
    let value = number.doubleValue
    if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
      self = .integer(number.intValue)
    } else {
      self = .number(value)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let integer = try? container.decode(Int.self) {
      self = .integer(integer)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }
}

private struct JSONRPCClientResponse: Encodable {
  struct ErrorPayload: Encodable {
    var code: Int
    var message: String
  }

  var jsonrpc = "2.0"
  var id: MCPJSONRPCID
  var result: [String: JSONValue]?
  var error: ErrorPayload?
}

// MARK: - Session storage

private actor MCPSessionStore {
  private var sessions: [String: MCPSession] = [:]

  func session(
    for serverID: String,
    baseURL: String,
    authorizationHeader: String?
  ) -> MCPSession? {
    guard let session = sessions[serverID],
      session.baseURL == baseURL,
      session.authorizationHeader == authorizationHeader
    else {
      return nil
    }
    return session
  }

  func set(
    _ handshake: MCPHandshake,
    for serverID: String,
    baseURL: String,
    authorizationHeader: String?
  ) {
    sessions[serverID] = MCPSession(
      handshake: handshake,
      baseURL: baseURL,
      authorizationHeader: authorizationHeader)
  }

  @discardableResult
  func remove(_ serverID: String) -> MCPSession? {
    sessions.removeValue(forKey: serverID)
  }

  func removeAll() -> [MCPSession] {
    let removed = Array(sessions.values)
    sessions.removeAll()
    return removed
  }
}

// MARK: - Wire models and errors

private struct MCPSession: Sendable {
  var handshake: MCPHandshake
  var baseURL: String
  var authorizationHeader: String?
}

private struct MCPHandshake: Sendable {
  var sessionID: String?
  var protocolVersion: String?
  var serverName: String?
}

private struct MCPHTTPResponse {
  var data: Data
  var sessionID: String?
}

private struct MCPHTTPError: LocalizedError {
  var statusCode: Int
  var body: String
  var hadSessionID: Bool
  var hadAuthorization: Bool

  var isInvalidSessionID: Bool {
    statusCode == 404 && hadSessionID
      || body.localizedCaseInsensitiveContains("invalid session")
  }

  var isPossibleLegacySSEEndpoint: Bool {
    [400, 404, 405].contains(statusCode)
  }

  var isUnsupportedProtocolVersion: Bool {
    statusCode == 400
      && (body.localizedCaseInsensitiveContains("unsupported_mcp_protocol")
        || body.localizedCaseInsensitiveContains("unsupported protocol")
        || body.localizedCaseInsensitiveContains("protocol version"))
  }

  var errorDescription: String? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if statusCode == 401 {
      let detail = problemDetail ?? trimmed
      let guidance =
        hadAuthorization
        ? "The supplied credential was rejected."
        : "Select Bearer Token or OAuth in this MCP server's Authentication settings."
      return detail.isEmpty
        ? "MCP authorization required. \(guidance)"
        : "MCP authorization required: \(detail) \(guidance)"
    }
    return trimmed.isEmpty ? "MCP HTTP \(statusCode)." : "MCP HTTP \(statusCode): \(trimmed)"
  }

  private var problemDetail: String? {
    guard let data = body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return (object["detail"] as? String) ?? (object["title"] as? String)
  }
}

private struct MCPLegacySSETransportError: LocalizedError {
  var errorDescription: String? {
    "Legacy HTTP+SSE MCP endpoint detected. PocketMai supports Streamable HTTP only. Use the server's Streamable HTTP endpoint (usually /mcp), not its /sse endpoint."
  }
}

private enum MCPStreamableHTTPError: LocalizedError {
  case invalidEventData
  case invalidJSONRPCMessage
  case mismatchedResponseID
  case missingResponse
  case responseTooLarge
  case unexpectedEventStream
  case unsupportedContentType(String, String)

  var errorDescription: String? {
    switch self {
    case .invalidEventData:
      return "MCP Streamable HTTP returned an SSE event with invalid JSON data."
    case .invalidJSONRPCMessage:
      return "MCP Streamable HTTP returned an invalid JSON-RPC message."
    case .mismatchedResponseID:
      return "MCP Streamable HTTP returned a response for a different request."
    case .missingResponse:
      return "MCP Streamable HTTP closed without returning the requested JSON-RPC response."
    case .responseTooLarge:
      return "MCP Streamable HTTP response exceeded the 16 MB safety limit."
    case .unexpectedEventStream:
      return "MCP Streamable HTTP returned an SSE stream for a notification instead of HTTP 202."
    case .unsupportedContentType(let contentType, let body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = trimmed.isEmpty ? "" : " Response: \(trimmed)"
      return
        "MCP Streamable HTTP expected application/json or text/event-stream, but received \(contentType).\(suffix)"
    }
  }
}

private struct MCPResponseError: LocalizedError {
  var code: Int?
  var message: String

  var isInvalidSessionID: Bool {
    message.localizedCaseInsensitiveContains("invalid session")
  }

  var isMethodNotFound: Bool {
    code == -32601
  }

  var isUnsupportedProtocolVersion: Bool {
    message.localizedCaseInsensitiveContains("unsupported protocol")
      || message.localizedCaseInsensitiveContains("protocol version")
  }

  var errorDescription: String? {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let codeSuffix = code.map { " (code \($0))" } ?? ""
    return "MCP error\(codeSuffix): \(trimmed.isEmpty ? "unknown" : trimmed)"
  }
}

private struct JSONRPCRequest: Encodable {
  var jsonrpc = "2.0"
  var id: Int?
  var method: String
  var params: [String: JSONValue]?
}
