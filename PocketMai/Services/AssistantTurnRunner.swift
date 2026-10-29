import Foundation

@MainActor
enum AssistantTurnRunner {
  static func run(
    conversationID: UUID,
    context: String,
    store: AppStore
  ) async {
    guard !Task.isCancelled else { return }
    guard let assistantID = store.appendAssistantMessage(to: conversationID) else {
      return
    }

    do {
      try await AssistantToolLoop.run(
        conversationID: conversationID,
        assistantID: assistantID,
        baseContext: context,
        store: store)
      try Task.checkCancellation()
    } catch is CancellationError {
      store.markLatestAssistantStopped(in: conversationID, fallbackID: assistantID)
    } catch {
      let nsError = error as NSError
      if Task.isCancelled
        || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
      {
        store.markLatestAssistantStopped(in: conversationID, fallbackID: assistantID)
      } else {
        let text = error.localizedDescription
        store.markLatestAssistantFailed(
          in: conversationID,
          fallbackID: assistantID,
          message: text)
        store.errorMessage = text
      }
    }
  }
}
