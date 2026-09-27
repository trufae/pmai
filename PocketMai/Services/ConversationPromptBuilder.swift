import Foundation
import MaiCore

enum OneShotPromptResponseFormat: Sendable {
  case text
  case followUpSuggestions(count: Int)
}

struct OneShotPromptRequest: Sendable {
  let title: String
  let prompt: String
  let provider: ProviderKind
  let modelID: String
  let endpointID: UUID?
  var responseFormat: OneShotPromptResponseFormat = .text
  var reasoningLevel: ReasoningLevel = .automatic
  var systemPromptID: UUID?
}

struct CompactConversationRequest: Sendable {
  let conversationID: UUID
  let oneShot: OneShotPromptRequest
}

enum ConversationPromptBuilder {
  static let transcriptPlaceholder = "{{transcript}}"

  static func compactPrompt(conversation: Conversation, settings: AppSettings) async -> String? {
    await Task.detached(priority: .userInitiated) {
      compactPromptText(conversation: conversation, template: settings.compactPrompt)
    }.value
  }

  static func compactRequest(
    conversation: Conversation,
    settings: AppSettings,
    prompt: String? = nil
  ) async -> CompactConversationRequest? {
    await Task.detached(priority: .userInitiated) {
      let promptText: String
      if let prompt {
        promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptText.isEmpty else { return nil }
      } else {
        guard
          let generated = compactPromptText(
            conversation: conversation,
            template: settings.compactPrompt)
        else { return nil }
        promptText = generated
      }
      let inference = settings.taskConversation(.compact, from: conversation)
      let model: String = {
        let m = inference.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        if inference.provider == .apple { return settings.appleModelID }
        if inference.provider == .mlx {
          return LocalMLXProvider.effectiveModelID(conversation: inference, settings: settings)
        }
        if let endpoint = OpenAICompatibleProvider.selectedEndpoint(
          for: inference, settings: settings)
        {
          return endpoint.defaultModel
        }
        return ""
      }()

      return CompactConversationRequest(
        conversationID: conversation.id,
        oneShot: OneShotPromptRequest(
          title: "Compact",
          prompt: promptText,
          provider: inference.provider,
          modelID: model,
          endpointID: inference.endpointID,
          reasoningLevel: inference.reasoningLevel,
          systemPromptID: inference.systemPromptID
        )
      )
    }.value
  }

  private static func compactPromptText(conversation: Conversation, template: String) -> String? {
    let transcriptEntries = conversation.messages.compactMap { msg -> String? in
      guard msg.role != .error else { return nil }
      let text = MessageContentFilter.promptSafeText(from: msg.text)
      guard !text.isEmpty else { return nil }
      return "\(msg.role.displayName):\n\(text)"
    }
    guard transcriptEntries.count >= 2 else { return nil }

    let transcript = transcriptEntries.joined(separator: "\n\n---\n\n")
    let promptTemplate =
      template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? AppSettings.defaultCompactPrompt
      : template
    if promptTemplate.contains(transcriptPlaceholder) {
      return promptTemplate.replacingOccurrences(of: transcriptPlaceholder, with: transcript)
    }
    return "\(promptTemplate)\n\nTranscript:\n\n\(transcript)"
  }

  static func memoryUpdateRequest(
    conversations: [Conversation],
    settings: AppSettings
  ) async -> OneShotPromptRequest? {
    await Task.detached(priority: .userInitiated) {
      let transcript = AgentMemoryPrompt.transcript(of: conversations.map { MemoryChat($0) })
      guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }

      // The notes already recorded travel with the request, so an update
      // merges rather than starting over.
      let prompt = AgentMemoryPrompt.render(
        existing: AgentMemory(text: settings.memory),
        transcript: transcript)
      let defaultProvider = settings.defaultProviderConfiguration
      return OneShotPromptRequest(
        title: "Memory update",
        prompt: prompt,
        provider: defaultProvider.provider,
        modelID: defaultProvider.modelID,
        endpointID: defaultProvider.endpointID
      )
    }.value
  }
}

enum OneShotPromptRunner {
  static func run(_ prompt: OneShotPromptRequest, settings: AppSettings) async throws -> String {
    var oneShot = Conversation()
    oneShot.title = prompt.title
    oneShot.provider = prompt.provider
    oneShot.modelID = prompt.modelID
    oneShot.endpointID = prompt.endpointID
    oneShot.reasoningLevel = prompt.reasoningLevel
    oneShot.systemPromptID = prompt.systemPromptID
    oneShot.toolsEnabled = false
    oneShot.enabledTools = []
    oneShot.usesStreaming = false
    oneShot.messages = [ChatMessage(role: .user, text: prompt.prompt)]
    var request = ChatCompletionRequest(
      conversation: oneShot,
      settings: settings,
      context: "",
      assistantMessageID: UUID()
    )
    request.oneShotResponseFormat = prompt.responseFormat
    return try await ChatProviderRouter.complete(request: request) { _ in }
  }
}
