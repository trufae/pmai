import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public final class OpenAICompatibleProvider: ChatProvider, @unchecked Sendable {
  public struct Configuration: Sendable {
    public var id: ProviderID
    public var displayName: String
    public var baseURL: URL
    public var apiKey: String?
    public var additionalHeaders: [String: String]
    public var requestTimeout: TimeInterval

    public init(
      id: ProviderID = .openAI,
      displayName: String = "OpenAI-compatible",
      baseURL: URL,
      apiKey: String? = nil,
      additionalHeaders: [String: String] = [:],
      requestTimeout: TimeInterval = 600
    ) {
      self.id = id
      self.displayName = displayName
      self.baseURL = baseURL
      self.apiKey = apiKey
      self.additionalHeaders = additionalHeaders
      self.requestTimeout = requestTimeout
    }
  }

  public let descriptor: ProviderDescriptor
  private let configuration: Configuration
  private let session: URLSession
  /// What `{{session}}` becomes for a request made outside any chat: one
  /// session for the life of this provider, so such requests still present a
  /// stable session to a backend that requires one.
  private let standaloneSessionID = ChatSession.newID()

  public init(
    configuration: Configuration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
    descriptor = ProviderDescriptor(
      id: configuration.id,
      displayName: configuration.displayName,
      capabilities: [
        .streaming, .nativeToolCalling, .imageInput, .audioInput, .reasoning,
        .structuredOutput,
      ])
  }

  public func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw OpenAICompatibleProviderError.missingModel }

    let resolver = ToolNameResolver(definitions: request.tools)
    let urlRequest = try makeURLRequest(request, model: model, resolver: resolver)
    return request.stream
      ? try await stream(urlRequest, resolver: resolver, emit: emit)
      : try await completeOnce(urlRequest, resolver: resolver, emit: emit)
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    var values: [JSONValue] = []
    var afterID: String?
    var seenCursors = Set<String>()
    repeat {
      let root = try await catalog("models", afterID: afterID)
      guard let page = root["data"]?.arrayValue ?? root["models"]?.arrayValue else {
        throw OpenAICompatibleProviderError.invalidResponse(
          "Expected a model catalog in the provider response.")
      }
      values.append(contentsOf: page)
      guard root["has_more"]?.boolValue == true,
        let cursor = root["last_id"]?.stringValue,
        !cursor.isEmpty, seenCursors.insert(cursor).inserted
      else { break }
      afterID = cursor
    } while true
    return values.compactMap { value in
      guard let object = value.objectValue,
        let id = object["id"]?.stringValue ?? object["model"]?.stringValue
          ?? object["name"]?.stringValue,
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      var capabilities: ProviderCapabilities = []
      let architecture = object["architecture"]?.objectValue
      var declaredModalities =
        architecture?["input_modalities"]?.arrayValue?.compactMap(\.stringValue)
        ?? object["input_modalities"]?.arrayValue?.compactMap(\.stringValue)
      let modality = architecture?["modality"]?.stringValue?.lowercased() ?? ""
      if declaredModalities == nil, !modality.isEmpty {
        declaredModalities = modality.split(separator: "-").first.map {
          $0.split(separator: "+").map(String.init)
        }
      }
      let nativeImageInput = object["capabilities"]?.objectValue?["image_input"]?
        .objectValue?["supported"]?.boolValue
      if declaredModalities == nil, let nativeImageInput {
        declaredModalities = nativeImageInput ? ["text", "image"] : ["text"]
      }
      let inputModalities = declaredModalities ?? []
      if inputModalities.contains(where: { $0.lowercased() == "image" })
        || modality.split(separator: "-").first?.contains("image") == true
      {
        capabilities.insert(.imageInput)
      }
      if inputModalities.contains(where: { $0.lowercased() == "audio" })
        || modality.split(separator: "-").first?.contains("audio") == true
      {
        capabilities.insert(.audioInput)
      }
      return ModelDescriptor(
        id: id,
        displayName: object["display_name"]?.stringValue ?? object["name"]?.stringValue,
        ownedBy: object["owned_by"]?.stringValue ?? object["ownedBy"]?.stringValue,
        capabilities: capabilities,
        inputModalities: declaredModalities.map {
          Set($0.map { $0.lowercased() })
        })
    }.sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }

  /// Lists voices exposed by OpenAI-compatible `/voices` endpoints.
  public func availableVoices() async throws -> [String] {
    let root = try await catalog("voices")
    let voices = (root["data"]?.arrayValue ?? []).compactMap { value in
      value.stringValue
        ?? value.objectValue?["id"]?.stringValue
        ?? value.objectValue?["name"]?.stringValue
    }
    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    .sorted()
    guard !voices.isEmpty else {
      throw OpenAICompatibleProviderError.invalidResponse("The endpoint returned no voices.")
    }
    return voices
  }

  /// Synthesizes speech through an OpenAI-compatible `/audio/speech` endpoint.
  public func synthesizeSpeech(
    input: String,
    voice: String,
    responseFormat: String = "wav",
    model: String? = nil
  ) async throws -> Data {
    var body: [String: JSONValue] = [
      "input": .string(input),
      "voice": .string(voice),
      "response_format": .string(responseFormat),
    ]
    if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body["model"] = .string(model)
    }
    var request = URLRequest(url: try endpointURL("audio/speech"))
    request.httpMethod = "POST"
    request.timeoutInterval = max(1, configuration.requestTimeout)
    request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
    applyHeaders(to: &request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.speechAcceptHeader(responseFormat), forHTTPHeaderField: "Accept")

    let (data, response) = try await data(for: request)
    try validate(response: response, data: data)
    guard !data.isEmpty else { throw OpenAICompatibleProviderError.emptyResponse }
    return data
  }

  func makeURLRequest(_ request: ProviderRequest, model: String) throws -> URLRequest {
    try makeURLRequest(
      request,
      model: model,
      resolver: ToolNameResolver(definitions: request.tools))
  }

  private func makeURLRequest(
    _ request: ProviderRequest,
    model: String,
    resolver: ToolNameResolver
  ) throws -> URLRequest {
    let family = ReasoningEffort.APIFamily.detect(
      model: model,
      provider: "\(descriptor.id.rawValue) \(descriptor.displayName)",
      baseURL: configuration.baseURL.absoluteString)
    var body = request.options.additional
    body["model"] = .string(model)
    let includesReasoningHistory = family != .deepSeek || !request.tools.isEmpty
    body["messages"] = .array(
      try ReasoningEffort.messages(request.messages, options: request.options, model: model)
        .flatMap {
          try openAIMessages(
            $0, resolver: resolver, family: family,
            includesReasoningHistory: includesReasoningHistory)
        })
    body["stream"] = .bool(request.stream)
    if request.stream && request.options.includeStreamUsage {
      body["stream_options"] = .object(["include_usage": .bool(true)])
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(request.tools.map { openAITool($0, resolver: resolver) })
      body["tool_choice"] = openAIToolChoice(request.toolChoice, resolver: resolver)
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    if let maxOutputTokens = request.options.maxOutputTokens {
      body["max_tokens"] = .integer(maxOutputTokens)
    }
    let reasoningEffort = request.options.reasoningEffort?.trimmingCharacters(
      in: .whitespacesAndNewlines) ?? ""
    if reasoningEffort.isEmpty,
      request.options.additional["thinking"] == nil,
      request.options.additional["reasoning_effort"] == nil
    {
      for (key, value) in ReasoningEffort.automatic.requestFields(family: family, model: model)
      where request.options.additional[key] == nil {
        body[key] = value
      }
    } else {
      // One of our levels becomes whatever this endpoint's API family takes;
      // anything else is a value meant for the endpoint and goes as it is.
      // Fields set through `additional` are the person's own and stay.
      if let effort = ReasoningEffort(name: reasoningEffort) {
        let fields = effort.requestFields(family: family, model: model)
        for (key, value) in fields where request.options.additional[key] == nil {
          body[key] = value
        }
      } else if request.options.additional["reasoning_effort"] == nil {
        body["reasoning_effort"] = .string(reasoningEffort)
      }
    }
    if let responseFormat = openAIResponseFormat(request.responseFormat) {
      body["response_format"] = responseFormat
    }

    var urlRequest = URLRequest(url: try endpointURL("chat/completions"))
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = max(1, configuration.requestTimeout)
    urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))
    applyHeaders(to: &urlRequest, sessionID: request.sessionID)
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return urlRequest
  }

  private func applyHeaders(to request: inout URLRequest, sessionID: String? = nil) {
    let headers = ProviderHeaders.expand(
      configuration.additionalHeaders, sessionID: sessionID ?? standaloneSessionID)
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
  }

  private func endpointURL(_ endpoint: String) throws -> URL {
    guard
      var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      components.host?.isEmpty == false
    else {
      throw OpenAICompatibleProviderError.invalidBaseURL(configuration.baseURL.absoluteString)
    }

    var path = components.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    for suffix in ["/chat/completions", "/audio/speech", "/models", "/voices"]
    where path.hasSuffix(suffix) {
      path.removeLast(suffix.count)
      break
    }
    if path == "/" { path = "" }
    path += "/\(endpoint)"
    components.path = path.hasPrefix("/") ? path : "/\(path)"
    components.query = nil
    components.fragment = nil
    guard let url = components.url else {
      throw OpenAICompatibleProviderError.invalidBaseURL(configuration.baseURL.absoluteString)
    }
    return url
  }

  private func completeOnce(
    _ request: URLRequest,
    resolver: ToolNameResolver,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let (data, response) = try await data(for: request)
    try validate(response: response, data: data)
    return try await decodedResponse(data, resolver: resolver, emit: emit)
  }

  private func decodedResponse(
    _ data: Data,
    resolver: ToolNameResolver,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let root = try decodeRoot(data)
    if let message = providerError(in: root) {
      throw OpenAICompatibleProviderError.providerFailure(message)
    }
    guard let choice = root["choices"]?.arrayValue?.first?.objectValue else {
      throw OpenAICompatibleProviderError.emptyResponse
    }
    let payload = choice["message"]?.objectValue ?? choice
    let message = try agentMessage(from: payload, resolver: resolver)
    guard
      !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !message.toolCalls.isEmpty
    else {
      throw OpenAICompatibleEmptyReply()
    }

    await emitParts(message.content, emit: emit)
    for (index, call) in message.toolCalls.enumerated() {
      await emit(
        .toolCallDelta(
          ToolCallDelta(
            index: index,
            id: call.id,
            name: call.name,
            argumentsFragment: call.arguments.compactJSONString)))
    }
    let usage = try tokenUsage(root["usage"])
    if let usage { await emit(.usage(usage)) }
    return ProviderResponse(
      message: message,
      usage: usage,
      stopReason: ProviderStopReason(choice["finish_reason"]?.stringValue))
  }

  private func stream(
    _ request: URLRequest,
    resolver: ToolNameResolver,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let delegate = ProviderRedirectDelegate(originalRequest: request)
    let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
    #if !canImport(FoundationNetworking)
      let urlTask = bytes.task
    #endif
    return try await withTaskCancellationHandler {
      try await decodedStream(bytes, response: response, resolver: resolver, emit: emit)
    } onCancel: {
      #if !canImport(FoundationNetworking)
        urlTask.cancel()
      #endif
    }
  }

  private func decodedStream(
    _ bytes: URLSession.AsyncBytes,
    response: URLResponse,
    resolver: ToolNameResolver,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    guard let http = response as? HTTPURLResponse else {
      throw OpenAICompatibleProviderError.invalidResponse(
        "The provider returned a non-HTTP response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      var body = Data()
      for try await byte in bytes {
        guard body.count < 64 * 1_024 else { break }
        body.append(byte)
      }
      throw httpError(statusCode: http.statusCode, data: body)
    }

    var hasContent = false
    var reasoningStream = ReasoningStream()
    var usage: TokenUsage?
    var stopReason = ProviderStopReason.unknown
    var toolCalls: [Int: ToolCallAccumulator] = [:]
    var reasoningDetailsSnapshot = ""
    var rawLines: [String] = []
    var rawCharacterCount = 0

    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else {
        appendRawLine(line, to: &rawLines, characterCount: &rawCharacterCount)
        continue
      }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
      if payload == "[DONE]" { break }
      guard let data = payload.data(using: .utf8) else { continue }
      guard let root = try? decodeRoot(data) else {
        appendRawLine(String(payload), to: &rawLines, characterCount: &rawCharacterCount)
        continue
      }
      if let message = providerError(in: root) {
        throw OpenAICompatibleProviderError.providerFailure(message)
      }
      // Some servers attach usage to every chunk, zero or cumulative until
      // the last one. Only the final figures count, announced once below.
      if let value = try tokenUsage(root["usage"]) { usage = value }
      guard let choice = root["choices"]?.arrayValue?.first?.objectValue else { continue }
      let delta = choice["delta"]?.objectValue ?? choice["message"]?.objectValue ?? [:]
      var reasoningDelta = decodedReasoning(delta)
      if configuration.baseURL.host?.contains("minimax") == true,
        delta["reasoning_details"] != nil,
        delta["reasoning_content"]?.stringValue?.isEmpty != false,
        delta["reasoning"]?.stringValue?.isEmpty != false
      {
        let snapshot = reasoningDelta
        if snapshot.hasPrefix(reasoningDetailsSnapshot) {
          reasoningDelta = String(snapshot.dropFirst(reasoningDetailsSnapshot.count))
        }
        reasoningDetailsSnapshot = snapshot
      }
      if !reasoningDelta.isEmpty {
        await emitParts(reasoningStream.appendReasoning(reasoningDelta), emit: emit)
      }
      let textDelta = decodedText(delta["content"])
      if !textDelta.isEmpty {
        hasContent = hasContent || !textDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        await emitParts(reasoningStream.append(textDelta), emit: emit)
      }
      if delta["tool_calls"]?.arrayValue?.isEmpty == false {
        await emitParts(reasoningStream.flush(), emit: emit)
      }
      for rawCall in delta["tool_calls"]?.arrayValue ?? [] {
        guard let object = rawCall.objectValue else { continue }
        let index = object["index"]?.intValue ?? toolCalls.count
        var accumulator = toolCalls[index] ?? ToolCallAccumulator()
        let function = object["function"]?.objectValue ?? [:]
        let id = object["id"]?.stringValue
        let name = function["name"]?.stringValue
        let arguments = function["arguments"]?.stringValue ?? ""
        if let id, !id.isEmpty { accumulator.id = id }
        if let name, !name.isEmpty { accumulator.name = name }
        // OpenAI streams arguments as concatenated JSON fragments; some
        // OpenAI-compatible endpoints (notably MiniMax-M3) re-send the full
        // tool-call JSON in every chunk. Concatenating those yields an invalid
        // string, so merge by preferring whichever form is a parseable prefix.
        accumulator.arguments =
          ToolCallAccumulator.merge(accumulator.arguments, with: arguments)
        toolCalls[index] = accumulator
        let deltaName = name.flatMap(resolver.canonicalName) ?? name ?? ""
        await emit(
          .toolCallDelta(
            ToolCallDelta(
              index: index,
              id: id,
              name: deltaName.isEmpty ? nil : deltaName,
              argumentsFragment: arguments)))
      }
      if let value = choice["finish_reason"]?.stringValue {
        stopReason = ProviderStopReason(value)
      }
    }

    await emitParts(reasoningStream.flush(), emit: emit)
    let completedCalls = try toolCalls.keys.sorted().compactMap { index -> ToolCall? in
      guard let accumulator = toolCalls[index] else { return nil }
      return try accumulator.toolCall(index: index, resolver: resolver)
    }
    if !hasContent,
      completedCalls.isEmpty,
      !rawLines.isEmpty,
      let data = rawLines.joined(separator: "\n").data(using: .utf8),
      let fallback = try? await decodedResponse(data, resolver: resolver, emit: emit)
    {
      return fallback
    }
    guard hasContent || !completedCalls.isEmpty
    else {
      throw OpenAICompatibleEmptyReply()
    }
    var parts = reasoningStream.parts
    parts.append(contentsOf: completedCalls.map(ContentPart.toolCall))
    if let usage { await emit(.usage(usage)) }
    return ProviderResponse(
      message: AgentMessage(role: .assistant, content: parts),
      usage: usage,
      stopReason: completedCalls.isEmpty ? stopReason : .toolCall)
  }

  private func emitParts(_ parts: [ContentPart], emit: ProviderEventHandler) async {
    for part in parts {
      switch part {
      case .text(let text): await emit(.textDelta(text))
      case .reasoning(let text): await emit(.reasoningDelta(text))
      default: break
      }
    }
  }

  private func appendRawLine(
    _ line: String,
    to lines: inout [String],
    characterCount: inout Int
  ) {
    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      characterCount < 32_000
    else { return }
    characterCount += line.count + (lines.isEmpty ? 0 : 1)
    lines.append(line)
  }

  private func openAIMessages(
    _ message: AgentMessage,
    resolver: ToolNameResolver,
    family: ReasoningEffort.APIFamily,
    includesReasoningHistory: Bool
  ) throws -> [JSONValue] {
    if message.role == .tool || !message.toolResults.isEmpty {
      return try message.toolResults.map { result in
        var content = result.content
        // Structured content is for programs; the model reads the text. It is
        // sent only when there is no text to carry the result, so a listing or
        // a file is not paid for twice on every later request.
        let hasText = content.contains { part in
          switch part {
          case .text(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          case .file(let file):
            return file.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
          case .resource(let resource):
            return resource.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
          default:
            return false
          }
        }
        if !hasText, let structured = result.structuredContent {
          content.append(
            .text("<structured_content>\n\(structured.compactJSONString)\n</structured_content>"))
        }
        return .object([
          "role": .string("tool"),
          "tool_call_id": .string(result.callID),
          "content": try openAIContent(content),
        ])
      }
    }

    var object: [String: JSONValue] = ["role": .string(message.role.rawValue)]
    let visibleParts = message.content.filter { part in
      switch part {
      case .reasoning, .toolCall, .toolResult: false
      default: true
      }
    }
    object["content"] = visibleParts.isEmpty ? .null : try openAIContent(visibleParts)
    if includesReasoningHistory, !message.reasoning.isEmpty {
      if family == .minimax {
        object["content"] = .string(ReasoningText.render(message.content))
      } else {
        object["reasoning_content"] = .string(message.reasoning)
      }
    }
    if !message.toolCalls.isEmpty {
      object["tool_calls"] = .array(
        message.toolCalls.map { call in
          .object([
            "id": .string(call.id),
            "type": .string("function"),
            "function": .object([
              "name": .string(resolver.providerName(for: call.name)),
              "arguments": .string(call.arguments.compactJSONString),
            ]),
          ])
        })
    }
    return [.object(object)]
  }

  private func openAIContent(_ parts: [ContentPart]) throws -> JSONValue {
    if parts.count == 1, case .text(let text) = parts[0] { return .string(text) }
    var values: [JSONValue] = []
    for part in parts {
      switch part {
      case .text(let text):
        values.append(.object(["type": .string("text"), "text": .string(text)]))
      case .reasoning, .toolCall, .toolResult:
        continue
      case .image(let image):
        values.append(
          .object([
            "type": .string("image_url"),
            "image_url": .object([
              "url": .string(try encodedURL(image.source, mimeType: image.mimeType)),
              "detail": .string(image.detail.rawValue),
            ]),
          ]))
      case .audio(let audio):
        guard case .data(let data) = audio.source else {
          throw OpenAICompatibleProviderError.unsupportedContent(
            "OpenAI-compatible audio input requires inline data.")
        }
        let format = audio.mimeType.split(separator: "/").last.map(String.init) ?? "wav"
        values.append(
          .object([
            "type": .string("input_audio"),
            "input_audio": .object([
              "data": .string(data.base64EncodedString()),
              "format": .string(format),
            ]),
          ]))
      case .file(let file):
        if let text = file.text {
          values.append(
            .object([
              "type": .string("text"),
              "text": .string("<file name=\"\(file.name)\">\n\(text)\n</file>"),
            ]))
        } else {
          throw OpenAICompatibleProviderError.unsupportedContent(
            "Binary file '\(file.name)' is not supported by Chat Completions.")
        }
      case .resource(let resource):
        if let text = resource.text {
          values.append(
            .object([
              "type": .string("text"),
              "text": .string("<resource uri=\"\(resource.uri)\">\n\(text)\n</resource>"),
            ]))
        } else {
          throw OpenAICompatibleProviderError.unsupportedContent(
            "Binary resource '\(resource.uri)' is not supported by Chat Completions.")
        }
      }
    }
    return .array(values)
  }

  private func encodedURL(_ source: BinarySource, mimeType: String) throws -> String {
    switch source {
    case .url(let url): return url.absoluteString
    case .data(let data): return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
  }

  private func openAITool(_ definition: ToolDefinition, resolver: ToolNameResolver) -> JSONValue {
    .object([
      "type": .string("function"),
      "function": .object([
        "name": .string(resolver.providerName(for: definition.name)),
        "description": .string(definition.description),
        "parameters": definition.inputSchema,
      ]),
    ])
  }

  private func openAIToolChoice(_ choice: ToolChoice, resolver: ToolNameResolver) -> JSONValue {
    switch choice {
    case .automatic: .string("auto")
    case .none: .string("none")
    case .required: .string("required")
    case .tool(let name):
      .object([
        "type": .string("function"),
        "function": .object(["name": .string(resolver.providerName(for: name))]),
      ])
    }
  }

  private func openAIResponseFormat(_ format: ResponseFormat) -> JSONValue? {
    switch format {
    case .text: nil
    case .jsonObject: .object(["type": .string("json_object")])
    case .jsonSchema(let name, let schema, let strict):
      .object([
        "type": .string("json_schema"),
        "json_schema": .object([
          "name": .string(name),
          "schema": schema,
          "strict": .bool(strict),
        ]),
      ])
    }
  }

  private func agentMessage(
    from payload: [String: JSONValue],
    resolver: ToolNameResolver
  ) throws -> AgentMessage {
    let text = decodedText(payload["content"] ?? payload["text"])
    let reasoning = decodedReasoning(payload)
    var stream = ReasoningStream()
    _ = stream.appendReasoning(reasoning)
    _ = stream.append(text)
    _ = stream.flush()
    var parts = stream.parts
    for (index, raw) in (payload["tool_calls"]?.arrayValue ?? []).enumerated() {
      guard let object = raw.objectValue else { continue }
      let function = object["function"]?.objectValue ?? [:]
      let providerName = function["name"]?.stringValue ?? ""
      let rawArguments = function["arguments"]?.stringValue ?? "{}"
      let arguments = try decodeToolArguments(rawArguments, tool: providerName)
      let canonicalName = resolver.canonicalName(for: providerName) ?? providerName
      guard !canonicalName.isEmpty else {
        throw OpenAICompatibleProviderError.invalidResponse(
          "Provider returned a tool call with an empty name. Arguments: \(rawArguments)")
      }
      let call = ToolCall(
        id: object["id"]?.stringValue ?? "call_\(index)",
        name: canonicalName,
        arguments: arguments)
      parts.append(.toolCall(call))
    }
    return AgentMessage(role: .assistant, content: parts)
  }

  private func decodedReasoning(_ payload: [String: JSONValue]) -> String {
    for key in ["reasoning_content", "reasoning", "thinking"] {
      if let value = payload[key]?.stringValue, !value.isEmpty { return value }
    }
    return (payload["reasoning_details"]?.arrayValue ?? []).compactMap {
      $0.objectValue?["text"]?.stringValue ?? $0.objectValue?["summary"]?.stringValue
    }.joined()
  }

  private func decodedText(_ value: JSONValue?) -> String {
    if let string = value?.stringValue { return string }
    return (value?.arrayValue ?? []).compactMap { part -> String? in
      guard let object = part.objectValue else { return nil }
      return object["text"]?.stringValue
        ?? object["content"]?.stringValue
        ?? object["value"]?.stringValue
    }.joined()
  }

  private func decodeRoot(_ data: Data) throws -> [String: JSONValue] {
    do {
      let root = try JSONDecoder().decode(JSONValue.self, from: data)
      guard let object = root.objectValue else {
        throw OpenAICompatibleProviderError.invalidResponse("Expected a JSON object.")
      }
      return object
    } catch let error as OpenAICompatibleProviderError {
      throw error
    } catch {
      throw OpenAICompatibleProviderError.invalidResponse(
        "The response was not a supported chat-completions payload.")
    }
  }

  private func decodeToolArguments(_ raw: String, tool: String) throws -> JSONValue {
    guard let data = raw.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      value.objectValue != nil
    else {
      throw OpenAICompatibleProviderError.invalidToolArguments(tool: tool, arguments: raw)
    }
    return value
  }

  private func providerError(in root: [String: JSONValue]) -> String? {
    root["error"]?.objectValue?["message"]?.stringValue
  }

  private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let delegate = ProviderRedirectDelegate(originalRequest: request)
    return try await session.data(for: request, delegate: delegate)
  }

  private func catalog(_ endpoint: String, afterID: String? = nil) async throws -> [String: JSONValue] {
    var url = try endpointURL(endpoint)
    if let afterID {
      guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw OpenAICompatibleProviderError.invalidBaseURL(url.absoluteString)
      }
      components.queryItems = [URLQueryItem(name: "after_id", value: afterID)]
      guard let pageURL = components.url else {
        throw OpenAICompatibleProviderError.invalidBaseURL(url.absoluteString)
      }
      url = pageURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = min(15, max(1, configuration.requestTimeout))
    applyHeaders(to: &request)
    if endpoint == "models", url.host?.lowercased() == "api.anthropic.com",
      request.value(forHTTPHeaderField: "anthropic-version") == nil
    {
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      // Catalogs need a total deadline, independent of inference and HTTP idle timeouts.
      let (data, response) = try await withThrowingTaskGroup(
        of: (Data, URLResponse).self
      ) { group in
        group.addTask { [request] in try await self.data(for: request) }
        group.addTask { [request] in
          try await Task.sleep(for: .seconds(request.timeoutInterval))
          throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
      }
      try validate(response: response, data: data)
      let root = try decodeRoot(data)
      if let message = providerError(in: root) {
        throw OpenAICompatibleProviderError.providerFailure(message)
      }
      return root
    } catch let error as URLError where error.code == .timedOut {
      throw OpenAICompatibleProviderError.providerFailure(
        "Fetching /\(endpoint) timed out after \(Int(request.timeoutInterval))s. "
          + "Check that the server is ready and the provider base URL is correct.")
    }
  }

  private static func speechAcceptHeader(_ responseFormat: String) -> String {
    switch responseFormat.lowercased() {
    case "aac": "audio/aac"
    case "mp3": "audio/mpeg"
    case "wav": "audio/wav"
    case "opus", "ogg": "audio/ogg"
    case "flac": "audio/flac"
    default: "*/*"
    }
  }

  private func tokenUsage(_ value: JSONValue?) throws -> TokenUsage? {
    guard let usage = value?.objectValue else { return nil }
    func count(_ value: JSONValue?) throws -> Int? {
      guard let value, value != .null else { return nil }
      guard let count = value.intValue, count >= 0 else {
        throw OpenAICompatibleProviderError.invalidResponse(
          "Token usage must contain nonnegative integers within the supported range.")
      }
      return count
    }
    let input = try count(usage["prompt_tokens"] ?? usage["input_tokens"]) ?? 0
    let output = try count(usage["completion_tokens"] ?? usage["output_tokens"]) ?? 0
    guard !input.addingReportingOverflow(output).overflow else {
      throw OpenAICompatibleProviderError.invalidResponse("Token usage total exceeds the supported range.")
    }
    let promptDetails = usage["prompt_tokens_details"]?.objectValue
    let completionDetails = usage["completion_tokens_details"]?.objectValue
    return try TokenUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: count(usage["total_tokens"]),
      cachedTokens: count(promptDetails?["cached_tokens"]),
      reasoningTokens: count(completionDetails?["reasoning_tokens"]))
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw OpenAICompatibleProviderError.invalidResponse(
        "The provider returned a non-HTTP response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw httpError(statusCode: http.statusCode, data: data)
    }
  }

  private func httpError(statusCode: Int, data: Data) -> OpenAICompatibleProviderError {
    if let root = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
      let message = providerError(in: root)
    {
      return .httpError(statusCode: statusCode, message: message)
    }
    let body =
      String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return .httpError(
      statusCode: statusCode,
      message: body.isEmpty ? "Request failed." : String(body.prefix(1_000)))
  }
}

public enum OpenAICompatibleProviderError: LocalizedError, Equatable, Sendable {
  case invalidBaseURL(String)
  case missingModel
  case emptyResponse
  case invalidResponse(String)
  case providerFailure(String)
  case invalidToolArguments(tool: String, arguments: String)
  case unsupportedContent(String)
  case httpError(statusCode: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      "Invalid OpenAI-compatible base URL: \(value)"
    case .missingModel:
      "Select a model for this endpoint before sending a message."
    case .emptyResponse:
      "The provider returned an empty response."
    case .invalidResponse(let message), .providerFailure(let message),
      .unsupportedContent(let message):
      message
    case .invalidToolArguments(let tool, let arguments):
      "Provider returned invalid JSON arguments for '\(tool)': \(arguments)"
    case .httpError(let statusCode, let message):
      "Provider returned HTTP \(statusCode): \(message)"
    }
  }
}

private struct ToolCallAccumulator {
  var id = ""
  var name = ""
  var arguments = ""

  /// Merges a freshly arrived `arguments` string into whatever the accumulator
  /// already has. OpenAI streams `arguments` as JSON fragments that form a
  /// valid object only when concatenated (`{"text":` then `"hi"}` then `}`).
  /// Some OpenAI-compatible endpoints — notably MiniMax-M3 — instead re-send
  /// the full tool-call JSON in every chunk; concatenating those produces an
  /// invalid string, so prefer whichever form parses as a JSON object.
  ///
  /// The rules, in priority order:
  /// 1. If the concatenation already parses, keep it (OpenAI is mid-stream).
  /// 2. If only the new fragment parses, replace the buffer with it (full
  ///    re-send, possibly the first chunk that completes the object).
  /// 3. If the buffer alone already parses, ignore the new fragment (later
  ///    re-sends of the same complete object).
  /// 4. Otherwise fall back to concatenation (mid-stream, not yet valid).
  static func merge(_ existing: String, with fragment: String) -> String {
    if fragment.isEmpty { return existing }
    if existing.isEmpty { return fragment }
    let combined = existing + fragment
    if Self.isJSONObject(combined) { return combined }
    if Self.isJSONObject(fragment) { return fragment }
    if Self.isJSONObject(existing) { return existing }
    return combined
  }

  private static func isJSONObject(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return false }
    return decoded.objectValue != nil
  }

  func toolCall(index: Int, resolver: ToolNameResolver) throws -> ToolCall {
    let raw = arguments.isEmpty ? "{}" : arguments
    guard let data = raw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
      decoded.objectValue != nil
    else {
      throw OpenAICompatibleProviderError.invalidToolArguments(tool: name, arguments: raw)
    }
    let canonicalName = resolver.canonicalName(for: name) ?? name
    guard !canonicalName.isEmpty else {
      throw OpenAICompatibleProviderError.invalidResponse(
        "Provider streamed a tool call with an empty name. Arguments: \(raw)")
    }
    return ToolCall(
      id: id.isEmpty ? "call_\(index)" : id,
      name: canonicalName,
      arguments: decoded)
  }
}

extension ProviderStopReason {
  fileprivate init(_ rawValue: String?) {
    switch rawValue {
    case "stop": self = .stop
    case "length", "max_tokens": self = .length
    case "tool_calls", "function_call": self = .toolCall
    case "content_filter": self = .contentFilter
    case "cancelled": self = .cancelled
    default: self = .unknown
    }
  }
}

/// Only a reply with nothing in it is a repairable turn; an empty HTTP body is
/// still a transport failure.
public struct OpenAICompatibleEmptyReply: ProviderEmptyResponseError, LocalizedError {
  public var errorDescription: String? { "The provider returned an empty response." }
}
