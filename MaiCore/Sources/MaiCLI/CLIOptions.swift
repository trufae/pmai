import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Swift discovers argv from the initial process stack on ELF targets. The
/// Play Store build of Termux preserves argv[0], inserts the executable at
/// argv[1], and starts Android's linker. Bionic skips the preserved argv[0]
/// before calling C main, but Swift still finds it on the initial stack.
func platformCommandLineArguments(environment: [String: String]) -> [String] {
  var arguments = CommandLine.arguments
  #if canImport(Android)
    guard arguments.count >= 2 else { return arguments }

    if environment["TERMUX_EXEC__PROC_SELF_EXE"] != nil {
      arguments.removeFirst()
    } else {
      // Also support invoking the Android linker explicitly, outside the
      // termux-exec wrapper.
      let first = URL(fileURLWithPath: arguments[0]).lastPathComponent
      if first == "linker" || first == "linker64" {
        arguments.removeFirst()
      }
    }
  #endif
  return arguments
}

struct CLIOptions {
  var configPath: String?
  /// Root holding the project index and shared state; nil follows PMAI_HOME or ~/.pmai.
  var homePath: String?
  /// Directory holding this project's chat files; nil uses .pmai/chats in the project.
  var statePath: String?
  var historyPath: String?
  var agentOverride: String?
  var providerOverride: ProviderID?
  var modelOverride: String?
  var compactAgent: String?
  var toolAgent: String?
  var effortOverride: String?
  var saveDefaults = false
  var baseURLOverride: URL?
  var apiKeyOverride: String?
  var systemOverride: String?
  var maxToolCalls: Int?
  var maxModelTurns: Int?
  var maxSubagents: Int?
  var stream = true
  /// Override the project approval policy for this process.
  var approvalMode: ToolApprovalMode?
  /// Reopen the most recently updated chat instead of starting a fresh one.
  var resume = false
  /// A chat list index, UUID prefix, or title to reopen.
  var resumeSelector: String?
  /// Render replies as markdown; nil follows the configuration and the tty.
  var markdown: Bool?
  var imagePaths: [String] = []
  /// Attach what arrives on standard input as a text file, for one-liners
  /// such as `git diff | pmai --stdin "review this"`.
  var readStdin = false
  var pluginPaths: [String] = []
  var initialPrompt: String?
  var printConfig = false
  var editConfig = false
  var update = false
  var vimAction: VimIntegration.Action?
  var vimDirectory: String?
  /// List every known project and exit.
  var listProjects = false
  /// List this project's saved chats and exit.
  var listChats = false
  /// Serve one protocol on stdio instead of the REPL.
  var serve: ServeMode?
  var acpRoot: String?
  var acpPaths: [String] = []
  var acpSessionDirectory: String?
  var tailcatGateway: String?

  init(arguments: [String], environment: [String: String]) throws {
    configPath = environment["PMAI_CONFIG"]
    statePath = environment["PMAI_STATE"]
    historyPath = environment["PMAI_HISTORY"]
    var positional: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--config":
        configPath = try Self.value(after: argument, in: arguments, index: &index)
      case "--state":
        statePath = try Self.value(after: argument, in: arguments, index: &index)
      case "--history":
        historyPath = try Self.value(after: argument, in: arguments, index: &index)
      case "--home":
        homePath = try Self.value(after: argument, in: arguments, index: &index)
      case "--projects":
        listProjects = true
      case "-l", "--list":
        listChats = true
      case "--agent":
        agentOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--provider":
        providerOverride = ProviderID(try Self.value(after: argument, in: arguments, index: &index))
      case "-m", "--model":
        modelOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "-b", "--base-url":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        guard let url = URL(string: value),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else { throw CLIError.invalidURL(value) }
        baseURLOverride = url
      case "--compact-agent", "--compact-model":
        compactAgent = try Self.value(after: argument, in: arguments, index: &index)
      case "--tool-agent", "--tool-model":
        toolAgent = try Self.value(after: argument, in: arguments, index: &index)
      case "--effort":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        guard let effort = ReasoningEffort(name: value) else {
          throw CLIError.unknownOption("effort: \(value)")
        }
        effortOverride = effort.rawValue
      case "--save-defaults":
        saveDefaults = true
      case "--api-key":
        apiKeyOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--system":
        systemOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--max-tool-calls":
        maxToolCalls = try Self.count(after: argument, in: arguments, index: &index)
      case "--max-turns", "--max-model-turns":
        maxModelTurns = try Self.count(after: argument, in: arguments, index: &index)
      case "--max-subagents":
        maxSubagents = try Self.count(after: argument, in: arguments, index: &index)
      case "--image":
        imagePaths.append(try Self.value(after: argument, in: arguments, index: &index))
      case "--stdin":
        readStdin = true
      case "--plugin":
        pluginPaths.append(try Self.value(after: argument, in: arguments, index: &index))
      case "--no-stream":
        stream = false
      case "--tool-approval", "--tool-aproval":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        guard let mode = ToolApprovalMode(rawValue: value) else {
          throw CLIError.unknownOption("--tool-approval expects yolo, ask, or smart")
        }
        approvalMode = mode
      case "-r", "--resume", "--continue":
        resume = true
        if index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("-") || Int(arguments[index + 1]) != nil
        {
          index += 1
          resumeSelector = arguments[index]
        }
      case "--markdown":
        markdown = true
      case "--no-markdown":
        markdown = false
      case "--print-config":
        printConfig = true
      case "-E":
        editConfig = true
      case "-U", "--update":
        update = true
      case "--vim":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        guard let action = VimIntegration.Action(rawValue: value) else {
          throw CLIError.unknownOption("--vim expects install, update, or uninstall")
        }
        vimAction = action
      case "--vim-dir":
        vimDirectory = try Self.value(after: argument, in: arguments, index: &index)
      case "--acp-root":
        acpRoot = try Self.value(after: argument, in: arguments, index: &index)
      case "--acp-path":
        acpPaths.append(try Self.value(after: argument, in: arguments, index: &index))
      case "--acp-sessions":
        acpSessionDirectory = try Self.value(after: argument, in: arguments, index: &index)
      case "--tailcat-gateway":
        tailcatGateway = try Self.value(after: argument, in: arguments, index: &index)
      case "--acp":
        serve = .acp
      case "--mcp":
        serve = .mcp
      default:
        guard !argument.hasPrefix("-") else { throw CLIError.unknownOption(argument) }
        positional.append(argument)
      }
      index += 1
    }
    if let modelOverride {
      let selection = try ModelSelection(
        modelOverride, currentProvider: providerOverride ?? .openAI)
      if modelOverride.contains("::") { providerOverride = selection.provider }
      self.modelOverride = selection.model
    }
    if !positional.isEmpty { initialPrompt = positional.joined(separator: " ") }
    if readStdin, serve != nil { throw CLIError.stdinServesProtocol }
    if vimDirectory != nil, vimAction == nil {
      throw CLIError.unknownOption("--vim-dir requires --vim")
    }
    if tailcatGateway != nil, serve != .acp { throw CLIError.unknownOption("Tailcat gateway requires --acp") }
  }

  private static func value(
    after option: String,
    in arguments: [String],
    index: inout Int
  ) throws -> String {
    index += 1
    guard index < arguments.count else { throw CLIError.missingValue(option) }
    return arguments[index]
  }

  private static func count(
    after option: String,
    in arguments: [String],
    index: inout Int
  ) throws -> Int {
    let raw = try value(after: option, in: arguments, index: &index)
    guard let count = Int(raw), count >= 0 else { throw CLIError.invalidCount(option, raw) }
    return count
  }

  /// Applies command-line run limits on top of a configured agent.
  func applyLimitOverrides(to limits: inout AgentRunLimits) {
    if let maxToolCalls { limits.maxToolCalls = max(0, maxToolCalls) }
    if let maxModelTurns { limits.maxModelTurns = max(1, maxModelTurns) }
    if let maxSubagents { limits.maxSubagents = max(0, maxSubagents) }
  }

  /// Explicit flags take precedence over both saved chats and launch defaults.
  func applyOverrides(to profile: inout SessionProfile) {
    if let providerOverride { profile.provider = providerOverride }
    if let modelOverride { profile.model = modelOverride }
    if let effortOverride { profile.options.reasoningEffort = effortOverride }
    if let systemOverride {
      profile.instructions = systemOverride
      profile.systemPrompt = nil
    }
    profile.stream = stream && profile.stream
    applyLimitOverrides(to: &profile.limits)
  }
}

/// A protocol pmai speaks over stdio instead of running its REPL.
enum ServeMode: String, Sendable {
  case acp
  case mcp
}

enum CLIError: LocalizedError {
  case invalidURL(String)
  case missingValue(String)
  case unknownOption(String)
  case chatSettingsWhileRunning
  case unknownChat(String)
  case invalidCount(String, String)
  case configNotFound(String)
  case noEditor
  case noProvider
  case noProject
  case invalidImage(String)
  case isDirectory(String)
  case missingFolder(String)
  case stdinServesProtocol
  case stdinWithoutTerminal
  case apiKeySourcesConflict

  var errorDescription: String? {
    switch self {
    case .noProject: "No project is open."
    case .stdinServesProtocol:
      "--stdin cannot be combined with --acp or --mcp: they own standard input."
    case .apiKeySourcesConflict: "Set PMAI_API_KEY or PMAI_API_KEY_FILE, not both."
    case .stdinWithoutTerminal:
      "--stdin was read, but there is no terminal for the REPL; give the message on the command line."
    case .invalidURL(let value): "Invalid URL: \(value)"
    case .missingValue(let option): "Missing value after \(option)."
    case .unknownOption(let option): "Unknown option: \(option)"
    case .chatSettingsWhileRunning:
      "Wait for active agents to finish before switching to a chat with different provider or model settings."
    case .unknownChat(let selector): "No chat matches '\(selector)'. Run pmai -l to list chats."
    case .invalidCount(let option, let value):
      "\(option) expects a non-negative integer, got '\(value)'."
    case .configNotFound(let path): "Configuration file not found: \(path)"
    case .noEditor: "No editor found. Set EDITOR or install vim, nano, or notepad in PATH."
    case .noProvider: "No provider is configured. Start pmai and type /about for setup commands."
    case .invalidImage(let path): "Unable to load image: \(path)"
    case .isDirectory(let path): "\(path) is a folder; give a file name."
    case .missingFolder(let path): "The folder \(path) does not exist; create it first."
    }
  }
}
