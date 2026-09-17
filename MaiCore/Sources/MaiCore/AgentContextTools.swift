import Foundation

/// An edit an agent asked for on its own conversation. The runtime applies it
/// before the agent's next model turn, so a run can drop what no longer
/// matters — a wrong instruction, a long tool result, an aside — and go on
/// with a smaller context instead of dragging it to the end.
public enum AgentTranscriptEdit: Equatable, Sendable {
  case remove(messageIDs: [String])
  case rewrite(messageID: String, text: String)
  /// Replaces the messages with one summary at the place of the first.
  case compact(messageIDs: [String], summary: String)
  /// `compact` with the summary still to be written: the runtime asks the
  /// model for it with the compaction prompt, guided by `focus` when there is
  /// one, and applies the result as a `compact`. `AgentTranscriptEditor.apply`
  /// has no model and leaves it alone.
  case summarize(messageIDs: [String], focus: String)
}

/// What applying edits did, for hosts to show and tools to report.
public struct AgentTranscriptEditReport: Equatable, Sendable {
  public var removed: Int
  public var rewritten: Int
  public var compacted: Int
  public var charactersBefore: Int
  public var charactersAfter: Int

  public init(
    removed: Int = 0,
    rewritten: Int = 0,
    compacted: Int = 0,
    charactersBefore: Int = 0,
    charactersAfter: Int = 0
  ) {
    self.removed = removed
    self.rewritten = rewritten
    self.compacted = compacted
    self.charactersBefore = charactersBefore
    self.charactersAfter = charactersAfter
  }

  public var isEmpty: Bool { removed == 0 && rewritten == 0 && compacted == 0 }

  /// `removed 3 messages, compacted 4 into a summary (12.3k → 2.1k chars)`
  public var summary: String {
    var parts: [String] = []
    if removed > 0 { parts.append("removed \(removed) message\(removed == 1 ? "" : "s")") }
    if rewritten > 0 { parts.append("rewrote \(rewritten) message\(rewritten == 1 ? "" : "s")") }
    if compacted > 0 {
      parts.append("compacted \(compacted) message\(compacted == 1 ? "" : "s") into a summary")
    }
    guard !parts.isEmpty else { return "nothing changed" }
    let before = AgentProcessInfo.compactCount(charactersBefore)
    let after = AgentProcessInfo.compactCount(charactersAfter)
    return parts.joined(separator: ", ") + " (\(before) → \(after) chars)"
  }
}

/// Applies context edits to a transcript. Removing either side of a tool
/// exchange removes the other side too, so what is left can still be sent to
/// a provider.
public enum AgentTranscriptEditor {
  public static func apply(
    _ edits: [AgentTranscriptEdit],
    to messages: [AgentMessage]
  ) -> (messages: [AgentMessage], report: AgentTranscriptEditReport) {
    var transcript = AgentTranscript(messages: messages)
    var report = AgentTranscriptEditReport(charactersBefore: characterCount(of: messages))
    for edit in edits {
      switch edit {
      case .remove(let ids):
        for id in ids {
          if let dropped = try? transcript.removeMessage(id: id) { report.removed += dropped.count }
        }
      case .rewrite(let id, let text):
        if (try? transcript.editMessage(id: id, text: text)) != nil { report.rewritten += 1 }
      case .compact(let ids, let summary):
        guard let first = ids.compactMap({ transcript.index(ofMessageID: $0) }).min() else { continue }
        var dropped = 0
        for id in ids {
          if let removed = try? transcript.removeMessage(id: id) { dropped += removed.count }
        }
        guard dropped > 0 else { continue }
        report.compacted += dropped
        var all = transcript.messages
        all.insert(summaryMessage(summary), at: min(first, all.count))
        transcript.replaceAll(with: all)
      case .summarize:
        continue
      }
    }
    report.charactersAfter = characterCount(of: transcript.messages)
    return (transcript.messages, report)
  }

  /// A transcript cut off inside a tool exchange — by Ctrl+C, a crash, a
  /// dropped connection — ends with calls nobody answered, which providers
  /// reject. This answers each with an error that says so, so the transcript
  /// can be run again and the model knows those steps did not happen.
  public static func answeringUnansweredToolCalls(
    in messages: [AgentMessage],
    reason: String
  ) -> [AgentMessage] {
    let answered = Set(messages.flatMap(\.toolResults).map(\.callID))
    var repaired = messages
    for (index, message) in messages.enumerated().reversed() where message.role == .assistant {
      let pending = message.toolCalls.filter { !answered.contains($0.id) }
      guard !pending.isEmpty else { continue }
      let results = pending.map {
        ContentPart.toolResult(
          ToolResult(callID: $0.id, text: "Error: not executed; \(reason).", isError: true))
      }
      repaired.insert(AgentMessage(role: .tool, content: results), at: index + 1)
      break
    }
    return repaired
  }

  /// A summary reads as something the conversation already covered, in the
  /// user's voice so every provider accepts it wherever it lands.
  static func summaryMessage(_ summary: String) -> AgentMessage {
    .user(
      "Summary of earlier parts of this conversation, written by the assistant to save context:\n\n"
        + summary.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public static func characterCount(of messages: [AgentMessage]) -> Int {
    messages.reduce(0) { $0 + characterCount(of: $1) }
  }

  public static func characterCount(of message: AgentMessage) -> Int {
    message.content.reduce(0) { total, part in
      switch part {
      case .text(let text), .reasoning(let text): total + text.count
      case .toolCall(let call): total + call.name.count + call.arguments.compactJSONString.count
      case .toolResult(let result): total + result.text.count
      case .file(let file): total + (file.text?.count ?? 0)
      case .resource(let resource): total + (resource.text?.count ?? 0)
      case .image, .audio: total + 64
      }
    }
  }
}

/// Tools an agent uses on its own context: see what is in it, drop messages,
/// rewrite one, or fold a stretch into a summary it writes itself or leaves
/// to the runtime. Each call reads the running process's transcript from the
/// supervisor and queues an edit the runtime applies before the next model
/// turn, so the following turn already runs on the smaller conversation.
///
/// The system prompt, the latest user prompt, and the turn in progress are
/// kept out of reach; a task that should start with no history at all belongs
/// in a child agent.
public enum MaiContextTools {
  public static let listName = "context_list"
  public static let removeName = "context_remove"
  public static let rewriteName = "context_rewrite"
  public static let compactName = "context_compact"
  public static let groupID = "context"

  public static let toolNames = [listName, removeName, rewriteName, compactName]

  /// What `/tools` shows for the family: what it is for and how the four
  /// tools work together.
  public static let group = ToolGroupDefinition(
    id: groupID,
    sourceID: "runtime",
    displayName: "Context",
    description:
      "Let the agent manage its own conversation instead of carrying every detour to the end. "
      + "context_list numbers the messages with their roles, sizes, and a preview; context_remove drops "
      + "messages by number, range, \"last N\", or \"all\" (a tool call and its result always go together); "
      + "context_rewrite replaces one message's text, for example a long tool result cut to what matters; "
      + "context_compact folds a stretch into a summary the agent writes or, when it gives none, one the "
      + "runtime generates with the compaction prompt. Edits are queued and applied before the next model "
      + "turn. The system prompt, the latest user prompt, and the turn in progress are never touched.",
    toolNames: Set(toolNames))

  private static let previewLength = 90

  private static func messagesParameter(required: Bool, suffix: String = "") -> ToolParameterDef {
    ToolParameterDef(
      name: "messages", type: "string",
      description:
        "Which messages, as numbered by context_list: one (\"4\"), several (\"3, 5\"), a range (\"3-7\"), \"last N\" for the N most recent, or \"all\" for everything that can go. The system prompt, the latest user prompt, and the turn in progress are always kept."
        + suffix,
      required: required)
  }

  public static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description:
        "Show what this conversation holds: every message numbered, with its role, size, and a one-line preview, and the total size. Use it to decide what context_remove, context_rewrite, or context_compact should act on; their message numbers come from here.",
      parameters: [],
      annotations: ToolAnnotations(
        readOnly: true, idempotent: true, openWorld: false, approval: .automatic)),
    ToolDefinition(
      name: removeName,
      description:
        "Drop messages from this conversation before your next turn: an aside that no longer matters, a superseded instruction, tool output you have already used. Removing a tool call removes its result and the other way round. \"last N\" drops the most recent exchanges; \"all\" keeps only the system prompt and the latest user prompt.",
      parameters: [messagesParameter(required: true)],
      annotations: ToolAnnotations(
        readOnly: false, destructive: true, idempotent: false, openWorld: false,
        approval: .confirm)),
    ToolDefinition(
      name: rewriteName,
      description:
        "Replace the text of one message before your next turn, keeping any tool calls it carries: correct a wrong instruction, or cut a long tool result down to the lines that still matter.",
      parameters: [
        ToolParameterDef(
          name: "message", type: "integer", description: "Message number from context_list.",
          required: true),
        ToolParameterDef(
          name: "text", type: "string", description: "The new text of the message.",
          required: true),
      ],
      annotations: ToolAnnotations(
        readOnly: false, destructive: true, idempotent: false, openWorld: false,
        approval: .confirm)),
    ToolDefinition(
      name: compactName,
      description:
        "Replace a stretch of messages with one summary before your next turn, keeping the facts, decisions, paths, and results still needed. Write the summary yourself, or omit it and the runtime generates one with the compaction prompt. Use it when the context has grown with details that no longer help; a task that needs no history at all belongs in a child agent (agent_start).",
      parameters: [
        messagesParameter(required: false, suffix: " Default: \"all\"."),
        ToolParameterDef(
          name: "summary", type: "string",
          description:
            "What the messages established, in a few lines. Omit it to have the runtime summarize them with the model.",
          required: false),
        ToolParameterDef(
          name: "focus", type: "string",
          description:
            "Without summary: what the generated summary must keep, for example the decisions taken and the failing test names.",
          required: false),
      ],
      annotations: ToolAnnotations(
        readOnly: false, destructive: true, idempotent: false, openWorld: false,
        approval: .confirm)),
  ]

  /// The tools bound to a supervisor, ready to register with a runtime.
  public static func makeTools(supervisor: AgentSupervisor) -> [any AgentTool] {
    definitions.map { definition in
      ClosureTool(definition: definition) { arguments, context in
        guard let pid = context.run.pid else {
          return ToolOutput(
            text: "Error: this run has no process table, so its context cannot be edited.",
            isError: true)
        }
        return await execute(
          name: definition.name,
          arguments: arguments.objectValue ?? [:],
          pid: pid,
          supervisor: supervisor)
      }
    }
  }

  public static func execute(
    name: String,
    arguments: [String: JSONValue],
    pid: AgentPID,
    supervisor: AgentSupervisor
  ) async -> ToolOutput {
    let view = ContextView(messages: await supervisor.transcript(pid))
    switch name {
    case listName:
      return ToolOutput(text: view.listing)
    case removeName:
      guard let selector = arguments["messages"]?.coercedStringValue,
        !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return error("messages is required.")
      }
      let selection: [Int]
      do {
        selection = try view.select(selector)
      } catch {
        return self.error(error.localizedDescription)
      }
      let edit = AgentTranscriptEdit.remove(messageIDs: view.ids(selection))
      let preview = AgentTranscriptEditor.apply([edit], to: view.messages).report
      await supervisor.post(edit: edit, to: pid)
      return ToolOutput(
        text:
          "Before your next turn: \(preview.summary). Tool calls and their results go together, so linked messages are included."
      )
    case rewriteName:
      guard let number = arguments["message"]?.intValue else {
        return error("message is required.")
      }
      guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
        return error("text is required.")
      }
      let selection: [Int]
      do {
        selection = try view.select(String(number))
      } catch {
        return self.error(error.localizedDescription)
      }
      guard let index = selection.first else { return error("No such message.") }
      await supervisor.post(edit: .rewrite(messageID: view.messages[index].id, text: text), to: pid)
      return ToolOutput(text: "Before your next turn: message #\(number) is rewritten (\(text.count) chars).")
    case compactName:
      let selector =
        arguments["messages"]?.coercedStringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
      let summary =
        arguments["summary"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let focus = arguments["focus"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let selection: [Int]
      do {
        selection = try view.select(selector.isEmpty ? "all" : selector)
      } catch {
        return self.error(error.localizedDescription)
      }
      let ids = view.ids(selection)
      guard !summary.isEmpty else {
        let size = AgentProcessInfo.compactCount(
          AgentTranscriptEditor.characterCount(of: selection.map { view.messages[$0] }))
        await supervisor.post(edit: .summarize(messageIDs: ids, focus: focus), to: pid)
        return ToolOutput(
          text:
            "Before your next turn: \(selection.count) message\(selection.count == 1 ? "" : "s") (\(size) chars) are summarized by the model and replaced with the summary\(focus.isEmpty ? "" : ", keeping: \(focus)")."
        )
      }
      let edit = AgentTranscriptEdit.compact(messageIDs: ids, summary: summary)
      let preview = AgentTranscriptEditor.apply([edit], to: view.messages).report
      await supervisor.post(edit: edit, to: pid)
      return ToolOutput(text: "Before your next turn: \(preview.summary).")
    default:
      return error("unknown context tool '\(name)'.")
    }
  }

  private static func error(_ message: String) -> ToolOutput {
    ToolOutput(text: "Error: \(message)", isError: true)
  }

  /// The transcript as the tools number it (from 1), with what may not be
  /// touched: the system prompt at the top, the latest user prompt, and the
  /// turn being produced.
  struct ContextView {
    let messages: [AgentMessage]
    /// Why an index is out of reach, for the ones that are.
    let protected: [Int: String]
    let currentTurnStart: Int?

    init(messages: [AgentMessage]) {
      self.messages = messages
      var protected: [Int: String] = [:]
      if messages.first?.role == .system { protected[0] = "system prompt" }
      let currentTurn = messages.lastIndex { $0.role == .assistant }
      if let currentTurn {
        for index in currentTurn..<messages.count { protected[index] = "turn in progress" }
      }
      if let latestUser = messages.lastIndex(where: { $0.role == .user }),
        protected[latestUser] == nil
      {
        protected[latestUser] = "latest user prompt"
      }
      self.protected = protected
      currentTurnStart = currentTurn
    }

    /// The indexes an edit may act on, in order.
    var editable: [Int] { messages.indices.filter { protected[$0] == nil } }

    func ids(_ indexes: [Int]) -> [String] {
      indexes.map { messages[$0].id }
    }

    /// Zero-based indexes for a selector, refusing protected messages.
    func select(_ selector: String) throws -> [Int] {
      let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if trimmed == "all" {
        let all = editable
        guard !all.isEmpty else { throw ContextSelectionError.nothingEditable }
        return all
      }
      if trimmed.hasPrefix("last") {
        let digits = trimmed.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " :-"))
        guard let count = digits.isEmpty ? 1 : Int(digits), count >= 1 else {
          throw ContextSelectionError.invalidSelector(trimmed)
        }
        let all = editable
        guard !all.isEmpty else { throw ContextSelectionError.nothingEditable }
        return Array(all.suffix(count))
      }
      var indexes: [Int] = []
      for piece in trimmed.split(separator: ",") {
        let part = piece.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        let bounds = part.split(separator: "-", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        guard let lower = Int(bounds.first ?? ""), let upper = Int(bounds.last ?? ""), lower >= 1,
          upper >= lower
        else { throw ContextSelectionError.invalidSelector(part) }
        for number in lower...upper {
          let index = number - 1
          guard messages.indices.contains(index) else {
            throw ContextSelectionError.outOfRange(number, messages.count)
          }
          if let label = protected[index] {
            throw ContextSelectionError.protected(number, label)
          }
          if !indexes.contains(index) { indexes.append(index) }
        }
      }
      guard !indexes.isEmpty else { throw ContextSelectionError.invalidSelector(trimmed) }
      return indexes.sorted()
    }

    var listing: String {
      let total = AgentTranscriptEditor.characterCount(of: messages)
      var lines = [
        "Context: \(messages.count) message\(messages.count == 1 ? "" : "s"), ~\(AgentProcessInfo.compactCount(total)) chars (~\(AgentProcessInfo.compactCount(total / 4)) tokens)"
      ]
      for (index, message) in messages.enumerated() {
        let size = AgentProcessInfo.compactCount(AgentTranscriptEditor.characterCount(of: message))
        let note = protected[index].map { "  [\($0), kept]" } ?? ""
        lines.append("#\(index + 1) \(message.role.rawValue) \(size) chars: \(Self.preview(message))\(note)")
      }
      let count = editable.count
      lines.append(
        "Numbers are what context_remove, context_rewrite, and context_compact take; \"last N\" and \"all\" choose among the \(count) editable message\(count == 1 ? "" : "s"). Edits apply before your next turn."
      )
      return lines.joined(separator: "\n")
    }

    private static func preview(_ message: AgentMessage) -> String {
      var pieces: [String] = []
      for part in message.content {
        switch part {
        case .text(let text): pieces.append(text)
        case .reasoning: pieces.append("(reasoning)")
        case .toolCall(let call): pieces.append("→ \(call.name) \(call.arguments.compactJSONString)")
        case .toolResult(let result): pieces.append("← \(result.isError ? "error" : "result"): \(result.text)")
        case .image(let image): pieces.append("(image \(image.name ?? image.mimeType))")
        case .file(let file): pieces.append("(file \(file.name))")
        case .audio: pieces.append("(audio)")
        case .resource(let resource): pieces.append("(resource \(resource.uri))")
        }
      }
      return AgentProcessInfo.oneLine(pieces.joined(separator: " "), limit: previewLength)
    }
  }

  enum ContextSelectionError: LocalizedError {
    case invalidSelector(String)
    case outOfRange(Int, Int)
    case protected(Int, String)
    case nothingEditable

    var errorDescription: String? {
      switch self {
      case .invalidSelector(let text):
        "'\(text)' is not a message number, list, range, \"last N\", or \"all\"; context_list shows the numbers."
      case .outOfRange(let number, let count):
        "there is no message #\(number); the conversation has \(count)."
      case .protected(let number, let label):
        "message #\(number) cannot be changed: it is the \(label)."
      case .nothingEditable:
        "nothing can be changed: only the system prompt, the latest user prompt, and the turn in progress are left."
      }
    }
  }
}
