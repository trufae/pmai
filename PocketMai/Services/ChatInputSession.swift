import Foundation

/// Routes the shared composer and voice session to the chat visible on screen.
@MainActor
struct ChatInputSession {
  let store: AppStore
  var remoteChat: RemoteAgentChat?

  var conversation: Conversation? { remoteChat?.presentation ?? store.currentConversation }
  var canSubmit: Bool { remoteChat?.canSubmit ?? true }
  var errorMessage: String? { remoteChat?.error ?? (remoteChat == nil ? store.errorMessage : nil) }
  var usesVoiceover: Bool { remoteChat == nil && conversation?.voiceoverEnabled == true }

  var assistantMessages: [ChatMessage] {
    if let remoteChat {
      // The timeline also renders remote thoughts and tool activity as assistant
      // bubbles. Voice playback must only consume actual assistant replies.
      return remoteChat.messages.filter { $0.role == "assistant" }.map {
        ChatMessage(id: $0.id, role: .assistant, text: $0.text)
      }
    }
    return conversation?.messages.filter { $0.role == .assistant } ?? []
  }

  var supportsImages: Bool {
    // Both remote transports currently accept text prompts. Documents and voice
    // notes use the same text attachment encoding as local provider requests.
    remoteChat == nil
      && ProviderVisionSupport.supportsImageInput(
        conversation: conversation, settings: store.settings)
  }

  func isResponding(in conversationID: UUID) -> Bool {
    remoteChat?.responding ?? store.isResponding(in: conversationID)
  }

  func cancelResponse() {
    if let remoteChat {
      remoteChat.cancel()
    } else if let id = conversation?.id {
      store.cancelResponse(in: id)
    }
  }

  func cancelVoiceover() {
    if remoteChat == nil, let id = conversation?.id { store.cancelVoiceover(in: id) }
  }

  func prepareToSend() {
    guard remoteChat == nil, let conversation = store.currentConversation,
      conversation.toolsEnabled, conversation.enabledTools.contains(.location),
      store.settings.toolSettings.useGPSLocation
    else { return }
    store.locationService.prefetch(precise: store.settings.toolSettings.preciseLocation)
  }

  func send(
    prompt: String, attachments: [ChatAttachment] = [], voiceRecordingFilename: String? = nil
  ) async -> Bool {
    if let remoteChat {
      let attachmentText = PromptComposer.attachmentPromptText(from: attachments)
      let text = [prompt, attachmentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
      return remoteChat.send(text)
    }
    return await store.send(
      prompt: prompt, voiceRecordingFilename: voiceRecordingFilename, attachments: attachments)
  }
}
