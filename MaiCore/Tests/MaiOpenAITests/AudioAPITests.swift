import Foundation
import Testing

@testable import MaiCore
@testable import MaiOpenAI
@testable import MaiTestSupport

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test("Groq has model-specific voices without requesting an unsupported voices endpoint")
func groqVoiceCatalog() async throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: URL(string: "https://api.groq.com/openai/v1")!),
    session: stubSession())
  #expect(
    try await provider.availableVoices() == GroqSpeech.voices(for: GroqSpeech.defaultSpeechModel))
  #expect(
    try await provider.availableVoices(model: "canopylabs/orpheus-arabic-saudi") == [
      "abdullah", "fahad", "sultan", "lulwa", "noura", "aisha",
    ])
  let request = try provider.makeSpeechRequest(input: "Hello", voice: "autumn")
  let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody))
  #expect(body["model"] == .string(GroqSpeech.defaultSpeechModel))
  #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/speech")
  #expect(throws: AudioAPIError.self) {
    try provider.makeSpeechRequest(input: "Hello", voice: "alloy")
  }
  #expect(throws: AudioAPIError.self) {
    try provider.makeSpeechRequest(input: String(repeating: "a", count: 201), voice: "autumn")
  }
  #expect(!GroqSpeech.isDirectEndpoint(URL(string: "https://api.groq.com.example.test")!))
}

@Test("Multipart preserves binary audio, including strings resembling boundaries")
func audioMultipartRoundTrip() throws {
  let binary = Data([0, 255, 128]) + Data("\r\n--pmai-test-not-a-boundary\r\n".utf8)
  let form = AudioMultipart(parts: [
    .init(name: "model", data: Data("whisper-large-v3-turbo".utf8)),
    .init(name: "file", filename: "note.wav", contentType: "audio/wav", data: binary),
  ])
  let encoded = try form.encoded(boundary: "pmai-test")
  let decoded = try AudioMultipart(
    data: encoded, contentType: "multipart/form-data; boundary=\"pmai-test\"")
  #expect(decoded.field("model") == "whisper-large-v3-turbo")
  #expect(decoded.parts.last?.data == binary)
  #expect(decoded.parts.last?.filename == "note.wav")
  #expect(throws: AudioAPIError.self) {
    try AudioMultipart(
      data: encoded.dropLast(8), contentType: "multipart/form-data; boundary=pmai-test")
  }
  #expect(throws: AudioAPIError.self) {
    try AudioMultipart(data: encoded, contentType: "application/json")
  }
  #expect(throws: AudioAPIError.self) {
    try AudioMultipart(parts: [.init(name: "file", filename: "x\r\nInjected: true", data: binary)])
      .encoded(boundary: "test")
  }
}

@Test("Transcription uses multipart audio and configured authentication, without a chat request")
func providerAudioTranscription() async throws {
  let host = "transcription.example.test"
  let audio = Data([0, 1, 255, 42])
  StubURLProtocol.install(forHost: host) { request in
    #expect(request.url?.path == "/v1/audio/transcriptions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let form = try AudioMultipart(
      data: requestBodyData(request),
      contentType: #require(request.value(forHTTPHeaderField: "Content-Type")))
    #expect(form.field("model") == "whisper-large-v3-turbo")
    #expect(form.field("language") == "es")
    #expect(form.parts.first { $0.name == "file" }?.data == audio)
    return try httpResponse(
      request, status: 200, contentType: "application/json", body: #"{"text":"¿Qué es esto?"}"#)
  }
  defer { StubURLProtocol.reset(host: host) }
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "test-key"),
    session: stubSession())
  #expect(
    try await provider.transcribeAudio(
      audio: audio, filename: "note.wav", model: "whisper-large-v3-turbo", language: "es")
      == "¿Qué es esto?")
}

@Test("Groq text chunks preserve Unicode and stay below its 200-character budget")
func groqSpeechChunks() {
  let text = String(repeating: "¡Hola! 日本語 🙂 ", count: 80)
  let chunks = OpenAISpeech.textChunks(text, maximumUTF8Bytes: 200)
  #expect(chunks.joined() == text)
  #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 200 })
}

@Test("Speech speed is forwarded only when changed and rejects invalid rates")
func providerSpeechSpeed() throws {
  let provider = OpenAICompatibleProvider(configuration: .init(baseURL: URL(string: "https://speech.example.test/v1")!))
  let changed = try provider.makeSpeechRequest(input: "Hello", voice: "default", speed: 1.25)
  let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(changed.httpBody))
  #expect(body["speed"] == .number(1.25))
  let normal = try provider.makeSpeechRequest(input: "Hello", voice: "default")
  let defaults = try JSONDecoder().decode([String: JSONValue].self, from: #require(normal.httpBody))
  #expect(defaults["speed"] == nil)
  #expect(throws: AudioAPIError.self) { try provider.makeSpeechRequest(input: "Hello", voice: "default", speed: 0) }
}
