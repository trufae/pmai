import Foundation

/// Context changes are stored alongside the original message, never over it.
/// A summary identifies its sources; exclusions and replacements affect only
/// inference. This travels with messages through checkpoints, forks and archives.
public struct AgentMessageContext: Codable, Equatable, Sendable {
  public var excluded: Bool = false
  public var replacement: Revision?
  public var sourceMessageIDs: [String]?

  public struct Revision: Codable, Equatable, Sendable {
    public var role: AgentRole
    public var content: [ContentPart]
    public var providerState: [String: JSONValue]?

    public init(_ message: AgentMessage) {
      role = message.role
      content = message.content
      providerState = message.providerState
    }
  }

  public init(excluded: Bool = false, sourceMessageIDs: [String]? = nil) {
    self.excluded = excluded
    self.sourceMessageIDs = sourceMessageIDs
  }
}

public enum AgentConversationContext {
  /// The working transcript. Storage-only metadata never reaches a provider.
  public static func messages(from history: [AgentMessage]) -> [AgentMessage] {
    history.compactMap { original in
      guard original.context?.excluded != true else { return nil }
      var message = original
      if let revision = message.context?.replacement {
        message.role = revision.role
        message.content = revision.content
        message.providerState = revision.providerState
      }
      message.context = nil
      return message
    }
  }

  /// Reconcile a reduced working transcript with its original evidence. New
  /// summaries keep their position relative to retained messages. Original
  /// messages remain in their original order, even when excluded from context.
  public static func replacing(_ history: [AgentMessage], with working: [AgentMessage])
    -> [AgentMessage]
  {
    let existing = Set(history.map(\.id))
    let active = Dictionary(working.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    var insertions: [String: [AgentMessage]] = [:]
    var pending: [AgentMessage] = []
    for message in working {
      if existing.contains(message.id) {
        if !pending.isEmpty { insertions[message.id] = pending; pending = [] }
      } else {
        pending.append(message)
      }
    }
    var result: [AgentMessage] = []
    for original in history {
      result += insertions[original.id] ?? []
      var message = original
      var context = original.context ?? AgentMessageContext()
      context.excluded = active[original.id] == nil
      if let selected = active[original.id] {
        let revision = AgentMessageContext.Revision(selected)
        context.replacement = revision == AgentMessageContext.Revision(original) ? nil : revision
      }
      message.context = context == AgentMessageContext() ? nil : context
      result.append(message)
    }
    result += pending
    return result
  }

  /// Restore original evidence, discarding context replacements and summaries.
  /// Summary records remain available in the archive for provenance.
  public static func rebuilt(_ history: [AgentMessage]) -> [AgentMessage] {
    history.map { original in
      var message = original
      if let sources = original.context?.sourceMessageIDs {
        message.context = AgentMessageContext(excluded: true, sourceMessageIDs: sources)
      } else {
        message.context = nil
      }
      return message
    }
  }

  /// A fresh working context retains instructions, without deleting history.
  public static func reset(_ history: [AgentMessage]) -> [AgentMessage] {
    replacing(history, with: messages(from: history).filter(AgentPromptContext.isInstruction))
  }
}
