import Foundation
import MaiCore

enum VoiceoverPromptBuilder {
  static let defaultPrompt = SystemPrompt(
    id: UUID(uuidString: "604FBECC-2ABD-46D0-8D57-90C75CC12C59")!,
    name: "Voiceover", text: AgentTask.voiceover.instructions)

  static func systemPrompt(settings: AppSettings) -> SystemPrompt {
    let id = settings.taskAgent(.voiceover)?.settings.defaultSystemPromptID ?? defaultPrompt.id
    return settings.systemPrompts.first { $0.id == id } ?? defaultPrompt
  }

  static func request(conversation: Conversation, settings: AppSettings) -> OneShotPromptRequest? {
    guard let message = conversation.messages.last, message.role == .assistant else { return nil }
    let text = MessageContentFilter.render(message.text).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let inference = settings.taskConversation(.voiceover, from: conversation)
    return OneShotPromptRequest(
      title: "Voiceover",
      prompt:
        "Summarize this assistant response for spoken playback in one or two sentences.\n\n\(text)",
      provider: inference.provider,
      modelID: inference.modelID,
      endpointID: inference.endpointID,
      reasoningLevel: inference.reasoningLevel,
      systemInstructions: systemPrompt(settings: settings).text)
  }
}

/// Summaries are stored separately from the model's chat history. A generation token also protects
/// against providers that return after cancellation or after a newer turn.
@MainActor
final class VoiceoverController {
  typealias Generate = (OneShotPromptRequest, AppSettings) async throws -> String
  private let generate: Generate
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var tokens: [UUID: UUID] = [:]

  init(generate: @escaping Generate = { try await OneShotPromptRunner.run($0, settings: $1) }) {
    self.generate = generate
  }

  func start(
    conversation: Conversation, settings: AppSettings,
    isCurrent: @escaping () -> Bool,
    speak: @escaping (String) -> Void,
    onError: @escaping (String) -> Void
  ) {
    let id = conversation.id
    cancel(in: id)
    guard conversation.voiceoverEnabled,
      let request = VoiceoverPromptBuilder.request(conversation: conversation, settings: settings)
    else { return }
    let token = UUID()
    tokens[id] = token
    tasks[id] = Task { [weak self, generate] in
      defer {
        if self?.tokens[id] == token {
          self?.tasks[id] = nil
          self?.tokens[id] = nil
        }
      }
      do {
        try Task.checkCancellation()
        guard self?.tokens[id] == token, isCurrent() else { return }
        let response = try await generate(request, settings)
        try Task.checkCancellation()
        guard self?.tokens[id] == token, isCurrent() else { return }
        let text = TTSSpeechTextSanitizer.sanitized(
          MessageContentFilter.render(response).visibleText, skipTechnicalContent: true)
        guard !text.isEmpty else {
          onError("The voiceover model returned no speakable text.")
          return
        }
        speak(text)
      } catch {
        guard !Task.isCancelled, self?.tokens[id] == token, isCurrent() else { return }
        onError(error.localizedDescription)
      }
    }
  }

  func wait(in conversationID: UUID) async {
    await tasks[conversationID]?.value
  }

  func cancel(in conversationID: UUID) {
    tasks.removeValue(forKey: conversationID)?.cancel()
    tokens[conversationID] = nil
  }

  func cancelAll() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    tokens.removeAll()
  }
}
