import Foundation

/// Where an agent's tool calls actually happen.
///
/// `inline` lets the agent call tools in its own transcript. An explicitly
/// enabled agents group also lets it start workers. `subagent` additionally
/// enables workers for legacy requests without explicit tool groups, so bulky work can be sent one level down to a child whose
/// transcript is thrown away — the parent's context grows by one answer
/// instead of by a call and a result for every step. It costs four schemas
/// on every call, so it pays only when a task's tool output is large.
public enum AgentToolDelegation: String, Codable, Equatable, Sendable {
  case inline
  case subagent

  public var delegatesTools: Bool { self == .subagent }
}

/// The three things a child agent needs, kept apart on purpose.
///
/// A model fills three labelled slots more reliably than it writes a
/// well-structured brief, and keeping them separate lets the host render them
/// through a template it controls.
public struct AgentTaskBrief: Codable, Equatable, Sendable {
  /// What the child must know and cannot discover: facts already established,
  /// decisions already made, paths already found.
  public var context: String
  /// The single thing to do.
  public var task: String
  /// What to return, and in what shape. The parent is the consumer, so the
  /// parent writes the contract.
  public var output: String

  public init(context: String = "", task: String, output: String = "") {
    self.context = context.trimmingCharacters(in: .whitespacesAndNewlines)
    self.task = task.trimmingCharacters(in: .whitespacesAndNewlines)
    self.output = output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public init?(arguments: [String: JSONValue]) {
    let task = arguments["task"]?.coercedStringValue ?? ""
    guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    self.init(
      context: arguments["context"]?.coercedStringValue ?? "",
      task: task,
      output: arguments["output"]?.coercedStringValue ?? "")
  }

  /// A short label for process listings.
  public var headline: String {
    AgentProcessInfo.oneLine(task, limit: 60)
  }
}

/// Renders a brief into the prompt a child agent actually receives, and holds
/// the built-in instructions a derived worker runs with. Both templates are
/// overridable per installation through `ConfiguredPrompts`, so pmai, PocketMai,
/// and any other host produce identical child prompts.
public enum AgentDelegationPrompt {
  public static let contextPlaceholder = "{{context}}"
  public static let taskPlaceholder = "{{task}}"
  public static let outputPlaceholder = "{{output}}"
  public static let agentPlaceholder = "{{agent}}"
  public static let workingDirectoryPlaceholder = "{{cwd}}"

  /// Substituted for an empty `context`, so the section never reads as an
  /// oversight the child should ask about.
  public static let emptyContext = "Nothing beyond this brief."
  /// Substituted for an empty `output`, which the tool schema discourages but
  /// text-protocol providers can still produce.
  public static let emptyOutput = "A direct answer to the task, and nothing else."

  public static let template = """
    ## Context

    {{context}}

    ## Task

    {{task}}

    ## Expected output

    {{output}}

    You are running as agent '{{agent}}' in {{cwd}}. You cannot see the \
    conversation that produced this brief; everything you need is above. Do the \
    task, then answer with exactly what "Expected output" asks for — no \
    preamble, no restating the task, no account of the steps you took.
    """

  /// Instructions for the worker MaiCore derives when a delegating agent does
  /// not name a child definition.
  public static let workerInstructions = """
    You are a focused worker agent. You receive one brief: context, a task, and \
    an expected output. Use your tools to complete the task, then reply with \
    exactly the expected output and nothing else. Do not ask questions and do \
    not report progress; if something needed is missing, do what you can and \
    say what was missing as part of the output.
    Search or inspect an index before reading large sources. Read only relevant \
    ranges and follow pagination when needed; a partial page is not the complete \
    source. Keep raw data in this worker and return concise findings with source \
    locations, unless the brief explicitly asks for the data itself.
    """

  public static func render(
    _ brief: AgentTaskBrief,
    agent: String,
    workingDirectory: String,
    template: String? = nil
  ) -> String {
    let source = template?.trimmingCharacters(in: .whitespacesAndNewlines)
    var text = (source?.isEmpty == false ? source! : Self.template)
    text = text.replacingOccurrences(
      of: contextPlaceholder, with: brief.context.isEmpty ? emptyContext : brief.context)
    text = text.replacingOccurrences(of: taskPlaceholder, with: brief.task)
    text = text.replacingOccurrences(
      of: outputPlaceholder, with: brief.output.isEmpty ? emptyOutput : brief.output)
    text = text.replacingOccurrences(of: agentPlaceholder, with: agent)
    text = text.replacingOccurrences(
      of: workingDirectoryPlaceholder,
      with: workingDirectory.isEmpty ? "an unspecified directory" : workingDirectory)
    return text
  }

  /// The placeholder a custom template must keep, or nil when it is usable.
  /// A template that drops `{{task}}` sends children an empty assignment.
  public static func missingPlaceholder(in template: String) -> String? {
    let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.contains(taskPlaceholder) ? nil : taskPlaceholder
  }
}
