import Foundation
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class VoiceoverTests: XCTestCase {
  private func conversation() -> Conversation {
    var chat = Conversation()
    chat.provider = .apple
    chat.modelID = "main-model"
    chat.voiceoverEnabled = true
    chat.messages = [
      ChatMessage(role: .user, text: "Private earlier context"),
      ChatMessage(role: .assistant, text: "Previous answer"),
      ChatMessage(
        role: .assistant,
        text:
          "<think>Hidden reasoning</think><tool_run>Private tool output</tool_run>\nThe migration succeeded."
      ),
    ]
    return chat
  }

  func testOldChatsDefaultOffAndEnabledChatsRoundTrip() throws {
    let chat = conversation()
    let data = try JSONEncoder().encode(chat)
    XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: data), chat)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "voiceoverEnabled")
    let restored = try JSONDecoder().decode(
      Conversation.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertFalse(restored.voiceoverEnabled)
    XCTAssertNil(
      try JSONDecoder().decode(TaskAgentAssignments.self, from: Data("{}".utf8)).voiceover)
  }

  func testDefaultUsesChatModelWithSeparatePromptAndOnlyLastVisibleReply() throws {
    let chat = conversation()
    var settings = AppSettings()
    settings.memory = "Unrelated private memory"
    let request = try XCTUnwrap(
      VoiceoverPromptBuilder.request(conversation: chat, settings: settings))
    XCTAssertEqual(request.provider, .apple)
    XCTAssertEqual(request.modelID, "main-model")
    XCTAssertEqual(request.systemInstructions, AgentTask.voiceover.instructions)
    XCTAssertTrue(request.prompt.contains("The migration succeeded."))
    XCTAssertFalse(request.prompt.contains("Hidden reasoning"))
    XCTAssertFalse(request.prompt.contains("Private tool output"))
    XCTAssertFalse(request.prompt.contains("Private earlier context"))
    XCTAssertFalse(request.prompt.contains("Previous answer"))
    XCTAssertFalse(request.prompt.contains(settings.memory))
  }

  func testAssignedAgentUsesIndependentModelAndEditablePromptAfterRestart() throws {
    var settings = AppSettings()
    let custom = SystemPrompt(name: "Spoken", text: "Use a warm tone and short sentences.")
    settings.systemPrompts.append(custom)
    var agent = settings.addAgent(named: "Narrator")
    agent.settings.defaultProvider = .mlx
    agent.settings.localMLXModelID = "local/small"
    agent.settings.defaultSystemPromptID = custom.id
    agent.settings.defaultReasoningLevel = .disabled
    settings.agents[settings.agents.count - 1] = agent
    settings.taskAgents.voiceover = agent.id.uuidString.lowercased()
    var restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    let request = try XCTUnwrap(
      VoiceoverPromptBuilder.request(conversation: conversation(), settings: restored))
    XCTAssertEqual(request.provider, .mlx)
    XCTAssertEqual(request.modelID, "local/small")
    XCTAssertEqual(request.reasoningLevel, .disabled)
    XCTAssertEqual(request.systemInstructions, custom.text)
    restored.removeAgent(agent.id)
    XCTAssertNil(restored.taskAgents.voiceover)
    XCTAssertEqual(
      VoiceoverPromptBuilder.request(conversation: conversation(), settings: restored)?.provider,
      .apple)
  }

  func testDoesNotSummarizeErrorsUserMessagesOrEmptyHiddenReplies() {
    for message in [
      ChatMessage(role: .error, text: "Failed"),
      ChatMessage(role: .user, text: "Next turn"),
      ChatMessage(role: .assistant, text: "<think>Still reasoning</think>"),
      ChatMessage(role: .assistant, text: "  "),
    ] {
      var chat = conversation()
      chat.messages.append(message)
      XCTAssertNil(VoiceoverPromptBuilder.request(conversation: chat, settings: AppSettings()))
    }
  }

  func testOneShotSendsRemoteModelAndCustomSystemPromptWithoutToolsOrHistory() async throws {
    StubChatEndpoint.install()
    defer { StubChatEndpoint.uninstall() }
    StubChatEndpoint.script = { _ in (StubChatEndpoint.completion(content: "It's ready."), 0) }
    let endpoint = OpenAIEndpoint(
      name: "Voiceover fixture", baseURL: "https://\(StubChatEndpoint.host)/v1",
      defaultModel: "small")
    var settings = AppSettings()
    settings.openAIEndpoints = [endpoint]
    settings.memory = "Private memory"
    var chat = conversation()
    chat.messages[chat.messages.count - 1].voiceoverText = "Saved summary must not be model context"
    chat.provider = .openAICompatible
    chat.endpointID = endpoint.id
    chat.modelID = "small-voice-model"
    let request = try XCTUnwrap(
      VoiceoverPromptBuilder.request(conversation: chat, settings: settings))
    let result = try await OneShotPromptRunner.run(request, settings: settings)
    XCTAssertEqual(result, "It's ready.")
    let sent = try XCTUnwrap(StubChatEndpoint.requests.last)
    XCTAssertEqual(sent["model"] as? String, "small-voice-model")
    XCTAssertNil(sent["tools"])
    let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 2)
    XCTAssertFalse(String(describing: messages).contains("Saved summary must not be model context"))
    let system = try XCTUnwrap(messages.first?["content"] as? String)
    XCTAssertTrue(system.contains(AgentTask.voiceover.instructions))
    XCTAssertFalse(system.contains(AppSettings.defaultSystemPrompt.text))
    XCTAssertFalse(system.contains(settings.memory))
    XCTAssertEqual(chat.messages.count, 3, "The summary must stay out of the transcript")
  }

  func testControllerSpeaksSanitizedSummaryAndSkipsDisabledOrStaleRequests() async {
    var calls = 0
    var spoken: [String] = []
    let controller = VoiceoverController { _, _ in
      calls += 1
      return "<think>Secret</think>\n**It's ready.**"
    }
    let chat = conversation()
    controller.start(
      conversation: chat, settings: AppSettings(), isCurrent: { true },
      speak: { spoken.append($0) }, onError: { XCTFail($0) })
    await controller.wait(in: chat.id)
    XCTAssertEqual(spoken, ["It's ready."])

    controller.start(
      conversation: chat, settings: AppSettings(), isCurrent: { false },
      speak: { _ in XCTFail("Stale summary played") }, onError: { XCTFail($0) })
    await controller.wait(in: chat.id)
    var disabled = chat
    disabled.voiceoverEnabled = false
    controller.start(
      conversation: disabled, settings: AppSettings(), isCurrent: { true },
      speak: { _ in XCTFail("Disabled voiceover played") }, onError: { XCTFail($0) })
    await controller.wait(in: chat.id)
    XCTAssertEqual(calls, 1)
  }

  func testReplacementAndCancellationDiscardLateProviderResults() async {
    let started = expectation(description: "First generation started")
    var continuation: CheckedContinuation<String, Never>?
    var callCount = 0
    var spoken: [String] = []
    let controller = VoiceoverController { _, _ in
      callCount += 1
      if callCount == 1 {
        return await withCheckedContinuation {
          continuation = $0
          started.fulfill()
        }
      }
      return "New summary."
    }
    let chat = conversation()
    controller.start(
      conversation: chat, settings: AppSettings(), isCurrent: { true },
      speak: { spoken.append($0) }, onError: { XCTFail($0) })
    let firstFinished = Task { await controller.wait(in: chat.id) }
    await fulfillment(of: [started], timeout: 2)
    controller.cancel(in: chat.id)
    controller.start(
      conversation: chat, settings: AppSettings(), isCurrent: { true },
      speak: { spoken.append($0) }, onError: { XCTFail($0) })
    await controller.wait(in: chat.id)
    continuation?.resume(returning: "Old summary.")
    await firstFinished.value
    XCTAssertEqual(spoken, ["New summary."])
  }

  func testSummaryFailureDoesNotReadFullReply() async {
    let chat = conversation()
    var errors: [String] = []
    let controller = VoiceoverController { _, _ in throw URLError(.timedOut) }
    controller.start(
      conversation: chat, settings: AppSettings(), isCurrent: { true },
      speak: { _ in XCTFail("A failed summary must not play the verbose reply") },
      onError: { errors.append($0) })
    await controller.wait(in: chat.id)
    XCTAssertEqual(errors.count, 1)
    XCTAssertEqual(chat.messages.count, 3)
  }

  func testSavedSummaryRoundTripsAndIsInvalidatedOnlyWhenReplyChanges() throws {
    var message = ChatMessage(role: .assistant, text: "Detailed response")
    let before = ChatMessageRenderKey(message)
    message.voiceoverText = "Short spoken version."
    XCTAssertNotEqual(before, ChatMessageRenderKey(message))
    let data = try JSONEncoder().encode(message)
    XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: data), message)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "voiceoverText")
    XCTAssertNil(
      try JSONDecoder().decode(
        ChatMessage.self, from: JSONSerialization.data(withJSONObject: legacy)
      ).voiceoverText)
    message.text = "Detailed response"
    XCTAssertEqual(message.voiceoverText, "Short spoken version.")
    message.text = "Edited response"
    XCTAssertNil(message.voiceoverText)
  }

  func testGeneratedSummaryIsSavedBeforePlaybackAndSurvivesReloadAndClone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "voiceover-save-\(UUID())")
    defer {
      TTSPlayer.shared.stop()
      TTSPlayer.shared.dismissError()
      try? FileManager.default.removeItem(at: root)
    }
    let persistence = PersistenceStore(localBaseURL: root)
    let controller = VoiceoverController { _, _ in "The migration is ready." }
    let store = AppStore(persistence: persistence, monitorNetwork: false, voiceover: controller)
    try await waitUntil { store.hasLoadedPersistedSettings }
    await store.loadStoredConversationsForSearch()
    // Fail speech immediately, without accessing a device voice or a network service.
    store.settings.toolSettings.voices.assistant = RoleVoiceSettings(
      provider: .openAICompatible, openAIEndpointID: UUID(), openAIVoice: "missing")
    store.updateCurrentConversation {
      $0.messages = self.conversation().messages
      $0.voiceoverEnabled = true
    }
    let chat = try XCTUnwrap(store.currentConversation)
    let source = try XCTUnwrap(chat.messages.last)
    store.scheduleVoiceover(for: chat.id)
    await controller.wait(in: chat.id)
    let saved = try XCTUnwrap(store.activeConversation?.messages.last)
    XCTAssertEqual(saved.voiceoverText, "The migration is ready.")
    XCTAssertEqual(saved.text, source.text)
    XCTAssertNotNil(
      TTSPlayer.shared.errorMessage, "Speech failure must not lose the generated summary")
    try await waitUntil {
      persistence.loadConversation(id: chat.id)?.messages.last?.voiceoverText == saved.voiceoverText
    }
    store.updateCurrentConversationSettings { $0.voiceoverEnabled = false }
    XCTAssertEqual(store.currentConversation?.messages.last?.voiceoverText, saved.voiceoverText)
    store.cloneConversation(try XCTUnwrap(store.currentConversation))
    XCTAssertEqual(store.currentConversation?.messages.last?.voiceoverText, saved.voiceoverText)
    XCTAssertNotEqual(store.currentConversation?.messages.last?.id, source.id)
    store.updateCurrentConversation { $0.messages[$0.messages.count - 1].text = "Changed reply" }
    XCTAssertNil(store.currentConversation?.messages.last?.voiceoverText)
  }

  func testReplayUsesSavedSummaryAndSelectedVoiceWithoutGeneratingAgain() async throws {
    let endpoint = OpenAIEndpoint(defaultModel: "chat", speechModel: "tts-1")
    let voice = RoleVoiceSettings(
      provider: .openAICompatible, openAIEndpointID: endpoint.id, openAIVoice: "nova")
    let message = ChatMessage(
      role: .assistant, text: "A much longer original reply",
      voiceoverText: "Here is the short version.")
    var calls: [(String, String)] = []
    let player = TTSPlayer { _, text, voice in
      calls.append((text, voice))
      throw URLError(.timedOut)
    }
    for _ in 0..<2 {
      player.toggleVoiceoverPlayback(for: message, voice: voice, openAIEndpoints: [endpoint])
      XCTAssertTrue(player.isPlayingVoiceover(for: message.id))
      XCTAssertFalse(player.isPlayingVoiceover(for: UUID()))
      try await waitUntil { !player.isSpeaking }
    }
    XCTAssertEqual(calls.map { $0.0 }, Array(repeating: "Here is the short version.", count: 2))
    XCTAssertEqual(calls.map { $0.1 }, ["nova", "nova"])

    let pending = TTSPlayer { _, _, _ in
      try await Task.sleep(for: .seconds(30))
      return Data()
    }
    pending.speakVoiceover(for: message, voice: voice, openAIEndpoints: [endpoint])
    pending.toggleVoiceoverPlayback(for: message, voice: voice, openAIEndpoints: [endpoint])
    XCTAssertTrue(pending.isPaused)
    pending.toggleVoiceoverPlayback(for: message, voice: voice, openAIEndpoints: [endpoint])
    XCTAssertFalse(pending.isPaused)
    pending.stop()
  }

  func testCompletedTurnsScheduleVoiceoverOnlyWhenEnabledAndKeepWrittenReply() async throws {
    StubChatEndpoint.install()
    defer { StubChatEndpoint.uninstall() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceover-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var summaries: [OneShotPromptRequest] = []
    let controller = VoiceoverController { request, _ in
      summaries.append(request)
      // Stop before audio playback; also exercise failure isolation from the chat turn.
      throw URLError(.timedOut)
    }
    let store = AppStore(
      persistence: PersistenceStore(localBaseURL: root), monitorNetwork: false,
      voiceover: controller)
    try await waitUntil { store.hasLoadedPersistedSettings }
    await store.loadStoredConversationsForSearch()
    let endpoint = OpenAIEndpoint(
      name: "Voiceover fixture", baseURL: "https://\(StubChatEndpoint.host)/v1",
      defaultModel: "stub")
    store.settings.openAIEndpoints = [endpoint]
    store.settings.followUps.isEnabled = false
    store.settings.background.liveActivityEnabled = false
    store.settings.background.notifyWhenResponseFinishes = false
    store.settings.agents[0].canSpawnSubagents = false
    store.newConversation()
    store.updateCurrentConversation {
      $0.provider = .openAICompatible
      $0.modelID = "stub"
      $0.endpointID = endpoint.id
      $0.usesStreaming = false
      $0.toolsEnabled = false
      $0.voiceoverEnabled = true
      $0.messages = []
    }
    let id = try XCTUnwrap(store.currentConversation?.id)
    StubChatEndpoint.script = { _ in
      (StubChatEndpoint.completion(content: "The detailed written answer stays here."), 0)
    }
    let accepted = await store.send(prompt: "Explain this")
    XCTAssertTrue(accepted)
    try await waitUntil { !store.isResponding(in: id) }
    await controller.wait(in: id)
    XCTAssertEqual(summaries.count, 1)
    XCTAssertTrue(
      summaries.first?.prompt.contains("The detailed written answer stays here.") == true)
    XCTAssertEqual(
      store.currentConversation?.messages.last?.text, "The detailed written answer stays here.")
    XCTAssertEqual(store.currentConversation?.messages.filter { $0.role == .assistant }.count, 1)
    XCTAssertFalse(store.currentConversation?.messages.contains { $0.role == .error } ?? true)

    store.updateCurrentConversationSettings { $0.voiceoverEnabled = false }
    XCTAssertEqual(store.activeConversation?.voiceoverEnabled, false)
    let disabledAccepted = await store.send(prompt: "Another answer")
    XCTAssertTrue(disabledAccepted)
    try await waitUntil { !store.isResponding(in: id) }
    await controller.wait(in: id)
    XCTAssertEqual(summaries.count, 1)

    store.updateCurrentConversationSettings { $0.voiceoverEnabled = true }
    XCTAssertEqual(store.activeConversation?.voiceoverEnabled, true)
    StubChatEndpoint.script = { _ in (["error": ["message": "Provider failed"]], 0) }
    let failedAccepted = await store.send(prompt: "Fail this reply")
    XCTAssertTrue(failedAccepted)
    try await waitUntil { !store.isResponding(in: id) }
    await controller.wait(in: id)
    XCTAssertEqual(
      summaries.count, 1, "Failed turns must not summarize a previous successful reply")
    store.cancelAllVoiceovers()
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else {
        XCTFail("Timed out waiting for the voiceover fixture")
        throw URLError(.timedOut)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}
