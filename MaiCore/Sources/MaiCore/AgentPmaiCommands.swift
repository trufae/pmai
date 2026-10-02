import Foundation

/// Runs pmai's own slash commands for the `pmai_run` and `pmai_help` tools.
///
/// The tools live in MaiCore so every host can offer them, but the commands
/// belong to the REPL that owns the session, the configuration and the MCP
/// catalogs. A host installs a runner while it holds those; without one the
/// tools say so instead of pretending to have run something.
public actor PmaiCommandHost {
  /// Runs one command line — `/set effort high`, `/mcp list` — and returns
  /// what it printed, the way the person would have seen it.
  public typealias Runner = @Sendable (String) async throws -> String

  public static let shared = PmaiCommandHost()

  private var runner: Runner?

  public init() {}

  /// The host's runner, or nil to take the tools out of service — used when a
  /// REPL ends so nothing keeps its commands alive afterwards.
  public func install(runner: Runner?) {
    self.runner = runner
  }

  public func run(_ command: String) async throws -> String {
    guard let runner else { throw PmaiCommandError.noRunner }
    return try await runner(command)
  }
}

public enum PmaiCommandError: LocalizedError, Equatable {
  /// No host has installed a runner, so there is nothing to run a command on.
  case noRunner
  /// The loop never handed over a session, so there is no state to change.
  case noSession
  case notACommand
  case blocked(String)
  case notReadOnly(String)

  public var errorDescription: String? {
    switch self {
    case .noRunner:
      return
        "This host does not run pmai commands, so pmai_run has nothing to call. "
        + "Ask the person to type the command at the pmai prompt."
    case .noSession:
      return
        "No pmai session is running, so there are no commands to run right now. "
        + "Ask the person to type the command at the pmai prompt."
    case .notACommand:
      return
        "A pmai command starts with a slash, as it does at the prompt: "
        + "/set, /mcp list, /theme use NAME. Use pmai_help for what each one takes."
    case .blocked(let name):
      return
        "'\(name)' is blocked for pmai_run. Ask the person to run it themselves, "
        + "or to widen the list with: /tools set pmai blockedCommands \"...\""
    case .notReadOnly(let name):
      return
        "'\(name)' is not read-only and this pmai_run is limited to reading. "
        + "Ask the person to run it themselves, or to widen the list with: "
        + "/tools set pmai readOnlyCommands \"...\""
    }
  }
}

/// What `pmai_run` is allowed to run.
///
/// Nothing here enumerates the REPL's commands. The policy is a blocklist and,
/// for an install that only wants reading, an allowlist — so a command added to
/// the REPL is allowed the moment it exists, and the settings decide the edges
/// instead of a list kept in this file that would go stale.
///
/// Each entry of either list is a command name, or a regular expression when it
/// is written between slashes (`/^\\/(export|import)/`). Lists are separated by
/// spaces, commas, or newlines.
public struct PmaiCommandPolicy: Equatable, Sendable {
  public static let blockedCommandsOption = "blockedCommands"
  public static let readOnlyOption = "readOnly"
  public static let readOnlyCommandsOption = "readOnlyCommands"

  /// Commands that cannot run away from the prompt: two end the session, two
  /// take the terminal over, and two queue something only the prompt holds.
  public static let defaultBlockedCommands = "exit quit clear visual image attach"
  /// Commands that answer with what they are rather than changing it.
  public static let defaultReadOnlyCommands =
    "help set models providers tools mcp mcps agents agent theme prompts skills memory todo stats version cwd"

  public var blockedCommands: String
  public var readOnly: Bool
  public var readOnlyCommands: String

  public init(
    blockedCommands: String = PmaiCommandPolicy.defaultBlockedCommands,
    readOnly: Bool = false,
    readOnlyCommands: String = PmaiCommandPolicy.defaultReadOnlyCommands
  ) {
    self.blockedCommands = blockedCommands
    self.readOnly = readOnly
    self.readOnlyCommands = readOnlyCommands
  }

  /// Reads the three settings from a tool group's options, then from the
  /// environment, so a packaged install can pin them without editing a config.
  public init(options: [String: JSONValue], environment: [String: String] = [:]) {
    func text(_ option: String, _ name: String, _ fallback: String) -> String {
      options[option]?.stringValue ?? environment[name] ?? fallback
    }
    self.init(
      blockedCommands: text(
        Self.blockedCommandsOption, "PMAI_COMMANDS_BLOCKED", Self.defaultBlockedCommands),
      readOnly: options[Self.readOnlyOption]?.boolValue
        ?? (environment["PMAI_COMMANDS_READONLY"] != nil),
      readOnlyCommands: text(
        Self.readOnlyCommandsOption, "PMAI_COMMANDS_READONLY_COMMANDS",
        Self.defaultReadOnlyCommands))
  }

  /// The command as it should run, or the reason it may not.
  public func evaluate(_ input: String) throws -> String {
    let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let head = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    guard head.hasPrefix("/"), head.count > 1 else { throw PmaiCommandError.notACommand }
    let name = String(head.dropFirst())
    guard !matches(blockedCommands, name: name, line: line) else {
      throw PmaiCommandError.blocked(name)
    }
    guard readOnly else { return line }
    guard matches(readOnlyCommands, name: name, line: line) else {
      throw PmaiCommandError.notReadOnly(name)
    }
    return line
  }

  /// One line saying what this policy allows and how it was set, for the help
  /// tool and for `/tools show pmai`.
  public var summary: String {
    let blocked = Self.entries(blockedCommands)
    return
      "\(readOnly ? "read-only" : "read and change") · blocked: "
      + (blocked.isEmpty ? "nothing" : blocked.joined(separator: " "))
      + " · read-only allowlist: \(Self.entries(readOnlyCommands).joined(separator: " "))"
  }

  private func matches(_ list: String, name: String, line: String) -> Bool {
    Self.entries(list).contains { entry in
      if entry.count > 2, entry.hasPrefix("/"), entry.hasSuffix("/"),
        let pattern = try? NSRegularExpression(pattern: String(entry.dropFirst().dropLast()))
      {
        return pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
      }
      return entry.caseInsensitiveCompare(name) == .orderedSame
        || entry.caseInsensitiveCompare("/" + name) == .orderedSame
    }
  }

  public static func entries(_ list: String) -> [String] {
    list.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
      .filter { !$0.isEmpty }
  }
}

/// The `pmai` tool group: the two tools that run pmai's own commands, and the
/// settings that decide which ones they may.
public enum MaiPmaiCommands {
  public static let runToolName = "pmai_run"
  public static let helpToolName = "pmai_help"
  public static var toolNames: Set<String> { [runToolName, helpToolName] }

  public static func makeTools(
    policy: PmaiCommandPolicy, host: PmaiCommandHost = .shared
  ) -> [any AgentTool] {
    [MaiPmaiRunTool(policy: policy, host: host), MaiPmaiHelpTool(policy: policy, host: host)]
  }

  public static func group(policy: PmaiCommandPolicy) -> ToolGroupDefinition {
    ToolGroupDefinition(
      id: "pmai",
      displayName: "pmai commands",
      description:
        "Run pmai's own slash commands — the ones the person types at the prompt — and read back "
        + "what they printed. pmai_run runs one (`/set tool.aproval smart`, `/mcp add …`, "
        + "`/model gpt-5`, `/theme use NAME`, `/tools enable …`); pmai_help returns a command's "
        + "usage without running it. Use them to read and change this installation. Ask the person "
        + "before running one that changes something, and check pmai_help first when unsure of the "
        + "syntax. Every call needs approval.",
      toolNames: toolNames,
      options: [
        .init(
          id: PmaiCommandPolicy.blockedCommandsOption,
          label: "Blocked commands",
          help:
            "Commands pmai_run refuses, as names or as /regex/. The default holds back the few that "
            + "cannot work away from the prompt. Empty allows everything.",
          defaultValue: .string(PmaiCommandPolicy.defaultBlockedCommands)),
        .init(
          id: PmaiCommandPolicy.readOnlyOption,
          label: "Read-only",
          help: "When on, pmai_run only runs the commands in the allowlist below.",
          kind: .boolean,
          defaultValue: .bool(false)),
        .init(
          id: PmaiCommandPolicy.readOnlyCommandsOption,
          label: "Read-only allowlist",
          help: "The commands a read-only pmai_run may run, as names or as /regex/.",
          defaultValue: .string(PmaiCommandPolicy.defaultReadOnlyCommands)),
      ])
  }
}

/// One pmai command, run on the host and reported back.
public struct MaiPmaiRunTool: AgentTool {
  public let definition: ToolDefinition
  private let policy: PmaiCommandPolicy
  private let host: PmaiCommandHost

  /// `host` is the running REPL's host; it defaults to the process-wide one a
  /// CLI installs, and a test passes its own so two do not share a runner.
  public init(policy: PmaiCommandPolicy, host: PmaiCommandHost = .shared) {
    self.policy = policy
    self.host = host
    let scope =
      policy.readOnly
      ? "This pmai_run only reads: it may run "
        + "\(PmaiCommandPolicy.entries(policy.readOnlyCommands).joined(separator: ", ")). "
      : ""
    definition = ToolDefinition(
      name: MaiPmaiCommands.runToolName,
      description:
        "Run one of pmai's own slash commands and return what it printed — the same command the "
        + "person types at the pmai prompt, including its leading slash. Use it to read and change "
        + "this installation: /set for settings (effort, limits, tool approval, colors), /models "
        + "and /model for the model, /providers and /provider for chat providers and their base "
        + "URLs, /tools for which tools an agent may call, /mcp to list, add or enable MCP servers, "
        + "/theme to list, apply or save a color theme, /agents for agents and subagents, /stats "
        + "for token use. Example: pmai_run with command \"/set tool.aproval smart\". Changes are "
        + "saved and take effect from the next turn, so run one that changes something only after "
        + "the person has asked for it. pmai_help gives a command's exact syntax. " + scope,
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "command": .object([
            "type": .string("string"),
            "description": .string(
              "The command with its leading slash and arguments, such as \"/mcp list\" or "
                + "\"/set effort high\"."),
          ])
        ]),
        "required": .array([.string("command")]),
        "additionalProperties": .bool(false),
      ]),
      annotations: ToolAnnotations(
        readOnly: false,
        destructive: false,
        idempotent: false,
        openWorld: false,
        approval: .confirm))
  }

  public func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput {
    let command = try policy.evaluate(arguments.objectValue?["command"]?.stringValue ?? "")
    return ToolOutput(text: try await host.run(command))
  }
}

/// What a command takes, without running it. Read-only, so it keeps working
/// when `pmai_run` has been narrowed.
public struct MaiPmaiHelpTool: AgentTool {
  public let definition: ToolDefinition
  private let policy: PmaiCommandPolicy
  private let host: PmaiCommandHost

  /// `host` is the running REPL's host; it defaults to the process-wide one a
  /// CLI installs, and a test passes its own so two do not share a runner.
  public init(policy: PmaiCommandPolicy, host: PmaiCommandHost = .shared) {
    self.policy = policy
    self.host = host
    definition = ToolDefinition(
      name: MaiPmaiCommands.helpToolName,
      description:
        "Help for pmai's own slash commands, the same text `/help TOPIC` prints at the prompt. "
        + "With no topic it lists every command; with a topic it gives that command's syntax — "
        + "set, theme, tools, mcp, agents, prompts, skills, memory, todo, chat, edit, queue, "
        + "export, import, copy, stats. Call this before pmai_run whenever the arguments are "
        + "unclear; it changes nothing.",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "topic": .object([
            "type": .string("string"),
            "description": .string(
              "The command to explain, without its slash: \"set\", \"mcp\", \"theme\". Empty "
                + "lists every command."),
          ])
        ]),
        "required": .array([]),
        "additionalProperties": .bool(false),
      ]),
      annotations: ToolAnnotations(
        readOnly: true,
        destructive: false,
        idempotent: true,
        openWorld: false,
        approval: .automatic))
  }

  public func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput {
    let topic = (arguments.objectValue?["topic"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // The topic is only ever handed to /help, so it needs no escaping of its
    // own beyond the trim; /help answers an unknown topic with the list.
    let command = try policy.evaluate(topic.isEmpty ? "/help" : "/help \(topic)")
    return ToolOutput(text: try await host.run(command))
  }
}
