import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension JSONValue {
  subscript(_ key: String) -> JSONValue? { objectValue?[key] }
}

/// Subscription-authorized Responses. Chat Completions and API-key billing are separate providers.
public final class ChatGPTProvider: ChatProvider, @unchecked Sendable {
  public let descriptor: ProviderDescriptor
  private let store: ChatGPTCredentialStore
  private let auth: ChatGPTAuth
  private let session: URLSession
  private let timeout: TimeInterval
  static let baseURL = URL(string: "https://api.openai.com/v1")!

  public init(
    id: ProviderID, displayName: String = "ChatGPT subscription",
    store: ChatGPTCredentialStore, auth: ChatGPTAuth = .shared,
    session: URLSession = .shared, timeout: TimeInterval = 600
  ) {
    self.store = store
    self.auth = auth
    self.session = session
    self.timeout = timeout
    descriptor = .init(
      id: id, displayName: displayName,
      capabilities: [.streaming, .nativeToolCalling, .imageInput, .reasoning, .structuredOutput])
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    let request = try await authorizedRequest(path: "models")
    let (data, response) = try await session.data(
      for: request, delegate: ProviderRedirectDelegate(originalRequest: request))
    try Self.validate(response, data: data)
    guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
      let models = root["models"]?.arrayValue
    else {
      throw ChatGPTError.message("ChatGPT returned an invalid model catalog.")
    }
    return models.compactMap { value in
      guard value["visibility"]?.stringValue == "list", let id = value["slug"]?.stringValue,
        !id.isEmpty
      else { return nil }
      let modalities = value["input_modalities"]?.arrayValue?.compactMap(\.stringValue)
      return ModelDescriptor(
        id: id, displayName: value["display_name"]?.stringValue,
        ownedBy: "OpenAI", capabilities: modalities?.contains("image") == true ? [.imageInput] : [],
        inputModalities: modalities.map(Set.init))
    }
  }

  public func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler)
    async throws -> ProviderResponse
  {
    guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OpenAICompatibleProviderError.missingModel
    }
    let resolver = ToolNameResolver(tools: request.tools)
    let streamEmit: ProviderEventHandler = { event in
      if request.stream { await emit(event) } else if case .usage = event { await emit(event) }
    }
    var http = try await authorizedRequest(path: "responses")
    http.httpMethod = "POST"
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    http.httpBody = try JSONEncoder().encode(
      Self.body(
        request, resolver: resolver,
        reasoning: ChatGPTReasoningCache.shared.items(
          account: store.identity, messages: request.messages)))
    let (bytes, response) = try await session.bytes(
      for: http, delegate: ProviderRedirectDelegate(originalRequest: http))
    #if !canImport(FoundationNetworking)
      let task = bytes.task
      defer { task.cancel() }
    #endif
    return try await withTaskCancellationHandler {
      let httpResponse = response as? HTTPURLResponse
      // Read the actual header: Foundation may infer text/plain when it is absent.
      let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")?
        .components(separatedBy: ";").first?
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard let status = httpResponse?.statusCode, (200..<300).contains(status),
        contentType == nil || contentType == "" || contentType == "text/event-stream"
      else {
        var data = Data()
        for try await byte in bytes {
          if data.count >= 65_536 { break }
          data.append(byte)
        }
        try Self.validate(response, data: data)
        let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        throw Self.failure(
          root?["error"] ?? root, status: httpResponse?.statusCode,
          requestID: httpResponse?.value(forHTTPHeaderField: "x-request-id"),
          fallback:
            "ChatGPT returned \(contentType ?? "no content type"); expected text/event-stream.")
      }
      var parser = ChatGPTResponseStream(
        resolver: resolver, requestID: httpResponse?.value(forHTTPHeaderField: "x-request-id"))
      var events = ChatGPTEventStream()
      // Some subscription responses omit Content-Type. Validate their events
      // normally, retaining a bounded prefix to diagnose headerless JSON errors.
      var diagnosticPrefix: Data? = contentType == "text/event-stream" ? nil : Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        if let count = diagnosticPrefix?.count, count < 65_536 { diagnosticPrefix?.append(byte) }
        if let payload = try events.consume(byte) {
          diagnosticPrefix = nil
          if let result = try await parser.feed(payload, emit: streamEmit) {
            ChatGPTReasoningCache.shared.remember(account: store.identity, message: result.message)
            return result
          }
        }
      }
      if let payload = try events.finish() {
        diagnosticPrefix = nil
        if let result = try await parser.feed(payload, emit: streamEmit) {
          ChatGPTReasoningCache.shared.remember(account: store.identity, message: result.message)
          return result
        }
      }
      if let data = diagnosticPrefix {
        let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        throw Self.failure(
          root?["error"] ?? root, status: httpResponse?.statusCode,
          requestID: httpResponse?.value(forHTTPHeaderField: "x-request-id"),
          fallback: "ChatGPT returned no response events and no content type. Try again.")
      }
      throw Self.failure(
        nil, requestID: httpResponse?.value(forHTTPHeaderField: "x-request-id"),
        fallback: "ChatGPT stream ended before response.completed. Try again.")
    } onCancel: {
      #if !canImport(FoundationNetworking)
        task.cancel()
      #endif
    }
  }

  private func authorizedRequest(path: String) async throws -> URLRequest {
    let token = try await auth.accessToken(store: store)
    var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
    request.timeoutInterval = timeout
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("pmai", forHTTPHeaderField: "originator")
    return request
  }

  static func body(
    _ request: ProviderRequest, resolver: ToolNameResolver,
    reasoning: [String: [JSONValue]] = [:]
  ) throws -> JSONValue {
    var input: [JSONValue] = []
    for message in ReasoningEffort.messages(
      request.messages, options: request.options, model: request.model)
    {
      if message.role == .assistant {
        input.append(
          contentsOf: message.providerState?["chatgpt.reasoning"]?.arrayValue
            ?? message.toolCalls.first.flatMap { reasoning[$0.id] } ?? [])
      }
      var content: [JSONValue] = []
      let textType = message.role == .assistant ? "output_text" : "input_text"
      func flush() {
        guard !content.isEmpty else { return }
        input.append(
          .object([
            "role": .string(message.role == .system ? "developer" : message.role.rawValue),
            "type": .string("message"), "content": .array(content),
          ]))
        content.removeAll()
      }
      for part in message.content {
        switch part {
        case .text(let text):
          if text.isEmpty { continue }
          content.append(
            .object([
              "type": .string(textType),
              "text": .string(text),
            ]))
        case .image(let image):
          content.append(
            .object([
              "type": .string("input_image"),
              "image_url": .string(encoded(image.source, mimeType: image.mimeType)),
            ]))
        case .file(let file):
          if let text = file.text {
            content.append(.object(["type": .string(textType), "text": .string(text)]))
          } else if let source = file.source {
            var item: [String: JSONValue] = ["type": .string("input_file")]
            switch source {
            case .data:
              item["file_data"] = .string(encoded(source, mimeType: file.mimeType))
              item["filename"] = .string(file.name)
            case .url(let url): item["file_url"] = .string(url.absoluteString)
            }
            content.append(.object(item))
          }
        case .resource(let resource):
          if let text = resource.text {
            content.append(.object(["type": .string(textType), "text": .string(text)]))
          }
        case .toolCall(let call):
          flush()
          input.append(
            .object([
              "type": .string("function_call"), "call_id": .string(call.id),
              "name": .string(resolver.apiName(for: call.name)), "namespace": .string("pmai"),
              "arguments": .string(call.arguments.compactJSONString),
            ]))
        case .toolResult(let result):
          flush()
          var output: [JSONValue] = []
          for part in result.content {
            if case .image(let image) = part {
              output.append(
                .object([
                  "type": .string("input_image"),
                  "image_url": .string(encoded(image.source, mimeType: image.mimeType)),
                ]))
            } else if let text = part.textValue {
              output.append(.object(["type": .string("input_text"), "text": .string(text)]))
            }
          }
          if output.isEmpty, let structured = result.structuredContent {
            output.append(
              .object([
                "type": .string("input_text"), "text": .string(structured.compactJSONString),
              ]))
          }
          input.append(
            .object([
              "type": .string("function_call_output"), "call_id": .string(result.callID),
              "output": output.isEmpty ? .string("") : .array(output),
            ]))
        case .audio:
          throw ChatGPTError.message(
            "ChatGPT plan usage does not support audio input. Use text or an image.")
        case .reasoning: break
        }
      }
      flush()
    }
    // Only explicitly supported parameters cross the subscription boundary.
    var body: [String: JSONValue] = [
      "model": .string(request.model), "input": .array(input),
      "store": .bool(false), "stream": .bool(true),
      "include": .array([.string("reasoning.encrypted_content")]),
    ]
    if !request.tools.isEmpty {
      let tools: [ToolDefinition]
      if case .tool(let name) = request.toolChoice {
        tools = request.tools.filter { $0.name == name || resolver.apiName(for: $0.name) == name }
        guard !tools.isEmpty else {
          throw ChatGPTError.message("The requested ChatGPT tool is not registered.")
        }
      } else {
        tools = request.tools
      }
      body["tools"] = .array([
        .object([
          "type": .string("namespace"), "name": .string("pmai"),
          "description": .string("Tools available in pmai"),
          "tools": .array(
            tools.map { tool in
              .object([
                "type": .string("function"), "name": .string(resolver.apiName(for: tool.name)),
                "description": .string(tool.description), "parameters": tool.inputSchema,
                "strict": .bool(false),
              ])
            }),
        ])
      ])
      switch request.toolChoice {
      case .automatic: body["tool_choice"] = .string("auto")
      case .none: body["tool_choice"] = .string("none")
      case .required: body["tool_choice"] = .string("required")
      case .tool:
        body["tool_choice"] = .string("required")
        body["parallel_tool_calls"] = .bool(false)
      }
    }
    if let effort = request.options.reasoningEffort, !effort.isEmpty, effort != "automatic" {
      let value =
        ReasoningEffort(name: effort)?.requestFields(family: .openAI, model: request.model)[
          "reasoning_effort"]?.stringValue ?? effort
      body["reasoning"] = .object(["effort": .string(value), "summary": .string("auto")])
    }
    switch request.responseFormat {
    case .text: break
    case .jsonObject: body["text"] = .object(["format": .object(["type": .string("json_object")])])
    case .jsonSchema(let name, let schema, let strict):
      body["text"] = .object([
        "format": .object([
          "type": .string("json_schema"), "name": .string(name), "schema": schema,
          "strict": .bool(strict),
        ])
      ])
    }
    return .object(body)
  }

  private static func encoded(_ source: BinarySource, mimeType: String) -> String {
    switch source {
    case .url(let url): url.absoluteString
    case .data(let data): "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
  }

  static func validate(_ response: URLResponse, data: Data) throws {
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw ChatGPTError.message("Expected an HTTP response from ChatGPT.")
    }
    if (200..<300).contains(status) { return }
    let root = try? JSONDecoder().decode(JSONValue.self, from: data)
    let fallback =
      status == 401
      ? ChatGPTError.signInRequired.localizedDescription
      : "ChatGPT request failed: \(HTTPURLResponse.localizedString(forStatusCode: status))."
    throw failure(
      root?["error"] ?? root, status: status,
      requestID: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-request-id"),
      fallback: fallback)
  }

  static func failure(
    _ error: JSONValue?, status: Int? = nil, requestID: String? = nil,
    fallback: String = "ChatGPT request failed."
  ) -> ChatGPTError {
    let code = error?["code"]?.stringValue ?? ""
    var message =
      error?["message"]?.stringValue ?? error?["detail"]?.stringValue
      ?? error?.stringValue ?? fallback
    if code.contains("usage_limit") {
      message += " Manage ChatGPT plan usage at https://chatgpt.com/settings/usage."
    } else if code == "subscription_sharing_usage_unavailable" {
      message += " ChatGPT usage could not be checked. Try again later."
    }
    var details: [String] = []
    if let status { details.append("HTTP \(status)") }
    if !code.isEmpty { details.append("code: \(code)") }
    if let param = error?["param"]?.stringValue { details.append("parameter: \(param)") }
    if let requestID { details.append("request: \(requestID)") }
    if !details.isEmpty { message += " (" + details.joined(separator: "; ") + ")" }
    return .message(message)
  }
}

struct ChatGPTResponseStream {
  let resolver: ToolNameResolver
  var requestID: String? = nil
  var text = ""
  var reasoning = ""
  private var completedItems: [Int: JSONValue] = [:]

  init(resolver: ToolNameResolver, requestID: String? = nil) {
    self.resolver = resolver
    self.requestID = requestID
  }

  mutating func feed(_ payload: String, emit: ProviderEventHandler) async throws
    -> ProviderResponse?
  {
    guard !payload.isEmpty, payload != "[DONE]" else { return nil }
    guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
      let type = root["type"]?.stringValue
    else {
      throw ChatGPTProvider.failure(
        nil, requestID: requestID,
        fallback: "ChatGPT returned malformed JSON or a missing type in a response event.")
    }
    switch type {
    case "response.output_text.delta", "response.refusal.delta":
      let delta = root["delta"]?.stringValue ?? ""
      text += delta
      await emit(.textDelta(delta))
    case "response.reasoning_summary_text.delta":
      let delta = root["delta"]?.stringValue ?? ""
      reasoning += delta
      await emit(.reasoningDelta(delta))
    case "response.output_item.added":
      if let item = root["item"], item["type"]?.stringValue == "function_call" {
        await emit(
          .toolCallDelta(
            .init(
              index: root["output_index"]?.intValue ?? 0,
              id: item["call_id"]?.stringValue,
              name: item["name"]?.stringValue.flatMap { resolver.canonicalName(for: $0) })))
      }
    case "response.function_call_arguments.delta":
      await emit(
        .toolCallDelta(
          .init(
            index: root["output_index"]?.intValue ?? 0,
            argumentsFragment: root["delta"]?.stringValue ?? "")))
    case "response.output_item.done":
      guard let index = root["output_index"]?.intValue, index >= 0,
        let item = root["item"], item.objectValue != nil
      else { throw ChatGPTError.message("ChatGPT returned an invalid completed output item.") }
      completedItems[index] = item
    case "error", "response.failed":
      throw ChatGPTProvider.failure(
        root["response"]?["error"] ?? root["error"] ?? root, requestID: requestID)
    case "response.incomplete":
      let reason = root["response"]?["incomplete_details"]?["reason"]?.stringValue
      throw ChatGPTProvider.failure(
        nil, requestID: requestID,
        fallback:
          "ChatGPT response was incomplete\(reason.map { ": " + $0 } ?? ""). Try again or reduce the request size."
      )
    case "response.completed":
      guard let response = root["response"], response["status"]?.stringValue == "completed",
        let terminalOutput = response["output"]?.arrayValue
      else { throw ChatGPTError.message("ChatGPT did not complete the response.") }
      // Subscription streams may send items only in output_item.done, with an
      // empty output array in the terminal event. Still require response.completed.
      let output =
        terminalOutput.isEmpty
        ? completedItems.keys.sorted().compactMap { completedItems[$0] } : terminalOutput
      var content: [ContentPart] = []
      for item in output {
        switch item["type"]?.stringValue {
        case "message":
          for part in item["content"]?.arrayValue ?? [] {
            if let value = part["text"]?.stringValue ?? part["refusal"]?.stringValue {
              content.append(.text(value))
            }
          }
        case "function_call":
          guard let id = item["call_id"]?.stringValue, let name = item["name"]?.stringValue,
            let canonical = resolver.canonicalName(for: name),
            let raw = item["arguments"]?.stringValue,
            let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
            arguments.objectValue != nil
          else { throw ChatGPTError.message("ChatGPT returned an invalid tool call.") }
          content.append(.toolCall(.init(id: id, name: canonical, arguments: arguments)))
        case "reasoning":
          let summary = (item["summary"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
            .joined()
          if !summary.isEmpty { content.append(.reasoning(summary)) }
        default: break
        }
      }
      if !content.contains(where: {
        if case .text = $0 { return true }
        return false
      }), !text.isEmpty {
        content.append(.text(text))
      }
      if !content.contains(where: {
        if case .reasoning = $0 { return true }
        return false
      }), !reasoning.isEmpty {
        content.append(.reasoning(reasoning))
      }
      guard
        content.contains(where: {
          if case .toolCall = $0 { return true }
          if case .text(let text) = $0 { return !text.isEmpty }
          return false
        })
      else {
        throw OpenAICompatibleProviderError.emptyResponse
      }
      let usage = response["usage"].flatMap { value -> TokenUsage? in
        guard let input = value["input_tokens"]?.intValue,
          let output = value["output_tokens"]?.intValue
        else { return nil }
        return .init(
          inputTokens: input, outputTokens: output,
          cachedTokens: value["input_tokens_details"]?["cached_tokens"]?.intValue,
          reasoningTokens: value["output_tokens_details"]?["reasoning_tokens"]?.intValue)
      }
      if let usage { await emit(.usage(usage)) }
      var message = AgentMessage(role: .assistant, content: content)
      let reasoningItems = output.filter { $0["type"]?.stringValue == "reasoning" }
      if !reasoningItems.isEmpty {
        message.providerState = ["chatgpt.reasoning": .array(reasoningItems)]
      }
      return .init(
        message: message, usage: usage, stopReason: message.toolCalls.isEmpty ? .stop : .toolCall)
    default: break
    }
    return nil
  }
}

/// iOS's display adapter reconstructs tool messages from text. Keep the opaque
/// reasoning associated with those call IDs for the next tool turn as well.
private final class ChatGPTReasoningCache: @unchecked Sendable {
  static let shared = ChatGPTReasoningCache()
  private let lock = NSLock()
  private var values: [String: [JSONValue]] = [:]
  private var order: [String] = []

  func remember(account: String, message: AgentMessage) {
    guard let items = message.providerState?["chatgpt.reasoning"]?.arrayValue else { return }
    lock.withLock {
      for call in message.toolCalls {
        let key = account + "/" + call.id
        if values[key] == nil { order.append(key) }
        values[key] = items
      }
      while order.count > 256 { values.removeValue(forKey: order.removeFirst()) }
    }
  }

  func items(account: String, messages: [AgentMessage]) -> [String: [JSONValue]] {
    lock.withLock {
      var result: [String: [JSONValue]] = [:]
      for call in messages.flatMap(\.toolCalls) {
        result[call.id] = values[account + "/" + call.id]
      }
      return result
    }
  }
}

public struct ChatGPTConfiguredProviderFactory: ConfiguredProviderFactory {
  public let kind = ConfiguredProviderKind.chatGPT
  private let credentialsDirectory: URL?
  public init(credentialsDirectory: URL? = nil) { self.credentialsDirectory = credentialsDirectory }
  public func makeProvider(from configuration: ConfiguredProvider, environment: [String: String])
    throws -> any ChatProvider
  {
    ChatGPTProvider(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? "ChatGPT subscription",
      store: .init(
        providerID: configuration.options["account"]?.stringValue ?? configuration.id,
        directory: credentialsDirectory, environment: environment),
      timeout: configuration.timeout ?? 600)
  }
}
