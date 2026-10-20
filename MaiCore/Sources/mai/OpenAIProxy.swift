import Foundation
import MaiACPGateway
import MaiCore
import MaiOpenAI

/// Hosts the same configured runtime as ACP/MCP, with an isolated history per request.
enum OpenAIProxy {
  static func serve(
    runtime: AgentRuntime, agent: AgentDefinition, configuration: MaiConfiguration?,
    environment: [String: String], host: String, port: Int, tokenEnvironment: String,
    allowTools: Bool, onListening: @escaping @Sendable () -> Void = {}
  ) async throws {
    let token = environment[tokenEnvironment] ?? ""
    guard ["127.0.0.1", "::1", "localhost"].contains(host) || !token.isEmpty else {
      throw AudioAPIError.invalidRequest(
        "Set \(tokenEnvironment) before binding the tool server to a LAN interface.")
    }
    try await OpenAIHTTPServer.serve(
      host: host, port: port,
      handler: { request in
        if !token.isEmpty {
          let supplied = request.headers["authorization"] ?? ""
          let expected = "Bearer \(token)"
          guard supplied.utf8.count == expected.utf8.count,
            zip(supplied.utf8, expected.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0
          else {
            return .error("Invalid bearer token.", status: 401)
          }
        }
        do {
          return try await respond(
            request, runtime: runtime, agent: agent,
            configuration: configuration, environment: environment, allowTools: allowTools)
        } catch let error as OpenAICompatibleProviderError {
          if case .httpError(let statusCode, let message) = error {
            return .error(message, status: statusCode)
          }
          return .error(error.localizedDescription, status: 502)
        } catch let error as AudioAPIError { return .error(error.localizedDescription) } catch let
          error as DecodingError
        { return .error(error.localizedDescription) } catch {
          return .error(error.localizedDescription, status: 502)
        }
      },
      onListening: onListening)
  }

  private static func provider(
    _ selection: String, configuration: MaiConfiguration?,
    environment: [String: String]
  ) throws -> (OpenAICompatibleProvider, String) {
    guard let separator = selection.range(of: "::") else {
      throw AudioAPIError.invalidRequest("Audio models must use providerID::model.")
    }
    let parts = [
      String(selection[..<separator.lowerBound]), String(selection[separator.upperBound...]),
    ]
    guard !parts[1].isEmpty,
      let config = configuration?.providers.first(where: { $0.id == parts[0] && $0.kind == .openAI }
      ),
      let baseURL = config.baseURL
    else {
      throw AudioAPIError.invalidRequest(
        "Audio requires system-tts/system-stt or an OpenAI-compatible providerID::model.")
    }
    guard configuration?.airplane != true else {
      throw AudioAPIError.invalidRequest("Provider audio is unavailable in Airplane Mode.")
    }
    return (
      OpenAICompatibleProvider(
        configuration: .init(
          id: ProviderID(config.id),
          baseURL: baseURL, apiKey: try config.resolvedAPIKey(environment: environment),
          additionalHeaders: try config.resolvedHeaders(environment: environment),
          requestTimeout: config.timeout ?? 600)), parts[1]
    )
  }

  static func respond(
    _ request: ProxyHTTPRequest, runtime: AgentRuntime,
    agent: AgentDefinition, configuration: MaiConfiguration?, environment: [String: String],
    allowTools: Bool
  ) async throws -> ProxyHTTPResponse {
    let url = URLComponents(string: request.path)
    let path = url?.path ?? request.path
    if request.method == "GET", path == "/health" {
      return .json(.object(["status": .string("ok")]))
    }
    if request.method == "GET", path == "/v1/models" {
      var ids = ["agent:\(agent.id)"]
      ids += await runtime.availableAgents(includingDisabled: false).map { "agent:\($0.id)" }
      for descriptor in await runtime.availableProviders() {
        for model in (try? await runtime.availableModels(provider: descriptor.id)) ?? [] {
          ids.append("\(descriptor.id.rawValue)::\(model.id)")
        }
      }
      #if canImport(AVFoundation)
        ids += ["system-stt", "system-tts"]
      #endif
      return .json(
        .object([
          "object": .string("list"),
          "data": .array(
            Set(ids).sorted().map {
              .object(["id": .string($0), "object": .string("model"), "owned_by": .string("pmai")])
            }),
        ]))
    }
    if request.method == "GET", path == "/v1/voices" {
      let model = url?.queryItems?.first { $0.name == "model" }?.value ?? "system-tts"
      let voices: [String]
      #if canImport(AVFoundation)
        if model == "system-tts" {
          voices = await SystemSpeech.voices
        } else {
          let (client, name) = try provider(
            model, configuration: configuration, environment: environment)
          voices = try await client.availableVoices(model: name)
        }
      #else
        let (client, name) = try provider(
          model, configuration: configuration, environment: environment)
        voices = try await client.availableVoices(model: name)
      #endif
      return .json(
        .object([
          "object": .string("list"),
          "data": .array(
            voices.map {
              .object(["id": .string($0), "object": .string("voice")])
            }),
        ]))
    }
    if request.method == "POST", path == "/v1/audio/speech" {
      let speech = try JSONDecoder().decode(AudioSpeechRequest.self, from: request.body)
      guard speech.stream_format == nil || speech.stream_format == "audio" else {
        throw AudioAPIError.invalidRequest(
          "Use stream_format=audio; SSE audio events are not supported.")
      }
      #if canImport(AVFoundation)
        if speech.model == "system-tts" {
          let audio = try await SystemSpeech.synthesize(
            input: speech.input, voice: speech.voice,
            format: speech.response_format ?? "wav", speed: speech.speed ?? 1)
          return .init(contentType: audio.contentType, body: audio.body, stream: audio.stream)
        }
      #endif
      let (client, model) = try provider(
        speech.model, configuration: configuration, environment: environment)
      var body = try JSONDecoder().decode([String: JSONValue].self, from: request.body)
      body["model"] = .string(model)
      let audio = try await client.audioRequest(
        endpoint: "audio/speech",
        body: JSONEncoder().encode(body), contentType: "application/json", streaming: true)
      return .init(contentType: audio.contentType, body: audio.body, stream: audio.stream)
    }
    if request.method == "POST", path == "/v1/audio/transcriptions" {
      var form = try AudioMultipart(
        data: request.body, contentType: request.headers["content-type"] ?? "")
      guard let selection = form.field("model"),
        let file = form.parts.first(where: { $0.name == "file" }),
        !file.data.isEmpty
      else { throw AudioAPIError.invalidRequest("Transcription requires model and file fields.") }
      #if canImport(AVFoundation)
        if selection == "system-stt" {
          let format = form.field("response_format") ?? "json"
          guard ["json", "text"].contains(format), form.field("stream") != "true" else {
            throw AudioAPIError.invalidRequest(
              "System transcription supports json/text responses without streaming.")
          }
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: directory) }
          let name = URL(fileURLWithPath: file.filename ?? "audio.wav").lastPathComponent
          let fileURL = directory.appendingPathComponent(
            name == "." || name == ".." ? "audio.wav" : name)
          try file.data.write(to: fileURL)
          let text = try await SystemSpeech.transcribe(
            file: fileURL, language: form.field("language"))
          return format == "text"
            ? .init(contentType: "text/plain", body: Data(text.utf8))
            : .json(.object(["text": .string(text)]))
        }
      #endif
      let (client, model) = try provider(
        selection, configuration: configuration, environment: environment)
      form.parts = form.parts.map {
        var p = $0
        if p.name == "model" { p.data = Data(model.utf8) }
        return p
      }
      let boundary = "pmai-\(UUID().uuidString)"
      let audio = try await client.audioRequest(
        endpoint: "audio/transcriptions",
        body: form.encoded(boundary: boundary),
        contentType: "multipart/form-data; boundary=\(boundary)")
      return .init(contentType: audio.contentType, body: audio.body)
    }
    guard request.method == "POST", path == "/v1/chat/completions" else {
      return .error("Unsupported endpoint.", status: 404)
    }
    let body = try JSONDecoder().decode(ChatInput.self, from: request.body)
    var selected = agent
    if let model = body.model, model.hasPrefix("agent:") {
      guard
        let match = await runtime.availableAgents(includingDisabled: false).first(where: {
          $0.id == String(model.dropFirst(6))
        })
      else {
        throw AudioAPIError.invalidRequest("Unknown agent.")
      }
      selected = match
    } else if let model = body.model, !model.isEmpty {
      let selection = try ModelSelection(model, currentProvider: selected.provider)
      selected.provider = selection.provider
      selected.model = selection.model
    }
    guard !body.messages.isEmpty, body.messages.contains(where: { $0.role == "user" }) else {
      throw AudioAPIError.invalidRequest("At least one user message is required.")
    }
    var messages = AgentChat.initialHistory(for: selected)
    for message in body.messages {
      guard ["system", "user", "assistant", "developer"].contains(message.role),
        let role = AgentRole(rawValue: message.role)
      else { throw AudioAPIError.invalidRequest("Unsupported message role.") }
      let text: String
      if let value = message.content.stringValue {
        text = value
      } else if let parts = message.content.arrayValue,
        parts.allSatisfy({ $0.objectValue?["type"]?.stringValue == "text" })
      {
        text = parts.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
      } else {
        throw AudioAPIError.invalidRequest("This proxy accepts text messages.")
      }
      messages.append(AgentMessage(role: role, content: text))
    }
    let run = AgentRequest(
      agentID: selected.id, provider: selected.provider, model: selected.model,
      messages: messages, toolNames: allowTools ? selected.toolNames : [],
      toolGroupNames: allowTools ? selected.toolGroupNames : [],
      subagentNames: allowTools ? selected.subagentNames : [],
      toolChoice: allowTools ? selected.toolChoice : .none, responseFormat: selected.responseFormat,
      options: selected.options, limits: selected.limits,
      stream: body.stream ?? false, toolCallingStrategy: selected.toolCallingStrategy,
      useToolProxy: allowTools && selected.useToolProxy,
      useSystemOne: allowTools && selected.useSystemOne,
      proxyExposedTools: selected.proxyExposedTools,
      toolPolicy: selected.toolPolicy, toolDelegation: selected.toolDelegation,
      retry: selected.retry, autocompact: selected.autocompact, context: selected.context)
    let id = "chatcmpl-\(UUID().uuidString)"
    let model = body.model ?? "agent:\(selected.id)"
    if body.stream == true {
      let stream = AsyncThrowingStream<Data, Error> { continuation in
        let task = Task {
          do {
            _ = try await runtime.run(run) { event in
              if case .provider(let context, .textDelta(let text)) = event, context.depth == 0 {
                continuation.yield(sse(id: id, model: model, text: text, done: false))
              }
            }
            continuation.yield(sse(id: id, model: model, text: "", done: true))
            continuation.yield(Data("data: [DONE]\n\n".utf8))
            continuation.finish()
          } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
      return .init(contentType: "text/event-stream", stream: stream)
    }
    let result = try await runtime.run(run)
    return .json(
      .object([
        "id": .string(id), "object": .string("chat.completion"),
        "created": .integer(Int(Date().timeIntervalSince1970)), "model": .string(model),
        "choices": .array([
          .object([
            "index": .integer(0),
            "message": .object([
              "role": .string("assistant"), "content": .string(result.response.text),
            ]), "finish_reason": .string("stop"),
          ])
        ]),
      ]))
  }

  private static func sse(id: String, model: String, text: String, done: Bool) -> Data {
    let object: JSONValue = .object([
      "id": .string(id), "object": .string("chat.completion.chunk"),
      "created": .integer(Int(Date().timeIntervalSince1970)), "model": .string(model),
      "choices": .array([
        .object([
          "index": .integer(0), "delta": .object(["content": .string(text)]),
          "finish_reason": done ? .string("stop") : .null,
        ])
      ]),
    ])
    return Data(
      "data: \(String(decoding: (try? JSONEncoder().encode(object)) ?? Data(), as: UTF8.self))\n\n"
        .utf8)
  }
  private struct ChatInput: Decodable {
    var model: String?
    var messages: [Message]
    var stream: Bool?
    struct Message: Decodable {
      var role: String
      var content: JSONValue
    }
  }
}
