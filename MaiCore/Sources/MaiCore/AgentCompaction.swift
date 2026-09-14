import Foundation

/// The prompt that folds a stretch of conversation into durable context.
/// `/chat compact` and the runtime's autocompact both render it, so a summary
/// reads the same however it was asked for. Overridable per installation
/// through `ConfiguredPrompts.compact`, like the delegation and memory prompts.
public enum AgentCompactionPrompt {
  public static let transcriptPlaceholder = "{{transcript}}"
  public static let focusPlaceholder = "{{focus}}"

  public static let template = """
    Compact the transcript below into durable context for continuing the same chat.

    Output only the compacted context. Do not include hidden reasoning, XML tags, prompt scaffolding, or commentary about the task.

    Preserve:
    - User goals, preferences, constraints, and decisions
    - Important names, projects, files, commands, code snippets, errors, and results
    - Current state, unresolved questions, and next steps

    Drop greetings, filler, repeated text, tool protocol blocks, and implementation details that no longer matter. Write concise bullets grouped by topic when useful.
    {{focus}}

    Transcript:

    {{transcript}}
    """

  /// The focus autocompact supplies: the run is in the middle of a task and
  /// what matters is whatever lets it finish without starting over.
  public static let automaticFocus = """
    This compaction runs automatically in the middle of a task the assistant is still working on. Keep everything needed to finish it without re-reading: the goal as the user stated it, decisions and constraints, what has been done and what remains, the files, paths, commands, identifiers, and values found so far, and every error or result that is still relevant. Leave out tool protocol details and outputs that later steps superseded.
    """

  /// Renders the template with a transcript and an optional focus. A custom
  /// template without `{{focus}}` gets the focus appended, so guidance is
  /// never silently dropped.
  public static func render(
    transcript: String,
    focus: String = "",
    template: String? = nil
  ) -> String {
    let source = template?.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = source?.isEmpty == false ? source! : Self.template
    let focusInstructions =
      focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? ""
      : """
      The user supplied this focus for compaction:

      <compaction-focus>
      \(focus.trimmingCharacters(in: .whitespacesAndNewlines))
      </compaction-focus>

      Prioritize context relevant to that focus while retaining essential state needed to continue the work.
      """
    var prompt = text.replacingOccurrences(of: focusPlaceholder, with: focusInstructions)
    prompt = prompt.replacingOccurrences(of: transcriptPlaceholder, with: transcript)
    if !focusInstructions.isEmpty, !text.contains(focusPlaceholder) {
      prompt += "\n\n" + focusInstructions
    }
    return prompt
  }

  /// The transcript the template is given. Prose travels whole; a tool call
  /// is one line of name and arguments; a tool result is cut to `resultLimit`
  /// characters, since what the model did with it is in the prose that
  /// follows. System messages are not included: the instructions survive
  /// compaction as they are.
  public static func transcript(of messages: [AgentMessage], resultLimit: Int = 4_000) -> String {
    var entries: [String] = []
    for message in messages {
      switch message.role {
      case .system, .developer:
        continue
      case .user, .assistant, .tool:
        break
      }
      var lines: [String] = []
      let prose = MessageContentFilter.textWithoutReasoning(from: message.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !prose.isEmpty, message.role != .tool { lines.append(prose) }
      for part in message.content {
        switch part {
        case .toolCall(let call):
          lines.append("[tool call \(call.name) \(call.arguments.compactJSONString)]")
        case .toolResult(let result):
          let status = result.isError ? " error" : ""
          let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
          lines.append(
            text.isEmpty ? "[tool result\(status)]" : "[tool result\(status)] \(truncated(text, limit: resultLimit))")
        case .file(let file) where file.text != nil:
          lines.append("[file \(file.name)] \(truncated(file.text ?? "", limit: resultLimit))")
        case .file(let file):
          lines.append("[file \(file.name)]")
        case .image(let image):
          lines.append("[image \(image.name ?? image.mimeType)]")
        default:
          continue
        }
      }
      guard !lines.isEmpty else { continue }
      let label =
        switch message.role {
        case .user: "User"
        case .assistant: "Assistant"
        default: "Tool"
        }
      entries.append("\(label):\n" + lines.joined(separator: "\n"))
    }
    return entries.joined(separator: "\n\n---\n\n")
  }

  /// The placeholder a custom template must keep, or nil when it is usable.
  public static func missingPlaceholder(in template: String) -> String? {
    let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.contains(transcriptPlaceholder) ? nil : transcriptPlaceholder
  }

  private static func truncated(_ text: String, limit: Int) -> String {
    guard limit > 0, text.count > limit else { return text }
    return text.prefix(limit) + "\n[... truncated, \(text.count - limit) characters omitted ...]"
  }
}

/// How the runtime decides that a conversation needs compacting and which
/// part of it to fold. Everything but the system prompt and the newest
/// exchange — the reply the model is about to act on and the tool results it
/// has not seen yet — is fair game.
public enum AgentAutocompaction {
  /// The smallest stretch worth summarizing: one message would only be
  /// rewritten, and a summary of a summary gains nothing.
  static let minimumMessages = 2

  /// How much of the transcript's text the compactable stretch must hold
  /// before a summary is attempted. Below this the bulk is in the newest
  /// exchange, which cannot be folded yet; the next turn will move it into
  /// reach.
  static let minimumShare = 0.3

  /// What the conversation is estimated to cost the model next turn. The
  /// provider's own count from the last call is exact for the messages it
  /// saw; the character estimate covers what was appended since, and stands
  /// in entirely when the provider reports nothing.
  public static func estimatedTokens(of messages: [AgentMessage], lastUsage: TokenUsage?) -> Int {
    let estimated = ModelCallStats.estimatedTokenCount(
      forCharacterCount: AgentTranscriptEditor.characterCount(of: messages))
    guard let lastUsage else { return estimated }
    return max(estimated, lastUsage.inputTokens + lastUsage.outputTokens)
  }

  /// The IDs of the messages to fold into one summary, or nil when there is
  /// too little to gain.
  public static func selection(in messages: [AgentMessage]) -> [String]? {
    guard let tailStart = messages.lastIndex(where: { $0.role == .user || $0.role == .assistant })
    else { return nil }
    let candidates = messages[..<tailStart].filter { $0.role != .system && $0.role != .developer }
    guard candidates.count >= minimumMessages else { return nil }
    let total = AgentTranscriptEditor.characterCount(of: messages)
    let compactable = AgentTranscriptEditor.characterCount(of: Array(candidates))
    guard total == 0 || Double(compactable) / Double(total) >= minimumShare else { return nil }
    return candidates.map(\.id)
  }
}

/// The cheap half of keeping a conversation small: files read while answering
/// an earlier prompt have been acted on, so their bodies are replaced with a
/// line that says what was there and how to get it back. Runs in
/// `AgentContextMode.size` before each model call.
///
/// Everything read for the prompt in progress stays. Pruning inside a run was
/// measured to cost more than it saved: a model asked to describe four files
/// re-read the ones already collapsed when it came to write the answer
/// (10 calls and 27k tokens instead of 7 and 18k).
public enum AgentContextPruning {
  /// Bodies shorter than this are left alone; the reference would not be smaller.
  public static let minimumCharacters = 400

  public static func prune(_ messages: inout [AgentMessage]) -> AgentTranscriptEditReport? {
    guard let currentPrompt = messages.lastIndex(where: { $0.role == .user }) else { return nil }
    var candidates: [Int] = []
    for (index, message) in messages.enumerated()
    where index < currentPrompt && message.role == .tool {
      if message.toolResults.contains(where: { hasPrunableContent($0) }) { candidates.append(index) }
    }
    guard !candidates.isEmpty else { return nil }
    var report = AgentTranscriptEditReport(
      charactersBefore: AgentTranscriptEditor.characterCount(of: messages))
    for index in candidates {
      var message = messages[index]
      message.content = message.content.map { part in
        guard case .toolResult(var result) = part, hasPrunableContent(result) else { return part }
        let path = result.structuredContent?.objectValue?["path"]?.stringValue
        let sourceID = result.structuredContent?.objectValue?["source_id"]?.stringValue
        let offset = result.structuredContent?.objectValue?["offset"]?.intValue ?? 0
        result.content = result.content.map { inner in
          if case .resource(let resource) = inner, let sourceID,
            let text = resource.text, text.count >= minimumCharacters {
            return .text(
              "[Web source body read earlier and removed from context; call web_fetch with source_id \(sourceID) and offset \(offset), or query it. If evicted, fetch \(resource.uri) again.]"
            )
          }
          guard case .file(let file) = inner, let text = file.text,
            text.count >= minimumCharacters
          else { return inner }
          let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
          return .text(
            "[\(path ?? file.name): \(lines) lines, \(text.count) characters, read earlier and removed from the context; call files_read again if needed]"
          )
        }
        report.rewritten += 1
        return .toolResult(result)
      }
      messages[index] = message
    }
    guard report.rewritten > 0 else { return nil }
    report.charactersAfter = AgentTranscriptEditor.characterCount(of: messages)
    return report
  }

  private static func hasPrunableContent(_ result: ToolResult) -> Bool {
    result.content.contains { part in
      if case .file(let file) = part { return (file.text?.count ?? 0) >= minimumCharacters }
      if case .resource(let resource) = part,
        result.structuredContent?.objectValue?["tool"]?.stringValue == "web_fetch",
        result.structuredContent?.objectValue?["source_id"]?.stringValue != nil {
        return (resource.text?.count ?? 0) >= minimumCharacters
      }
      return false
    }
  }
}
