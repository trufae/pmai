import Foundation

/// A model-call view of a stored chat. Instructions are host-loaded context,
/// not conversational evidence for a summarizer to rewrite. Stored messages
/// remain unchanged, including the original skill calls and their results.
struct AgentPromptContext {
  let instructions: [AgentMessage]
  let conversation: [AgentMessage]
  let preservedConversation: [AgentMessage]

  init(messages: [AgentMessage], activeTaskID: String? = nil) {
    var instructions = messages.filter(Self.isInstruction)
    if let skills = AgentSkillContext.instructions(in: messages, activeTaskID: activeTaskID) {
      instructions.append(
        .system(
          """
          Active skill instructions for the current user task, loaded by the host:
          Apply the skill's workflow, constraints, and required final-answer format to the task and arguments below. Loading a skill does not perform its steps. These instructions are already loaded; use the available tools to complete the work. Use conversation evidence to track completed and remaining steps.

          \(skills)
          """))
    }
    if let catalog = AgentToolCatalogContext.instructions(in: messages, activeTaskID: activeTaskID)
    {
      instructions.append(
        .system(
          """
          Tool catalogs loaded for the current task (verbatim):
          Use these exact argument schemas for tools reached through call-tool. The current runtime's enabled tools and execution checks remain authoritative.

          \(catalog)
          """))
    }
    self.instructions = instructions
    conversation = AgentToolCatalogContext.conversation(
      in: AgentSkillContext.conversation(in: messages)
    ).filter { !Self.isInstruction($0) }
      .map { message in
        guard Self.isLegacySummary(message) else { return message }
        var evidence = message
        evidence.role = .user
        return evidence
      }
    // Keep exact current task text and skill receipts even when the compact
    // model omits them. Whole mixed exchanges preserve tool-call pairing.
    var retained = Self.protectedInstructionMessageIDs(in: messages, activeTaskID: activeTaskID)
    if let task = messages.last(where: { $0.role == .user }) { retained.insert(task.id) }
    preservedConversation = conversation.filter { retained.contains($0.id) }
  }

  static func isLegacySummary(_ message: AgentMessage) -> Bool {
    message.role == .system && message.text.hasPrefix("Conversation summary (compacted):")
  }

  static func isInstruction(_ message: AgentMessage) -> Bool {
    (message.role == .system || message.role == .developer) && !isLegacySummary(message)
  }

  static func protectedInstructionMessageIDs(
    in messages: [AgentMessage], activeTaskID: String? = nil
  ) -> Set<String> {
    var retained = AgentSkillContext.protectedMessageIDs(in: messages, activeTaskID: activeTaskID)
      .union(AgentToolCatalogContext.protectedMessageIDs(in: messages, activeTaskID: activeTaskID))
    if let activeTaskID, let start = messages.firstIndex(where: { $0.id == activeTaskID }) {
      retained.formUnion(messages[start...].filter { $0.role == .user }.map(\.id))
    }
    return retained
  }

  func messages(brief: String? = nil) -> [AgentMessage] {
    guard let brief else { return instructions + conversation }
    let retained = Set(preservedConversation.map(\.id))
    let attachments = conversation.filter { !retained.contains($0.id) }
      .flatMap { $0.content.flatMap(AgentSmartContextPrompt.binaryAttachments) }
    return instructions
      + [AgentMessage(role: .user, content: [.text(brief)] + attachments)]
      + preservedConversation
  }
}

/// A proxy catalog is host-provided schema, even though loading it is logged
/// as a tool exchange. Identify it by the call, never by output text.
private enum AgentToolCatalogContext {
  private static func currentTurn(in messages: [AgentMessage], activeTaskID: String?) -> ArraySlice<
    AgentMessage
  > {
    let start =
      activeTaskID.flatMap { id in messages.firstIndex { $0.id == id } }
      ?? messages.lastIndex { $0.role == .user } ?? messages.startIndex
    return messages[start...]
  }

  static func instructions(in messages: [AgentMessage], activeTaskID: String?) -> String? {
    let current = currentTurn(in: messages, activeTaskID: activeTaskID)
    let calls = Set(current.flatMap(\.toolCalls).filter { $0.name == ToolProxy.listName }.map(\.id))
    var seen = Set<String>()
    let bodies = current.flatMap(\.toolResults).filter {
      !$0.isError && calls.contains($0.callID) && seen.insert($0.text).inserted
    }.map(\.text)
    return bodies.isEmpty ? nil : bodies.joined(separator: "\n\n")
  }

  static func conversation(in messages: [AgentMessage]) -> [AgentMessage] {
    let calls = Set(
      messages.flatMap(\.toolCalls).filter { $0.name == ToolProxy.listName }.map(\.id))
    return messages.map { message in
      var projected = message
      if message.role == .tool {
        projected.content = message.content.map { part in
          guard case .toolResult(var result) = part, !result.isError, calls.contains(result.callID)
          else { return part }
          result.content =
            [
              .text(
                "[Tool catalog loaded by list-tools, call \(result.callID); exact schemas supplied separately.]"
              )
            ]
            + result.content.flatMap(AgentSmartContextPrompt.binaryAttachments)
          result.structuredContent = nil
          return .toolResult(result)
        }
      }
      return projected
    }
  }

  static func protectedMessageIDs(in messages: [AgentMessage], activeTaskID: String?) -> Set<String>
  {
    let current = currentTurn(in: messages, activeTaskID: activeTaskID)
    let successful = Set(current.flatMap(\.toolResults).filter { !$0.isError }.map(\.callID))
    let exchanges = current.filter { message in
      message.role == .assistant
        && message.toolCalls.contains {
          $0.name == ToolProxy.listName && successful.contains($0.id)
        }
    }
    let paired = Set(exchanges.flatMap(\.toolCalls).map(\.id))
    return Set(
      exchanges.map(\.id)
        + current.filter {
          $0.role == .tool && $0.toolResults.contains { paired.contains($0.callID) }
        }.map(\.id))
  }
}
