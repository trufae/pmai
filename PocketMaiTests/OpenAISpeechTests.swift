import Foundation
import MaiCore
import MaiOpenAI
import XCTest

@testable import PocketMai

@MainActor
final class OpenAISpeechTests: XCTestCase {
  func testDirectOpenAISelectableBeforeDiscoveryAndWithoutCredentials() async throws {
    let endpoint = OpenAIEndpoint(defaultModel: "gpt-chat")
    XCTAssertTrue(endpoint.isSelectableForSpeech)
    let voices = try await OpenAICompatibleProvider.fetchVoices(endpoint: endpoint)
    XCTAssertEqual(voices, OpenAISpeech.voices)
    XCTAssertFalse(OpenAIEndpoint(isEnabled: false).isSelectableForSpeech)
    XCTAssertFalse(OpenAIEndpoint(kind: .chatGPT).isSelectableForSpeech)
    XCTAssertFalse(OpenAIEndpoint(kind: .systemOne).isSelectableForSpeech)
    let compatible = OpenAIEndpoint(baseURL: "http://localhost:8880/v1")
    XCTAssertTrue(compatible.isSelectableForSpeech)
    XCTAssertEqual(compatible.speechVoices(discovered: ["custom"]), ["custom"])
  }

  func testSwitchingProvidersDoesNotCarryAnUnsupportedVoice() {
    let compatible = OpenAIEndpoint(baseURL: "http://localhost:8880/v1")
    let openAI = OpenAIEndpoint()
    var voice = RoleVoiceSettings()
    voice.selectSpeechProvider(compatible, discovered: ["custom"])
    XCTAssertEqual(voice.openAIVoice, "custom")
    voice.selectSpeechProvider(openAI, discovered: [])
    XCTAssertEqual(voice.openAIEndpointID, openAI.id)
    XCTAssertTrue(OpenAISpeech.voices.contains(voice.openAIVoice))
    voice.openAIVoice = "nova"
    voice.selectSpeechProvider(compatible, discovered: ["nova", "custom"])
    XCTAssertEqual(voice.openAIVoice, "nova")
    voice.selectSpeechProvider(OpenAIEndpoint(baseURL: "http://other.local/v1"), discovered: [])
    XCTAssertEqual(voice.openAIVoice, "")
  }

  func testReturningFromSystemAndRefreshingPreservesCustomVoice() {
    let endpoint = OpenAIEndpoint(baseURL: "http://localhost:8880/v1")
    var voice = RoleVoiceSettings(
      provider: .system, openAIEndpointID: endpoint.id, openAIVoice: "manual-voice")
    voice.selectSpeechProvider(endpoint, discovered: [])
    XCTAssertEqual(voice.openAIVoice, "manual-voice")
    voice.selectSpeechProvider(endpoint, discovered: ["different-voice"])
    XCTAssertEqual(voice.openAIVoice, "manual-voice")
    voice.openAIVoice = "  "
    voice.selectSpeechProvider(endpoint, discovered: ["discovered-voice"])
    XCTAssertEqual(voice.openAIVoice, "discovered-voice")
  }

  func testUnsupportedAndDisabledProvidersCannotReplaceSelection() {
    let endpoint = OpenAIEndpoint()
    var voice = RoleVoiceSettings(
      provider: .openAICompatible, openAIEndpointID: endpoint.id, openAIVoice: "nova")
    let original = voice
    for unavailable in [
      OpenAIEndpoint(kind: .chatGPT), OpenAIEndpoint(kind: .systemOne),
      OpenAIEndpoint(isEnabled: false),
    ] {
      voice.selectSpeechProvider(unavailable, discovered: ["stale-cached-voice"])
      XCTAssertEqual(voice, original)
    }
    XCTAssertEqual(OpenAIEndpoint(kind: .chatGPT).speechVoices(discovered: ["stale"]), [])
  }

  func testUnavailableSpeechFailsBeforeSendingARequest() async throws {
    StubChatEndpoint.install()
    defer { StubChatEndpoint.uninstall() }
    let initialRequests = StubChatEndpoint.requests.count
    for endpoint in [
      OpenAIEndpoint(baseURL: "http://stub.local/v1", apiKey: "unused", kind: .chatGPT),
      OpenAIEndpoint(baseURL: "http://stub.local/v1", kind: .systemOne),
      OpenAIEndpoint(baseURL: "http://stub.local/v1", isEnabled: false),
      OpenAIEndpoint(),
    ] {
      do {
        _ = try await OpenAICompatibleProvider.synthesizeSpeechAudio(
          endpoint: endpoint, input: "Hello", voice: "nova")
        XCTFail("Unavailable providers must not synthesize")
      } catch {
        XCTAssertEqual(error.localizedDescription, endpoint.speechUnavailableReason)
      }
    }
    XCTAssertEqual(StubChatEndpoint.requests.count, initialRequests)
    XCTAssertTrue(
      OpenAIEndpoint(kind: .chatGPT).speechUnavailableReason?.contains("API key") == true)
    XCTAssertNil(OpenAIEndpoint(apiKey: "test-key").speechUnavailableReason)
    XCTAssertNil(
      OpenAIEndpoint(headers: ["authorization": "Bearer test-key"]).speechUnavailableReason)
    XCTAssertNil(OpenAIEndpoint(baseURL: "http://localhost:8880/v1").speechUnavailableReason)
  }

  func testSpeechModelIsIndependentOfChatModel() throws {
    var endpoint = OpenAIEndpoint(defaultModel: "gpt-chat")
    XCTAssertEqual(endpoint.effectiveSpeechModel, "gpt-4o-mini-tts")
    endpoint.speechModel = "tts-1-hd"
    endpoint.defaultModel = "other-chat"
    XCTAssertEqual(endpoint.effectiveSpeechModel, "tts-1-hd")
    XCTAssertFalse(endpoint.speechVoices(discovered: ["marin"]).contains("marin"))
    XCTAssertEqual(
      try JSONDecoder().decode(
        OpenAIEndpoint.self,
        from: JSONEncoder().encode(endpoint)), endpoint)
    let archive = ConfiguredProvider(pocketMai: endpoint)
    XCTAssertEqual(OpenAIEndpoint(archive: archive)?.speechModel, "tts-1-hd")
  }

  func testLegacyEndpointsPreserveCompatibleSpeechWithoutReusingOpenAIChatModel() throws {
    for (url, expected) in [
      ("https://api.openai.com/v1", "gpt-4o-mini-tts"),
      ("http://localhost:8880/v1", "old-model"),
    ] {
      let endpoint = OpenAIEndpoint(baseURL: url, defaultModel: "old-model")
      var json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(endpoint)) as? [String: Any])
      json.removeValue(forKey: "speechModel")
      var decoded = try JSONDecoder().decode(
        OpenAIEndpoint.self,
        from: JSONSerialization.data(withJSONObject: json))
      XCTAssertEqual(decoded.effectiveSpeechModel, expected)
      decoded.defaultModel = "new-chat-model"
      XCTAssertEqual(decoded.effectiveSpeechModel, expected)
    }
    let newCompatible = OpenAIEndpoint(
      baseURL: "http://localhost:8880/v1", defaultModel: "chat-model")
    XCTAssertEqual(newCompatible.effectiveSpeechModel, "")
  }

  func testLegacyRoleSettingsAndOfflineSelectionSurvive() throws {
    let id = UUID()
    let legacy = Data(
      """
      {"provider":"openAICompatible","openAIEndpointID":"\(id)","openAIVoice":"nova",
       "language":"es-ES","voiceIdentifier":"system-voice","rate":0.4,"pitch":1.2}
      """.utf8)
    let voice = try JSONDecoder().decode(RoleVoiceSettings.self, from: legacy)
    XCTAssertEqual(voice.openAIEndpointID, id)
    XCTAssertEqual(voice.openAIVoice, "nova")
    XCTAssertEqual(
      try JSONDecoder().decode(
        RoleVoiceSettings.self,
        from: JSONEncoder().encode(voice)), voice)
    let offline = voice.withoutOnlineProvider()
    XCTAssertEqual(offline.provider, .system)
    XCTAssertEqual(offline.openAIVoice, "nova")
    XCTAssertEqual(offline.openAIEndpointID, id)
    XCTAssertEqual(offline.voiceIdentifier, "system-voice")
  }

  func testMissingProviderReportsErrorWithoutSwitchingVoice() {
    let player = TTSPlayer { _, _, _ in
      XCTFail("Must not synthesize")
      return Data()
    }
    player.speak(
      text: "Hello",
      voice: .init(
        provider: .openAICompatible,
        openAIEndpointID: UUID(), openAIVoice: "nova"), role: .assistant)
    XCTAssertFalse(player.isSpeaking)
    XCTAssertTrue(player.errorMessage?.contains("missing or disabled") == true)
  }

  func testPreviewMessageQueueAndToolUseSelectedVoiceAndSpeechModel() async throws {
    let endpoint = OpenAIEndpoint(defaultModel: "chat-only", speechModel: "tts-1-hd")
    let voice = RoleVoiceSettings(
      provider: .openAICompatible, openAIEndpointID: endpoint.id, openAIVoice: "nova")
    var calls: [(String, String)] = []
    let player = TTSPlayer { endpoint, _, voice in
      calls.append((endpoint.effectiveSpeechModel, voice))
      throw ChatProviderError.providerHTTPError(statusCode: 429, message: "Quota exceeded")
    }
    for entry in 0..<4 {
      switch entry {
      case 0:
        player.speak(
          text: "Preview", voice: voice, role: .assistant, tag: "settings-test:assistant",
          openAIEndpoints: [endpoint])
      case 1:
        player.enqueue(
          text: "Live sentence", voice: voice, role: .assistant, openAIEndpoints: [endpoint])
      case 2:
        player.speakFromHere(
          messages: [ChatMessage(role: .assistant, text: "Read aloud")],
          voices: VoiceSettings(user: voice, assistant: voice), openAIEndpoints: [endpoint])
      default:
        var settings = NativeToolSettings.defaults
        settings.voices.assistant = voice
        _ = TextToSpeechTool.speak(
          arguments: ["text": .string("Tool speech")], settings: settings,
          openAIEndpoints: [endpoint], player: player)
      }
      for _ in 0..<100 where player.isSpeaking { await Task.yield() }
      XCTAssertFalse(player.isSpeaking)
      XCTAssertTrue(player.errorMessage?.contains("Quota exceeded") == true)
    }
    XCTAssertEqual(calls.map { $0.0 }, Array(repeating: "tts-1-hd", count: 4))
    XCTAssertEqual(calls.map { $0.1 }, Array(repeating: "nova", count: 4))
  }

  func testCancellationAndPauseDuringSynthesis() async throws {
    let endpoint = OpenAIEndpoint()
    let voice = RoleVoiceSettings(
      provider: .openAICompatible, openAIEndpointID: endpoint.id, openAIVoice: "coral")
    var calls = 0
    let player = TTSPlayer { _, _, _ in
      calls += 1
      try await Task.sleep(for: .seconds(30))
      return Data()
    }
    player.speak(text: "Hello", voice: voice, role: .assistant, openAIEndpoints: [endpoint])
    player.pause()
    XCTAssertTrue(player.isPaused)
    player.resume()
    XCTAssertFalse(player.isPaused)
    player.stop()
    await Task.yield()
    XCTAssertFalse(player.isSpeaking)
    XCTAssertNil(player.errorMessage)
    XCTAssertEqual(calls, 0, "Stopping before synthesis starts must not send a request")
  }
  func testAppSpeechRequestDoesNotUseChatModel() async throws {
    StubChatEndpoint.install()
    defer { StubChatEndpoint.uninstall() }
    StubChatEndpoint.script = { _ in
      (["error": ["message": "Mock synthesis error"]], 0)
    }
    let endpoint = OpenAIEndpoint(
      baseURL: "http://stub.local/v1", apiKey: "mock-key",
      defaultModel: "chat-only", speechModel: "gpt-4o-mini-tts")
    do {
      _ = try await OpenAICompatibleProvider.synthesizeSpeechAudio(
        endpoint: endpoint, input: "Hello", voice: "cedar")
      XCTFail("Expected mocked synthesis error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Mock synthesis error"))
    }
    let request = try XCTUnwrap(StubChatEndpoint.requests.last)
    XCTAssertEqual(request["model"] as? String, "gpt-4o-mini-tts")
    XCTAssertEqual(request["voice"] as? String, "cedar")
    XCTAssertEqual(request["response_format"] as? String, "wav")
  }

  func testPausedSynthesisWaitsForResumeAndFinishesQueuedAudio() async throws {
    let endpoint = OpenAIEndpoint()
    let voice = RoleVoiceSettings(
      provider: .openAICompatible, openAIEndpointID: endpoint.id, openAIVoice: "coral")
    let started = expectation(description: "Synthesis started")
    var continuation: CheckedContinuation<Data, Error>?
    var calls: [String] = []
    let audio = Self.silentWAV()
    let player = TTSPlayer { _, text, _ in
      calls.append(text)
      if calls.count == 1 {
        return try await withCheckedThrowingContinuation { pending in
          continuation = pending
          started.fulfill()
        }
      }
      return audio
    }
    defer { player.stop() }
    player.speak(text: "First.", voice: voice, role: .assistant, openAIEndpoints: [endpoint])
    player.enqueue(text: "Second.", voice: voice, role: .assistant, openAIEndpoints: [endpoint])
    await fulfillment(of: [started], timeout: 2)
    player.pause()
    continuation?.resume(returning: audio)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(player.isPaused)
    XCTAssertTrue(player.isSpeaking)
    XCTAssertNil(player.errorMessage)
    XCTAssertEqual(calls, ["First."])
    player.resume()
    for _ in 0..<300 where player.isSpeaking { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(player.isSpeaking)
    XCTAssertNil(player.errorMessage)
    XCTAssertEqual(calls, ["First.", "Second."])
  }

  func testLongReadAloudUsesExistingQueueInOrder() async throws {
    let endpoint = OpenAIEndpoint(defaultModel: "chat", speechModel: "gpt-4o-mini-tts")
    let voice = RoleVoiceSettings(
      provider: .openAICompatible, openAIEndpointID: endpoint.id, openAIVoice: "marin")
    let text = String(repeating: "A long spoken sentence. ", count: 180)
    var inputs: [String] = []
    let audio = Self.silentWAV()
    let player = TTSPlayer { endpoint, input, selectedVoice in
      XCTAssertEqual(endpoint.effectiveSpeechModel, "gpt-4o-mini-tts")
      XCTAssertEqual(selectedVoice, "marin")
      inputs.append(input)
      return audio
    }
    defer { player.stop() }
    player.speak(
      text: text, voice: voice, role: .assistant,
      openAIEndpoints: [endpoint], skipTechnicalContent: false)
    for _ in 0..<400 where player.isSpeaking { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(player.isSpeaking)
    XCTAssertNil(player.errorMessage)
    XCTAssertGreaterThan(inputs.count, 1)
    XCTAssertEqual(inputs.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
    XCTAssertTrue(inputs.allSatisfy { $0.utf8.count <= 2_000 })
  }

  func testMalformedAudioStopsQueueWithVisibleError() async throws {
    let endpoint = OpenAIEndpoint()
    let voice = RoleVoiceSettings(
      provider: .openAICompatible, openAIEndpointID: endpoint.id, openAIVoice: "nova")
    var calls = 0
    let player = TTSPlayer { _, _, _ in
      calls += 1
      return Data("not audio".utf8)
    }
    player.speak(text: "First", voice: voice, role: .assistant, openAIEndpoints: [endpoint])
    player.enqueue(text: "Second", voice: voice, role: .assistant, openAIEndpoints: [endpoint])
    for _ in 0..<100 where player.isSpeaking { await Task.yield() }
    XCTAssertFalse(player.isSpeaking)
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(player.errorMessage?.contains("could not be played") == true)
  }

  private static func silentWAV() -> Data {
    let samples = 4_800  // 0.2 seconds at 24 kHz, mono 16-bit PCM.
    var data = Data()
    func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
    func uint16(_ value: UInt16) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    func uint32(_ value: UInt32) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    ascii("RIFF")
    uint32(UInt32(36 + samples * 2))
    ascii("WAVEfmt ")
    uint32(16)
    uint16(1)
    uint16(1)
    uint32(24_000)
    uint32(48_000)
    uint16(2)
    uint16(16)
    ascii("data")
    uint32(UInt32(samples * 2))
    data.append(Data(count: samples * 2))
    return data
  }

}
