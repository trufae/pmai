import Foundation
import MaiCore

/// Transient presentation state: never part of a chat's history or export.
struct BTWQuestion: Identifiable, Equatable {
  let id: UUID
  let conversationID: UUID
  let prompt: String
  var answer = ""
  var isRunning = true
  var error: String?

  static func prompt(in text: String) -> String? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("/"), let command = PromptSlashCommand.parse(text),
      command.command.lowercased() == "btw"
    else { return nil }
    return command.remainder
  }

  static func conversation(from source: Conversation, prompt: String) -> Conversation {
    var conversation = source
    conversation.id = UUID()
    conversation.sessionID = ChatSession.newID()
    conversation.title = "BTW: \(prompt)"
    conversation.messages = [ChatMessage(role: .user, text: prompt)]
    conversation.subagents = []
    conversation.lastContextSignature = nil
    return conversation
  }
}

extension AppStore {
  /// The isolated tool loop has its own transcript, task, and provider session.
  /// It retains the selected profile, tools, memory, and approval policy.
  @discardableResult
  func startBTW(_ prompt: String, in conversationID: UUID) -> Bool {
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      errorMessage = "Usage: /btw QUESTION"
      return false
    }
    guard let source = conversation(withID: conversationID) else { return false }
    let settings = settings
    let conversation = settings.taskConversation(
      .btw, from: BTWQuestion.conversation(from: source, prompt: prompt))
    if let message = ChatProviderRouter.preflightMessage(conversation: conversation, settings: settings) {
      errorMessage = message
      return false
    }
    errorMessage = nil
    let id = conversation.id
    btwQuestions.append(BTWQuestion(id: id, conversationID: conversationID, prompt: prompt))
    btwTasks[id] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        btwTasks[id] = nil
        responseBackgroundTasks.removeValue(forKey: id)?.finish()
        refreshBackgroundKeepAlive()
        drainThenQueue()
        // Agent tools may have created a process for this transient context.
        stopAgentProcesses(for: id, reason: "Side question finished")
        if let index = btwQuestions.firstIndex(where: { $0.id == id }) {
          btwQuestions[index].isRunning = false
        }
      }
      do {
        let context = await ContextBuilder.build(
          input: prompt, conversation: conversation, settings: settings,
          locationService: { self.locationService })
        try Task.checkCancellation()
        let result = try await AssistantToolLoop.runIsolated(
          conversation: conversation, settings: settings, baseContext: context.text, store: self)
        try Task.checkCancellation()
        if let index = btwQuestions.firstIndex(where: { $0.id == id }) {
          btwQuestions[index].answer = result.text
        }
      } catch {
        if let index = btwQuestions.firstIndex(where: { $0.id == id }) {
          let cancelled = Task.isCancelled || error is CancellationError
            || (error as NSError).code == NSURLErrorCancelled
          btwQuestions[index].error = cancelled ? "Stopped" : error.localizedDescription
        }
      }
    }
    let background = ResponseBackgroundTask(
      onExpiration: {}, onCancellation: { [weak self] in self?.stopBTW(id) })
    responseBackgroundTasks[id] = background
    background.start(
      title: "Side question", useContinuedProcessing: settings.background.liveActivityEnabled
        && conversation.provider == .openAICompatible)
    refreshBackgroundKeepAlive()
    return true
  }

  func stopBTW(_ id: UUID) {
    btwTasks[id]?.cancel()
  }

  func dismissBTW(_ id: UUID) {
    stopBTW(id)
    btwQuestions.removeAll { $0.id == id }
  }

  func dismissBTWQuestions(in conversationID: UUID? = nil) {
    for question in btwQuestions where conversationID == nil || question.conversationID == conversationID {
      stopBTW(question.id)
    }
    btwQuestions.removeAll { conversationID == nil || $0.conversationID == conversationID }
  }
}
