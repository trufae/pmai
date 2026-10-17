import Foundation

extension AppStore {
  func scheduleVoiceover(for conversationID: UUID) {
    guard !Task.isCancelled, !hasQueuedUserMessages(in: conversationID),
      let conversation = conversation(withID: conversationID),
      conversation.voiceoverEnabled,
      let source = conversation.messages.last, source.role == .assistant
    else { return }
    voiceover.start(
      conversation: conversation, settings: settings,
      isCurrent: { [weak self] in
        guard let self, let current = self.conversation(withID: conversationID) else {
          return false
        }
        return current.voiceoverEnabled && !self.isResponding(in: conversationID)
          && current.messages.last?.id == source.id && current.messages.last?.text == source.text
      },
      speak: { [weak self] text in
        guard let self, let current = self.conversation(withID: conversationID) else { return }
        TTSPlayer.shared.speak(
          text: text,
          voice: self.effectiveToolSettings(for: current).voices.assistant,
          role: .assistant, title: "Voiceover", tag: Self.voiceoverTag(conversationID),
          messageID: source.id,
          openAIEndpoints: self.settings.isOffline ? [] : self.settings.openAIEndpoints)
      },
      onError: { [weak self] message in self?.errorMessage = "Voiceover: \(message)" })
  }

  func cancelVoiceover(in conversationID: UUID) {
    voiceover.cancel(in: conversationID)
    if TTSPlayer.shared.currentTag == Self.voiceoverTag(conversationID) {
      TTSPlayer.shared.stop()
    }
  }

  func cancelAllVoiceovers() {
    voiceover.cancelAll()
    if TTSPlayer.shared.currentTag?.hasPrefix("voiceover:") == true {
      TTSPlayer.shared.stop()
    }
  }

  private static func voiceoverTag(_ id: UUID) -> String { "voiceover:\(id.uuidString)" }
}
