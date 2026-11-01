import Foundation
import MaiCore

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

  func promptCatalog(local: PromptCatalog) -> PromptCatalog {
    guard let remoteChat else { return local }
    return local.merging(remoteChat.promptCatalog, source: remoteChat.bookmark.name)
  }

  func send(
    prompt: String, attachments: [ChatAttachment] = [], voiceRecordingFilename: String? = nil
  ) async -> Bool {
    if let remoteChat {
      guard canSubmit else { return false }
      var text = prompt
      var invocation: String?
      var skillID: String?
      let local = store.promptCatalog()
      if let command = PromptSlashCommand.parse(prompt),
        let entry = promptCatalog(local: local).entry(named: command.command)
          ?? (command.command.hasPrefix("remote:")
            ? remoteChat.promptCatalog.entry(named: String(command.command.dropFirst(7))) : nil)
      {
        if entry.kind == .system {
          remoteChat.setSystemPrompt(SystemPrompt(name: entry.name, text: entry.text))
          text = command.remainder
          if text.isEmpty && attachments.isEmpty { return true }
        } else {
          // Local skill instructions travel as text; their iOS resource path is
          // not a directory the remote host can open.
          invocation = entry.invocation
          skillID = entry.skillID
          let localSkill = entry.kind == .skill && local.entries.contains { $0.skill == entry.skill }
          text = invocation != nil || skillID != nil ? command.remainder
            : localSkill ? UserPrompt.message(text: entry.text, arguments: command.remainder)
            : entry.message(arguments: command.remainder) ?? prompt
        }
      }
      let attachmentText = PromptComposer.attachmentPromptText(from: attachments)
      text = [invocation == nil ? remoteChat.conversation.systemPrompt?.text ?? "" : "", text, attachmentText]
        .filter { !$0.isEmpty }.joined(separator: "\n\n")
      return remoteChat.send(text, command: invocation, skillID: skillID)
    }
    return await store.send(
      prompt: prompt, voiceRecordingFilename: voiceRecordingFilename, attachments: attachments)
  }
}
