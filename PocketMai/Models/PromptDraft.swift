import Foundation
import MaiCore

/// Shared editing and validation for the two kinds of named prompt.
struct PromptDraft: Equatable {
  enum Kind { case system, user }

  let kind: Kind
  let id: UUID?
  var name: String
  var text: String
  var isDefault: Bool

  init(systemPrompt: SystemPrompt? = nil, isDefault: Bool = false) {
    kind = .system
    id = systemPrompt?.id
    name = systemPrompt?.name ?? ""
    text = systemPrompt?.text ?? "You are a helpful assistant."
    self.isDefault = isDefault
  }

  init(userPrompt: UserPrompt?) {
    kind = .user
    id = userPrompt?.id
    name = userPrompt?.name ?? ""
    text = userPrompt?.text ?? "Use these instructions when answering."
    isDefault = false
  }

  /// Returns an actionable error without changing settings if saving fails.
  func save(to settings: inout AppSettings, original: PromptDraft) -> String? {
    let savedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    // Imported legacy names remain editable until the person renames them.
    if id == nil || savedName != original.name.trimmingCharacters(in: .whitespacesAndNewlines) {
      guard !savedName.isEmpty else { return "Specify a prompt name." }
      if savedName.contains(where: { $0.isWhitespace }) || savedName.contains("/") {
        return "Prompt names cannot contain spaces or /."
      }
      let otherNames =
        settings.systemPrompts
        .filter { kind != .system || $0.id != id }.map(\.commandName)
        + settings.userPrompts.filter { kind != .user || $0.id != id }.map(\.commandName)
      let commandName = PromptSlashCommand.commandName(for: savedName).lowercased()
      if otherNames.contains(where: { $0.lowercased() == commandName }) {
        return "A prompt named \"\(savedName)\" already exists."
      }
    }

    switch kind {
    case .system:
      let prompt = SystemPrompt(id: id ?? UUID(), name: savedName, text: text)
      if let id {
        guard let index = settings.systemPrompts.firstIndex(where: { $0.id == id }) else {
          return "This prompt no longer exists."
        }
        settings.systemPrompts[index] = prompt
      } else {
        settings.systemPrompts.append(prompt)
      }
      if isDefault { settings.defaultSystemPromptID = prompt.id }
    case .user:
      let prompt = UserPrompt(id: id ?? UUID(), name: savedName, text: text)
      if let id {
        guard let index = settings.userPrompts.firstIndex(where: { $0.id == id }) else {
          return "This prompt no longer exists."
        }
        settings.userPrompts[index] = prompt
      } else {
        settings.userPrompts.append(prompt)
      }
    }
    return nil
  }
}
