import Foundation
import MaiCore
import MaiOpenAI

extension AppStore {
  func audioServerModels() -> [[String: Any]] {
    var models: [[String: Any]] = [
      ["id": "system-tts", "object": "model", "owned_by": "apple", "task": "text-to-speech"],
      ["id": "system-stt", "object": "model", "owned_by": "apple", "task": "speech-to-text"],
    ]
    for endpoint in settings.openAIEndpoints
    where endpoint.isSelectableForSpeech && !settings.isOffline {
      for model in endpointModels[endpoint.id] ?? [] {
        let descriptor = endpointModelDescriptors[endpoint.id]?.first { $0.id == model }
        guard descriptor?.features.contains(.voice) == true
          || (descriptor?.features.isEmpty != false && Self.isAudioModel(model)) else { continue }
        models.append([
          "id": "\(endpoint.id.uuidString)::\(model)", "object": "model",
          "owned_by": endpoint.displayName,
        ])
      }
    }
    return models
  }

  static func isAudioModel(_ model: String) -> Bool {
    ["whisper", "transcri", "tts", "orpheus", "speech"].contains { model.lowercased().contains($0) }
  }

  private func audioEndpoint(_ selection: String) throws -> (OpenAIEndpoint, String) {
    let parts = selection.components(separatedBy: "::")
    guard parts.count == 2,
      let endpoint = settings.openAIEndpoints.first(where: {
        ($0.id.uuidString == parts[0] || $0.portableID == parts[0]) && $0.isSelectableForSpeech
      }), !parts[1].isEmpty
    else {
      throw AudioAPIError.invalidRequest(
        "Use system-tts/system-stt or a providerID::model from /v1/models.")
    }
    guard !settings.isOffline else {
      throw AudioAPIError.invalidRequest("Provider audio is unavailable in Airplane Mode.")
    }
    return (endpoint, parts[1])
  }

  func audioServerResponse(_ request: OpenAPIServerHTTPRequest) async throws
    -> OpenAPIServerHTTPResponse
  {
    if request.path == "/v1/voices" {
      let model = request.queryItems["model"] ?? "system-tts"
      let voices: [String]
      if model == "system-tts" {
        voices = SystemSpeech.voices
      } else {
        let (endpoint, name) = try audioEndpoint(model)
        var selected = endpoint
        selected.speechModel = name
        voices = try await OpenAICompatibleProvider.fetchVoices(endpoint: selected)
      }
      return .json(["object": "list", "data": voices.map { ["id": $0, "object": "voice"] }])
    }
    if request.path == "/v1/audio/speech" {
      let speech = try request.decodedBody(AudioSpeechRequest.self)
      guard speech.stream_format == nil || speech.stream_format == "audio" else {
        throw AudioAPIError.invalidRequest(
          "Use stream_format=audio; SSE audio events are not supported.")
      }
      let audio: AudioAPIResponse
      if speech.model == "system-tts" {
        audio = try await SystemSpeech.synthesize(
          input: speech.input, voice: speech.voice,
          format: speech.response_format ?? "wav", speed: speech.speed ?? 1)
      } else {
        let (endpoint, name) = try audioEndpoint(speech.model)
        var body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
        body["model"] = name
        audio = try await OpenAICompatibleProvider.forwardAudio(
          endpoint: endpoint, path: "audio/speech",
          body: JSONSerialization.data(withJSONObject: body), contentType: "application/json",
          streaming: true)
      }
      return OpenAPIServerHTTPResponse(
        statusCode: 200, reason: "OK",
        headers: ["Content-Type": audio.contentType], body: audio.body, stream: audio.stream)
    }
    var form = try AudioMultipart(
      data: request.body, contentType: request.headers["content-type"] ?? "")
    guard let model = form.field("model"),
      let file = form.parts.first(where: { $0.name == "file" }),
      !file.data.isEmpty
    else { throw AudioAPIError.invalidRequest("Transcription requires model and file fields.") }
    if model != "system-stt" {
      let (endpoint, name) = try audioEndpoint(model)
      form.parts = form.parts.map { part in
        var part = part
        if part.name == "model" { part.data = Data(name.utf8) }
        return part
      }
      let boundary = "pmai-\(UUID().uuidString)"
      let audio = try await OpenAICompatibleProvider.forwardAudio(
        endpoint: endpoint,
        path: "audio/transcriptions", body: form.encoded(boundary: boundary),
        contentType: "multipart/form-data; boundary=\(boundary)")
      return OpenAPIServerHTTPResponse(
        statusCode: 200, reason: "OK",
        headers: ["Content-Type": audio.contentType], body: audio.body)
    }
    let format = form.field("response_format") ?? "json"
    guard ["json", "text"].contains(format), form.field("stream") != "true" else {
      throw AudioAPIError.invalidRequest(
        "System transcription supports json/text responses without streaming.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let filename = URL(fileURLWithPath: file.filename ?? "audio.wav").lastPathComponent
    let url = directory.appendingPathComponent(
      filename == "." || filename == ".." ? "audio.wav" : filename)
    try file.data.write(to: url)
    let policy = speechTranscriptionPolicy
    policy.configure(settings)
    let text = try await AudioTranscriptionService.transcribe(
      fileURL: url,
      localeIdentifier: form.field("language") ?? Locale.current.identifier, policy: policy,
      useProvider: false)
    return format == "text" ? .text(text) : .json(["text": text])
  }
}
