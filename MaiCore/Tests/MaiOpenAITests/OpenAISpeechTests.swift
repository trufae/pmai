import Foundation
import Testing

@testable import MaiCore
@testable import MaiOpenAI
@testable import MaiTestSupport

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test("Direct OpenAI built-in voices are available without any discovery or credentials")
func openAISpeechBuiltInVoices() async throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(baseURL: URL(string: "https://api.openai.com/v1")!),
    session: stubSession())  // No stub installed: any network request fails this test.
  #expect(try await provider.availableVoices() == OpenAISpeech.voices)
  #expect(OpenAISpeech.voices.count == 13)
  #expect(
    try await provider.availableVoices(model: "tts-1") == [
      "alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer",
    ])
  #expect(
    try await provider.availableVoices(model: "tts-1-hd") == OpenAISpeech.voices(for: "tts-1"))
  #expect(!OpenAISpeech.isDirectEndpoint(URL(string: "https://api.openai.com.example.test/v1")!))
  #expect(!OpenAISpeech.isDirectEndpoint(URL(string: "https://example.test/openai/v1")!))
}

@Test(
  "Direct speech requests normalize URLs, use TTS defaults and retain authentication headers",
  arguments: [
    "https://api.openai.com", "https://api.openai.com/v1/",
    "https://api.openai.com/v1/chat/completions",
  ])
func openAISpeechRequestConstruction(base: String) throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: URL(string: base)!, apiKey: "test-key",
      additionalHeaders: ["OpenAI-Project": "test-project"]))
  let request = try provider.makeSpeechRequest(input: "Hello", voice: "marin")
  let body = try jsonObject(#require(request.httpBody))
  #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
  #expect(request.value(forHTTPHeaderField: "OpenAI-Project") == "test-project")
  #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  #expect(request.value(forHTTPHeaderField: "Accept") == "audio/wav")
  #expect(body["model"] as? String == "gpt-4o-mini-tts")
  #expect(body["voice"] as? String == "marin")
  #expect(body["input"] as? String == "Hello")
  #expect(body["response_format"] as? String == "wav")
  let selected = try provider.makeSpeechRequest(input: "Hi", voice: "nova", model: " tts-1-hd ")
  #expect(try jsonObject(#require(selected.httpBody))["model"] as? String == "tts-1-hd")
  #expect(throws: OpenAICompatibleProviderError.self) {
    try provider.makeSpeechRequest(input: "Hi", voice: "marin", model: "tts-1")
  }
  #expect(throws: OpenAICompatibleProviderError.self) {
    try provider.makeSpeechRequest(input: "Hi", voice: "missing-voice")
  }
}

@Test("Compatible speech requests retain custom voices and optional models")
func openAISpeechCompatibleRequest() throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: URL(string: "http://localhost:8880/v1")!))
  let request = try provider.makeSpeechRequest(input: "Hi", voice: "custom_voice")
  #expect(try jsonObject(#require(request.httpBody))["model"] == nil)
  let selected = try provider.makeSpeechRequest(input: "Hi", voice: "custom_voice", model: "kokoro")
  #expect(try jsonObject(#require(selected.httpBody))["model"] as? String == "kokoro")
}

@Test(
  "Speech failures retain API details and do not accept JSON or empty audio",
  arguments: [401, 403, 404, 429, 500, 200, 204])
func openAISpeechErrors(status: Int) async throws {
  let host = "speech-error-\(status).example.test"
  StubURLProtocol.install(forHost: host) { request in
    try httpResponse(
      request, status: status, contentType: "application/json",
      body: status == 204
        ? ""
        : #"{"error":{"message":"Requested speech model unavailable; check credentials or quota."}}"#
    )
  }
  defer { StubURLProtocol.reset(host: host) }
  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: URL(string: "https://\(host)/v1")!), session: stubSession())
  do {
    _ = try await provider.synthesizeSpeech(input: "Hello", voice: "nova", model: "tts-model")
    Issue.record("Expected speech failure")
  } catch {
    if status == 204 {
      #expect(error as? OpenAICompatibleProviderError == .emptyResponse)
    } else {
      #expect(error.localizedDescription.contains("Requested speech model unavailable"))
      if status != 200 { #expect(error.localizedDescription.contains("HTTP \(status)")) }
    }
  }
}

@Test(
  "Long OpenAI speech preserves text within character and token budgets",
  arguments: [
    "Short sentence.", String(repeating: "Sentence one. Sentence two. ", count: 300),
    String(repeating: "日本語の声です。🙂", count: 700), String(repeating: "é", count: 5_000), "",
  ])
func openAISpeechTextChunks(text: String) {
  let chunks = OpenAISpeech.textChunks(text)
  #expect(chunks.joined() == text)
  #expect(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 2_000 })
  if text.utf8.count > 2_000 { #expect(chunks.count > 1) }
}
