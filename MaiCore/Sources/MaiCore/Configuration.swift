import Foundation

/// An open-ended configuration discriminator. MaiCore reserves the static
/// values below for its built-in factories; hosts may define any other value.
public struct ConfiguredProviderKind: RawRepresentable, Codable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.init(rawValue: rawValue) }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let hello: ConfiguredProviderKind = "hello"
  public static let openAICompatible: ConfiguredProviderKind = "openAICompatible"
}

public struct ConfiguredProvider: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: ConfiguredProviderKind
  public var displayName: String?
  public var baseURL: URL?
  public var apiKey: String?
  public var apiKeyEnvironment: String?
  /// A file holding the key, for secrets mounted on disk rather than exported
  /// into the environment; read at every use, with surrounding whitespace dropped.
  public var apiKeyFile: String?
  public var headers: [String: String]
  public var headerEnvironment: [String: String]
  public var timeout: TimeInterval?
  /// Provider-specific settings preserved by the shared configuration format.
  public var options: [String: JSONValue]

  public init(
    id: String,
    kind: ConfiguredProviderKind,
    displayName: String? = nil,
    baseURL: URL? = nil,
    apiKey: String? = nil,
    apiKeyEnvironment: String? = nil,
    apiKeyFile: String? = nil,
    headers: [String: String] = [:],
    headerEnvironment: [String: String] = [:],
    timeout: TimeInterval? = nil,
    options: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.displayName = displayName
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.apiKeyEnvironment = apiKeyEnvironment
    self.apiKeyFile = apiKeyFile
    self.headers = headers
    self.headerEnvironment = headerEnvironment
    self.timeout = timeout
    self.options = options
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, displayName, baseURL, apiKey, apiKeyEnvironment, apiKeyFile, headers,
      headerEnvironment, timeout
    case options
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: try container.decode(ConfiguredProviderKind.self, forKey: .kind),
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      baseURL: try container.decodeIfPresent(URL.self, forKey: .baseURL),
      apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey),
      apiKeyEnvironment: try container.decodeIfPresent(String.self, forKey: .apiKeyEnvironment),
      apiKeyFile: try container.decodeIfPresent(String.self, forKey: .apiKeyFile),
      headers: try ProviderHeaders.decode(from: container, forKey: .headers),
      headerEnvironment: try container.decodeIfPresent(
        [String: String].self,
        forKey: .headerEnvironment) ?? [:],
      timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout),
      options: try container.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:])
  }

  public func resolvedHeaders(environment: [String: String]) throws -> [String: String] {
    var resolved = headers
    for (header, environmentName) in headerEnvironment {
      guard let value = environment[environmentName], !value.isEmpty else {
        throw MaiConfigurationError.missingEnvironmentVariable(environmentName)
      }
      resolved[header] = value
    }
    return resolved
  }

  /// The key to send: the environment variable when it is set (empty means
  /// none), else the file when one is named, else the literal.
  public func resolvedAPIKey(environment: [String: String]) throws -> String? {
    if let apiKeyEnvironment, !apiKeyEnvironment.isEmpty, let value = environment[apiKeyEnvironment]
    {
      return value.isEmpty ? nil : value
    }
    if let apiKeyFile, !apiKeyFile.trimmingCharacters(in: .whitespaces).isEmpty {
      let value = try Self.apiKey(fromFile: apiKeyFile)
      return value.isEmpty ? nil : value
    }
    return apiKey
  }

  /// The contents of a key file, trimmed: a trailing newline is the norm.
  public static func apiKey(fromFile path: String) throws -> String {
    let expanded = NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines))
      .expandingTildeInPath
    guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
      throw MaiConfigurationError.unreadableAPIKeyFile(expanded)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct ConfiguredPlugin: Codable, Equatable, Sendable {
  public var path: String
  public var enabled: Bool
  public var required: Bool

  public init(path: String, enabled: Bool = true, required: Bool = true) {
    self.path = path
    self.enabled = enabled
    self.required = required
  }

  private enum CodingKeys: String, CodingKey { case path, enabled, required }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      path: try container.decode(String.self, forKey: .path),
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      required: try container.decodeIfPresent(Bool.self, forKey: .required) ?? true)
  }
}

public struct ConfiguredToolSource: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: String
  public var enabled: Bool
  public var displayName: String?
  public var options: [String: JSONValue]

  public init(
    id: String,
    kind: String,
    enabled: Bool = true,
    displayName: String? = nil,
    options: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.enabled = enabled
    self.displayName = displayName
    self.options = options
  }

  private enum CodingKeys: String, CodingKey { case id, kind, enabled, displayName, options }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: try container.decode(String.self, forKey: .kind),
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      options: try container.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:])
  }

  public func context(environment: [String: String]) -> PluginFactoryContext {
    PluginFactoryContext(
      id: id,
      displayName: displayName,
      options: options,
      environment: environment)
  }
}

public struct ConfiguredOCRProvider: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: String
  public var enabled: Bool
  public var displayName: String?
  public var options: [String: JSONValue]

  public init(
    id: String,
    kind: String,
    enabled: Bool = true,
    displayName: String? = nil,
    options: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.enabled = enabled
    self.displayName = displayName
    self.options = options
  }

  private enum CodingKeys: String, CodingKey { case id, kind, enabled, displayName, options }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: try container.decode(String.self, forKey: .kind),
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      options: try container.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:])
  }

  public func context(environment: [String: String]) -> PluginFactoryContext {
    PluginFactoryContext(
      id: id,
      displayName: displayName,
      options: options,
      environment: environment)
  }
}

public struct ConfiguredMCPServer: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: String
  public var enabled: Bool
  public var displayName: String?
  public var url: URL?
  public var command: String?
  public var args: [String]
  public var env: [String: String]
  public var cwd: String?
  public var headers: [String: String]
  public var headerEnvironment: [String: String]
  public var bearerToken: String?
  public var bearerTokenEnvironment: String?
  public var timeout: TimeInterval?
  public var toolNamePrefix: String?
  public var defaultApproval: ToolApprovalRequirement
  public var options: [String: JSONValue]

  public init(
    id: String,
    kind: String = "streamable-http",
    enabled: Bool = true,
    displayName: String? = nil,
    url: URL? = nil,
    command: String? = nil,
    args: [String] = [],
    env: [String: String] = [:],
    cwd: String? = nil,
    headers: [String: String] = [:],
    headerEnvironment: [String: String] = [:],
    bearerToken: String? = nil,
    bearerTokenEnvironment: String? = nil,
    timeout: TimeInterval? = nil,
    toolNamePrefix: String? = nil,
    defaultApproval: ToolApprovalRequirement = .confirm,
    options: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.enabled = enabled
    self.displayName = displayName
    self.url = url
    self.command = command
    self.args = args
    self.env = env
    self.cwd = cwd
    self.headers = headers
    self.headerEnvironment = headerEnvironment
    self.bearerToken = bearerToken
    self.bearerTokenEnvironment = bearerTokenEnvironment
    self.timeout = timeout
    self.toolNamePrefix = toolNamePrefix
    self.defaultApproval = defaultApproval
    self.options = options
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, enabled, displayName, url, command, args, env, cwd
    case headers, headerEnvironment, bearerToken
    case bearerTokenEnvironment
    case timeout, toolNamePrefix, defaultApproval, options
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let command = try container.decodeIfPresent(String.self, forKey: .command)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: try container.decodeIfPresent(String.self, forKey: .kind)
        ?? (command == nil ? "streamable-http" : "stdio"),
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      url: try container.decodeIfPresent(URL.self, forKey: .url),
      command: command,
      args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
      env: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
      cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
      headers: try ProviderHeaders.decode(from: container, forKey: .headers),
      headerEnvironment: try container.decodeIfPresent(
        [String: String].self,
        forKey: .headerEnvironment) ?? [:],
      bearerToken: try container.decodeIfPresent(String.self, forKey: .bearerToken),
      bearerTokenEnvironment: try container.decodeIfPresent(
        String.self,
        forKey: .bearerTokenEnvironment),
      timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout),
      toolNamePrefix: try container.decodeIfPresent(String.self, forKey: .toolNamePrefix),
      defaultApproval: try container.decodeIfPresent(
        ToolApprovalRequirement.self,
        forKey: .defaultApproval) ?? .confirm,
      options: try container.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:])
  }

  public func resolved(environment: [String: String]) throws -> MCPServerConfiguration {
    guard let url else { throw MaiConfigurationError.mcpServerMissingURL(id) }
    var resolvedHeaders = headers
    for (header, environmentName) in headerEnvironment {
      guard let value = environment[environmentName], !value.isEmpty else {
        throw MaiConfigurationError.missingEnvironmentVariable(environmentName)
      }
      resolvedHeaders[header] = value
    }
    let token: String?
    if let bearerTokenEnvironment, !bearerTokenEnvironment.isEmpty {
      guard let value = environment[bearerTokenEnvironment], !value.isEmpty else {
        throw MaiConfigurationError.missingEnvironmentVariable(bearerTokenEnvironment)
      }
      token = value
    } else {
      token = bearerToken
    }
    if let token, !token.isEmpty {
      resolvedHeaders["Authorization"] = "Bearer \(token)"
    }
    return MCPServerConfiguration(
      id: id,
      displayName: displayName,
      url: url,
      headers: resolvedHeaders,
      timeout: timeout ?? 60,
      toolNamePrefix: toolNamePrefix,
      defaultApproval: defaultApproval)
  }

  #if !os(iOS)
    public func resolvedStdio(environment: [String: String]) throws
      -> MCPStdioServerConfiguration
    {
      let executable = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !executable.isEmpty else {
        throw MaiConfigurationError.mcpServerMissingCommand(id)
      }
      var childEnvironment = environment
      childEnvironment.merge(env) { _, configured in configured }
      let workingDirectory = cwd.flatMap { raw -> URL? in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
      }
      return MCPStdioServerConfiguration(
        id: id,
        displayName: displayName,
        command: executable,
        args: args,
        environment: childEnvironment,
        workingDirectory: workingDirectory,
        timeout: timeout ?? 60,
        toolNamePrefix: toolNamePrefix,
        defaultApproval: defaultApproval)
    }
  #endif
}

public enum ConfiguredApprovalMode: String, Codable, Sendable {
  case ask
  case allow
  case deny
}

public struct ConfiguredApprovals: Codable, Equatable, Sendable {
  public var confirm: ConfiguredApprovalMode
  public var dangerous: ConfiguredApprovalMode
  /// Permits every tool call without asking. The CLI uses this default when
  /// the opened project has no saved `/set yolo` choice.
  public var yolo: Bool

  public init(
    confirm: ConfiguredApprovalMode = .ask,
    dangerous: ConfiguredApprovalMode = .ask,
    yolo: Bool = false
  ) {
    self.confirm = confirm
    self.dangerous = dangerous
    self.yolo = yolo
  }

  private enum CodingKeys: String, CodingKey { case confirm, dangerous, yolo }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      confirm: try container.decodeIfPresent(ConfiguredApprovalMode.self, forKey: .confirm) ?? .ask,
      dangerous: try container.decodeIfPresent(ConfiguredApprovalMode.self, forKey: .dangerous)
        ?? .ask,
      yolo: try container.decodeIfPresent(Bool.self, forKey: .yolo) ?? false)
  }
}

/// How much of a child agent's run the text REPL prints. Every level keeps the
/// lines that say a child started and what it answered; the levels differ in
/// what is shown in between.
public enum SubagentOutputLevel: String, Codable, CaseIterable, Sendable {
  /// The child's replies and tool calls, as blocks prefixed with its pid.
  case all
  /// Only the tool calls and their results.
  case tools
  /// One line per model turn with the running counts.
  case stats
  /// Nothing while the child runs.
  case none
}

public struct ConfiguredTerminalUI: Codable, Equatable, Sendable {
  /// Optional label shown in the REPL prompt and used as the terminal window title.
  public var title: String
  public var backgroundLine: String
  public var foreground: String
  public var background: String
  public var promptForeground: String
  public var promptBackground: String
  /// Foreground color used for successful tool-result previews in the text REPL.
  public var toolResultForeground: String
  public var bold: Bool
  /// Render assistant replies as styled markdown in the REPL and visual mode.
  public var markdown: Bool
  /// Number of leading tool-result lines printed by the text REPL. Negative shows all.
  public var toolResultLines: Int
  /// What the text REPL prints while child agents run.
  public var subagentOutput: SubagentOutputLevel
  /// Send unaddressed REPL messages to every active process instead of the focus.
  public var broadcast: Bool
  /// Command the REPL hands the terminal to for `/edit` and the rest. Empty
  /// falls back to `$EDITOR`, then `$VISUAL`, then vim.
  public var thinking: ThinkingDisplay
  public var editor: String

  public init(
    title: String = "",
    backgroundLine: String = "rgb:024",
    foreground: String = "",
    background: String = "",
    promptForeground: String = "yellow",
    promptBackground: String = "",
    toolResultForeground: String = "yellow",
    bold: Bool = false,
    markdown: Bool = true,
    toolResultLines: Int = -1,
    subagentOutput: SubagentOutputLevel = .all,
    broadcast: Bool = false,
    thinking: ThinkingDisplay = .status,
    editor: String = ""
  ) {
    self.title = title
    self.backgroundLine = backgroundLine
    self.foreground = foreground
    self.background = background
    self.promptForeground = promptForeground
    self.promptBackground = promptBackground
    self.toolResultForeground = toolResultForeground
    self.bold = bold
    self.markdown = markdown
    self.toolResultLines = max(-1, toolResultLines)
    self.subagentOutput = subagentOutput
    self.broadcast = broadcast
    self.thinking = thinking
    self.editor = editor
  }

  private enum CodingKeys: String, CodingKey {
    case title
    case backgroundLine = "bgline"
    case foreground = "fgcolor"
    case background = "bgcolor"
    case promptForeground = "fgprompt"
    case promptBackground = "bgprompt"
    case toolResultForeground = "fgtoolresult"
    case bold
    case markdown
    case toolResultLines
    case subagentOutput = "subagents"
    case broadcast
    case thinking
    case editor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
      backgroundLine: try container.decodeIfPresent(String.self, forKey: .backgroundLine)
        ?? "rgb:024",
      foreground: try container.decodeIfPresent(String.self, forKey: .foreground) ?? "",
      background: try container.decodeIfPresent(String.self, forKey: .background) ?? "",
      promptForeground: try container.decodeIfPresent(String.self, forKey: .promptForeground)
        ?? "yellow",
      promptBackground: try container.decodeIfPresent(String.self, forKey: .promptBackground) ?? "",
      toolResultForeground: try container.decodeIfPresent(
        String.self, forKey: .toolResultForeground) ?? "yellow",
      bold: try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false,
      markdown: try container.decodeIfPresent(Bool.self, forKey: .markdown) ?? true,
      toolResultLines: try container.decodeIfPresent(Int.self, forKey: .toolResultLines) ?? -1,
      subagentOutput: try container.decodeIfPresent(
        SubagentOutputLevel.self, forKey: .subagentOutput) ?? .all,
      broadcast: try container.decodeIfPresent(Bool.self, forKey: .broadcast) ?? false,
      thinking: try container.decodeIfPresent(ThinkingDisplay.self, forKey: .thinking) ?? .status,
      editor: try container.decodeIfPresent(String.self, forKey: .editor) ?? "")
  }
}

/// Host-level prompt templates that are shared by every configured agent.
public struct ConfiguredPrompts: Codable, Equatable, Sendable {
  /// Template used by chat compaction. `{{transcript}}` is required and
  /// `{{focus}}` is replaced when `/chat compact` receives optional guidance.
  public var compact: String?
  /// Template that turns an `agent_start` brief into the prompt a child agent
  /// receives. `{{task}}` is required; `{{context}}`, `{{output}}`, `{{agent}}`,
  /// and `{{cwd}}` are replaced when present. Nil keeps MaiCore's built-in text.
  public var delegation: String?
  /// Instructions for the worker MaiCore derives when a delegating agent starts
  /// a child without naming one.
  public var worker: String?
  /// Template `/memory learn` uses to fold conversations into durable notes.
  /// `{{transcript}}` is required; `{{memory}}` and `{{focus}}` are replaced
  /// when present. Nil keeps MaiCore's built-in text.
  public var memory: String?
  /// Reusable system prompts referenced by `AgentDefinition.systemPrompt`.
  public var system: [String: String]
  /// Reusable messages sent by name with `$NAME [TEXT]`; see `UserPrompt`.
  public var user: [String: String]

  public init(
    compact: String? = nil,
    delegation: String? = nil,
    worker: String? = nil,
    memory: String? = nil,
    system: [String: String] = [:],
    user: [String: String] = [:]
  ) {
    self.compact = compact
    self.delegation = delegation
    self.worker = worker
    self.memory = memory
    self.system = system
    self.user = user
  }

  private enum CodingKeys: String, CodingKey {
    case compact, delegation, worker, memory, system, user
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      compact: try container.decodeIfPresent(String.self, forKey: .compact),
      delegation: try container.decodeIfPresent(String.self, forKey: .delegation),
      worker: try container.decodeIfPresent(String.self, forKey: .worker),
      memory: try container.decodeIfPresent(String.self, forKey: .memory),
      system: try container.decodeIfPresent([String: String].self, forKey: .system) ?? [:],
      user: try container.decodeIfPresent([String: String].self, forKey: .user) ?? [:])
  }
}

/// How durable memory is used: whether it reaches the model at all, and which
/// other chats the memory tools may read.
public struct ConfiguredMemory: Codable, Equatable, Sendable {
  /// Adds the memory notes to the system prompt of top-level runs.
  public var enabled: Bool
  /// Chats the `chats_*` tools may reach. `all` crosses working directories,
  /// so it stays opt-in.
  public var scope: MemoryScope

  public init(enabled: Bool = true, scope: MemoryScope = .project) {
    self.enabled = enabled
    self.scope = scope
  }

  private enum CodingKeys: String, CodingKey { case enabled, scope }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      scope: try container.decodeIfPresent(MemoryScope.self, forKey: .scope) ?? .project)
  }
}

/// Optional behaviours a person switches on with `/set use.*`.
public struct ConfiguredUse: Codable, Equatable, Sendable {
  /// Adds the working tree's AGENTS.md files — from the working directory up
  /// to the repository root — to the system prompt of every run.
  public var agentsmd: Bool
  /// Asks an agent that can start children to open a request of several
  /// steps with a short numbered plan — which steps go to child agents and
  /// which of those run in parallel — before its first `agent_start`; a
  /// single question gets no plan. Carried by the `agent_start` description,
  /// so it costs nothing where children are not allowed. On by default.
  public var plan: Bool

  public init(agentsmd: Bool = false, plan: Bool = true) {
    self.agentsmd = agentsmd
    self.plan = plan
  }

  private enum CodingKeys: String, CodingKey { case agentsmd, plan }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      agentsmd: try container.decodeIfPresent(Bool.self, forKey: .agentsmd) ?? false,
      plan: try container.decodeIfPresent(Bool.self, forKey: .plan) ?? true)
  }
}

public struct MaiConfiguration: Codable, Equatable, Sendable {
  public var version: Int
  public var defaultAgent: String?
  public var plugins: [ConfiguredPlugin]
  public var providers: [ConfiguredProvider]
  public var toolSources: [ConfiguredToolSource]
  public var ocrProviders: [ConfiguredOCRProvider]
  public var mcpServers: [ConfiguredMCPServer]
  public var agents: [AgentDefinition]
  public var prompts: ConfiguredPrompts?
  public var memory: ConfiguredMemory
  public var ui: ConfiguredTerminalUI
  public var approvals: ConfiguredApprovals
  public var use: ConfiguredUse

  public init(
    version: Int = 1,
    defaultAgent: String? = nil,
    plugins: [ConfiguredPlugin] = [],
    providers: [ConfiguredProvider] = [],
    toolSources: [ConfiguredToolSource] = [],
    ocrProviders: [ConfiguredOCRProvider] = [],
    mcpServers: [ConfiguredMCPServer] = [],
    agents: [AgentDefinition] = [],
    prompts: ConfiguredPrompts? = nil,
    memory: ConfiguredMemory = .init(),
    ui: ConfiguredTerminalUI = .init(),
    approvals: ConfiguredApprovals = .init(),
    use: ConfiguredUse = .init()
  ) {
    self.version = version
    self.defaultAgent = defaultAgent
    self.plugins = plugins
    self.providers = providers
    self.toolSources = toolSources
    self.ocrProviders = ocrProviders
    self.mcpServers = mcpServers
    self.agents = agents
    self.prompts = prompts
    self.memory = memory
    self.ui = ui
    self.approvals = approvals
    self.use = use
  }

  private enum CodingKeys: String, CodingKey {
    case version, defaultAgent, plugins, providers, toolSources, ocrProviders, mcpServers, agents,
      prompts, memory, ui,
      approvals, use
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
      defaultAgent: try container.decodeIfPresent(String.self, forKey: .defaultAgent),
      plugins: try container.decodeIfPresent([ConfiguredPlugin].self, forKey: .plugins) ?? [],
      providers: try container.decodeIfPresent([ConfiguredProvider].self, forKey: .providers) ?? [],
      toolSources: try container.decodeIfPresent([ConfiguredToolSource].self, forKey: .toolSources)
        ?? [],
      ocrProviders: try container.decodeIfPresent(
        [ConfiguredOCRProvider].self,
        forKey: .ocrProviders) ?? [],
      mcpServers: try container.decodeIfPresent([ConfiguredMCPServer].self, forKey: .mcpServers)
        ?? [],
      agents: try container.decodeIfPresent([AgentDefinition].self, forKey: .agents) ?? [],
      prompts: try container.decodeIfPresent(ConfiguredPrompts.self, forKey: .prompts),
      memory: try container.decodeIfPresent(ConfiguredMemory.self, forKey: .memory) ?? .init(),
      ui: try container.decodeIfPresent(ConfiguredTerminalUI.self, forKey: .ui) ?? .init(),
      approvals: try container.decodeIfPresent(ConfiguredApprovals.self, forKey: .approvals)
        ?? .init(),
      use: try container.decodeIfPresent(ConfiguredUse.self, forKey: .use) ?? .init())
  }

  public static func load(from url: URL) throws -> MaiConfiguration {
    let data = try Data(contentsOf: url)
    do {
      let configuration = try JSONDecoder().decode(MaiConfiguration.self, from: data)
      try configuration.validate()
      return configuration
    } catch let error as MaiConfigurationError {
      throw error
    } catch {
      throw MaiConfigurationError.invalidFile(error.localizedDescription)
    }
  }

  public func encoded(prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
    return try encoder.encode(self)
  }

  public func save(to url: URL, prettyPrinted: Bool = true) throws {
    try validate()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try encoded(prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
  }

  public func validate() throws {
    guard version == 1 else { throw MaiConfigurationError.unsupportedVersion(version) }
    if let compact = prompts?.compact?.trimmingCharacters(in: .whitespacesAndNewlines),
      !compact.isEmpty, !compact.contains("{{transcript}}")
    {
      throw MaiConfigurationError.missingPromptPlaceholder(
        prompt: "compact", placeholder: "{{transcript}}")
    }
    if let delegation = prompts?.delegation,
      let missing = AgentDelegationPrompt.missingPlaceholder(in: delegation)
    {
      throw MaiConfigurationError.missingPromptPlaceholder(
        prompt: "delegation", placeholder: missing)
    }
    if let memory = prompts?.memory,
      let missing = AgentMemoryPrompt.missingPlaceholder(in: memory)
    {
      throw MaiConfigurationError.missingPromptPlaceholder(prompt: "memory", placeholder: missing)
    }
    for name in prompts?.system.keys ?? [String: String]().keys {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MaiConfigurationError.emptyIdentifier("system prompt")
      }
    }
    for name in prompts?.user.keys ?? [String: String]().keys {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MaiConfigurationError.emptyIdentifier("user prompt")
      }
    }
    try Self.requireUnique(providers.map(\.id), kind: "provider")
    try Self.requireUnique(toolSources.map(\.id), kind: "tool source")
    try Self.requireUnique(ocrProviders.map(\.id), kind: "OCR provider")
    try Self.requireUnique(mcpServers.map(\.id), kind: "MCP server")
    try Self.requireUnique(agents.map(\.id), kind: "agent")
    let providerIDs = Set(providers.map(\.id))
    let agentIDs = Set(agents.map(\.id))
    if let defaultAgent, !agentIDs.contains(defaultAgent) {
      throw MaiConfigurationError.unknownAgent(defaultAgent)
    }
    for agent in agents {
      guard providerIDs.contains(agent.provider.rawValue) else {
        throw MaiConfigurationError.unknownProvider(agent.provider.rawValue)
      }
      if let prompt = agent.systemPrompt,
        prompts?.system[prompt] == nil
      {
        throw MaiConfigurationError.unknownPrompt(prompt)
      }
      for child in agent.subagentNames where !agentIDs.contains(child) {
        throw MaiConfigurationError.unknownAgent(child)
      }
    }
  }

  /// Gives legacy inline-instruction agents a reusable, same-named system
  /// prompt and refreshes associated agents from the prompt catalog.
  @discardableResult
  public mutating func associateSystemPrompts() -> Bool {
    let originalPrompts = prompts
    var configured = prompts ?? ConfiguredPrompts()
    let previousAgents = agents
    for index in agents.indices {
      let name = agents[index].systemPrompt ?? agents[index].id
      if let text = configured.system[name] {
        agents[index].instructions = text
      } else {
        configured.system[name] = agents[index].instructions
      }
      agents[index].systemPrompt = name
    }
    prompts = originalPrompts == nil && configured == ConfiguredPrompts() ? nil : configured
    return originalPrompts != prompts || previousAgents != agents
  }

  // MARK: - Catalog edits

  /// The ids of the agents whose instructions come from the named prompt.
  public func agentsUsingSystemPrompt(_ name: String) -> [String] {
    agents.filter { $0.systemPrompt == name }.map(\.id).sorted()
  }

  /// Creates or replaces a named system prompt and refreshes every agent
  /// that uses it, so the catalog and the agents never disagree. Returns the
  /// ids of the agents refreshed.
  @discardableResult
  public mutating func setSystemPrompt(_ name: String, text: String) -> [String] {
    var configured = prompts ?? ConfiguredPrompts()
    configured.system[name] = text
    prompts = configured
    for index in agents.indices where agents[index].systemPrompt == name {
      agents[index].instructions = text
    }
    return agentsUsingSystemPrompt(name)
  }

  /// Drops a named system prompt nobody uses. Answers false when it is
  /// unknown or still referenced, so the caller can say which agents to move.
  @discardableResult
  public mutating func removeSystemPrompt(_ name: String) -> Bool {
    guard prompts?.system[name] != nil, agentsUsingSystemPrompt(name).isEmpty else {
      return false
    }
    prompts?.system[name] = nil
    return true
  }

  /// Points an agent at a named prompt and copies its text into the agent's
  /// instructions. Answers false when either is unknown.
  @discardableResult
  public mutating func assignSystemPrompt(_ name: String, to agentID: String) -> Bool {
    guard let text = prompts?.system[name],
      let index = agents.firstIndex(where: { $0.id == agentID })
    else { return false }
    agents[index].systemPrompt = name
    agents[index].instructions = text
    return true
  }

  /// Inserts or replaces an agent. Its instructions become the text of its
  /// named prompt, and every other agent sharing that prompt is refreshed.
  /// The first agent saved becomes the default. Returns the ids of every
  /// agent whose definition changed, the saved one included.
  @discardableResult
  public mutating func upsertAgent(_ definition: AgentDefinition) -> [String] {
    var changed = Set([definition.id])
    if let name = definition.systemPrompt {
      changed.formUnion(setSystemPrompt(name, text: definition.instructions))
    }
    if let index = agents.firstIndex(where: { $0.id == definition.id }) {
      agents[index] = definition
    } else {
      agents.append(definition)
    }
    if defaultAgent == nil { defaultAgent = definition.id }
    return changed.sorted()
  }

  /// Removes an agent and every reference to it, so the file still validates:
  /// other agents stop offering it as a subagent, and the default moves on
  /// when it was the default. Answers false when the id is unknown.
  @discardableResult
  public mutating func removeAgent(_ id: String) -> Bool {
    guard let index = agents.firstIndex(where: { $0.id == id }) else { return false }
    agents.remove(at: index)
    for other in agents.indices { agents[other].subagentNames.remove(id) }
    if defaultAgent == id { defaultAgent = agents.first?.id }
    return true
  }

  private static func requireUnique(_ values: [String], kind: String) throws {
    var seen = Set<String>()
    for rawValue in values {
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { throw MaiConfigurationError.emptyIdentifier(kind) }
      guard seen.insert(value).inserted else {
        throw MaiConfigurationError.duplicateIdentifier(kind: kind, id: value)
      }
    }
  }
}

public enum MaiConfigurationError: LocalizedError, Equatable, Sendable {
  case invalidFile(String)
  case unsupportedVersion(Int)
  case emptyIdentifier(String)
  case duplicateIdentifier(kind: String, id: String)
  case providerMissingBaseURL(String)
  case mcpServerMissingURL(String)
  case mcpServerMissingCommand(String)
  case unknownProvider(String)
  case unknownAgent(String)
  case unknownTool(agent: String, tool: String)
  case missingEnvironmentVariable(String)
  case unreadableAPIKeyFile(String)
  case missingPromptPlaceholder(prompt: String, placeholder: String)
  case unknownPrompt(String)

  public var errorDescription: String? {
    switch self {
    case .invalidFile(let message):
      "Invalid Mai configuration: \(message)"
    case .unsupportedVersion(let version):
      "Unsupported Mai configuration version \(version)."
    case .emptyIdentifier(let kind):
      "A \(kind) identifier is empty."
    case .duplicateIdentifier(let kind, let id):
      "Duplicate \(kind) identifier '\(id)'."
    case .providerMissingBaseURL(let id):
      "OpenAI-compatible provider '\(id)' is missing baseURL."
    case .mcpServerMissingURL(let id):
      "MCP server '\(id)' is missing a URL."
    case .mcpServerMissingCommand(let id):
      "Stdio MCP server '\(id)' is missing a command."
    case .unknownProvider(let id):
      "Configuration references unknown provider '\(id)'."
    case .unknownAgent(let id):
      "Configuration references unknown agent '\(id)'."
    case .unknownTool(let agent, let tool):
      "Agent '\(agent)' references unknown tool '\(tool)'."
    case .unreadableAPIKeyFile(let path):
      "API key file '\(path)' cannot be read."
    case .missingEnvironmentVariable(let name):
      "Required environment variable '\(name)' is not set."
    case .missingPromptPlaceholder(let prompt, let placeholder):
      "The \(prompt) prompt must contain \(placeholder)."
    case .unknownPrompt(let prompt):
      "Unknown system prompt '\(prompt)'."
    }
  }
}
