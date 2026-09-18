import Foundation
import MaiCore

public struct MaiStandardToolsPlugin: MaiPlugin {
  public static let factoryKind = "standard-tools"

  public let manifest = PluginManifest(
    id: "org.mai.standard-tools",
    displayName: "Mai standard tools",
    version: "1.0.0",
    capabilities: [.agentTool])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(toolFactory: MaiStandardToolFactory(), from: manifest.id)
  }
}

public struct MaiStandardToolFactory: ConfiguredToolFactory {
  public let kind = MaiStandardToolsPlugin.factoryKind

  public init() {}

  public func makeTools(context: PluginFactoryContext) async throws -> [any AgentTool] {
    let configuredFilesRoot =
      context.options["filesRoot"]?.stringValue
      ?? context.environment["PMAI_FILES_ROOT"]
    let followsWorkingDirectory = configuredFilesRoot == nil || configuredFilesRoot == "."
    let filesRoot = NSString(
      string: context.string(
        "filesRoot",
        environment: "PMAI_FILES_ROOT",
        default: FileManager.default.currentDirectoryPath)
    )
    .expandingTildeInPath
    let fileConfiguration = MaiFileWorkspaceConfiguration(
      rootURL: URL(fileURLWithPath: filesRoot),
      displayName: context.options["filesDisplayName"]?.stringValue,
      writeEnabled: context.options["filesWriteEnabled"]?.boolValue ?? true,
      followsProcessWorkingDirectory: followsWorkingDirectory)
    let webSearchProvider =
      context.options["webSearchProvider"]?.stringValue
      .flatMap(MaiWebSearchProvider.init(rawValue:)) ?? .exa
    let latitude = context.options["weatherLatitude"]?.numberValue
    let longitude = context.options["weatherLongitude"]?.numberValue
    let coordinate = latitude.flatMap { latitude in
      longitude.map { MaiCoordinate(latitude: latitude, longitude: $0) }
    }
    let runConfiguration = MaiRunConfiguration(
      shell: context.string("runShell", environment: "PMAI_RUN_SHELL"),
      defaultTimeout: context.options["runTimeoutSeconds"]?.numberValue
        ?? MaiRunConfiguration.defaultTimeout)
    let tools: [any AgentTool] =
      [
        MaiCurrentTimeTool(),
        MaiCalculatorTool(),
        MaiWeatherTool(
          configuration: MaiWeatherConfiguration(
            location: context.string("weatherLocation", environment: "MAI_WEATHER_LOCATION"),
            coordinate: coordinate)),
        MaiWebSearchTool(
          configuration: MaiWebSearchConfiguration(
            provider: webSearchProvider,
            searXNGURL: context.string("searXNGURL", environment: "SEARXNG_URL"),
            searXNGUsername: context.string(
              "searXNGUsername", environment: "SEARXNG_USERNAME"),
            searXNGPassword: context.secret(
              "searXNGPassword", environmentOption: "searXNGPasswordEnvironment",
              defaultEnvironment: "SEARXNG_PASSWORD"),
            ollamaAPIKey: context.secret(
              "ollamaAPIKey", environmentOption: "ollamaAPIKeyEnvironment",
              defaultEnvironment: "OLLAMA_API_KEY"))),
        MaiWebFetchTool(),
        MaiMastodonTool(
          configuration: MaiMastodonConfiguration(
            instance: context.string(
              "mastodonInstance", environment: "MASTODON_INSTANCE", default: "mastodon.social"),
            apiKey: context.secret(
              "mastodonAPIKey", environmentOption: "mastodonAPIKeyEnvironment",
              defaultEnvironment: "MASTODON_API_KEY"),
            writeEnabled: context.options["mastodonWriteEnabled"]?.boolValue ?? false)),
      ]
      + MaiFileWorkspaceTool.makeTools(configuration: fileConfiguration)
      + MaiRunTool.makeTools(configuration: runConfiguration)
      + MaiGitHubTool.makeTools()
    guard let names = context.options["tools"]?.arrayValue else { return tools }
    let enabled = Set(names.compactMap(\.stringValue))
    return tools.filter { enabled.contains($0.definition.name) }
  }

  public func toolGroups(context: PluginFactoryContext) async throws -> [ToolGroupDefinition] {
    let available = Set(try await makeTools(context: context).map(\.definition.name))
    let webTools: Set<String> =
      context.options["webSearchFetchingEnabled"]?.boolValue == false
      ? [MaiWebSearchTool.name]
      : [MaiWebSearchTool.name, MaiWebFetchTool.name]
    return [
      ToolGroupDefinition(
        id: "datetime",
        displayName: "Date & Time",
        description:
          "Tell the model what day it is: current_time returns the current date and time as ISO-8601, "
          + "so answers about today, deadlines, and elapsed time do not rely on the model's training date.",
        toolNames: [MaiCurrentTimeTool.name]),
      ToolGroupDefinition(
        id: "calc",
        displayName: "Calculator",
        description:
          "Exact arithmetic: calc evaluates a numeric expression with +, -, *, /, and parentheses and "
          + "returns the result, so sums, percentages, and conversions are computed instead of guessed.",
        toolNames: [MaiCalculatorTool.name]),
      ToolGroupDefinition(
        id: "files",
        displayName: "Files",
        description:
          "Work with the files of one workspace folder, confined to it. files_list and files_find locate "
          + "files, files_grep searches their text, files_read and files_read_range return contents (PDF "
          + "and DOCX as Markdown), files_read_index and files_get_function navigate code by symbol, and "
          + "files_set_function, files_patch, files_replace_range, and files_write change it; files_rename "
          + "and files_delete move or remove. Read before editing and prefer the smallest edit that does "
          + "the job. With file changes disallowed the group is read-only.",
        toolNames: Set(MaiFileWorkspaceTool.toolNames),
        options: [
          .init(
            id: "filesRoot",
            label: "Workspace folder",
            help: "All relative tool paths are confined to this folder."),
          .init(id: "filesDisplayName", label: "Workspace name"),
          .init(
            id: "filesWriteEnabled",
            label: "Allow file changes",
            kind: .boolean,
            defaultValue: .bool(true)),
        ]),
      ToolGroupDefinition(
        id: "run",
        displayName: "Run",
        description:
          "Run programs on this computer: run_sh executes a shell command line or script with the "
          + "configured shell and returns its output and exit status, killing it after the default "
          + "timeout unless the call sets one. Use it for builds, tests, git, and anything a person "
          + "would type in a terminal.",
        toolNames: Set(MaiRunTool.toolNames),
        options: [
          .init(
            id: "runShell",
            label: "Shell",
            help: "Runs run_sh scripts; a name found in PATH or a full path, optionally with leading arguments.",
            defaultValue: .string(MaiRunConfiguration.defaultShell)),
          .init(
            id: "runTimeoutSeconds",
            label: "Default timeout (seconds)",
            help: "Processes are killed after this long unless a call sets timeout_seconds.",
            kind: .number,
            defaultValue: .integer(Int(MaiRunConfiguration.defaultTimeout))),
        ]),
      ToolGroupDefinition(
        id: "weather",
        displayName: "Weather",
        description:
          "Current weather and a 7-day forecast: weather looks up a city, place, or coordinates, or the "
          + "configured default location when the call names none. Use it whenever the user asks about "
          + "the weather instead of guessing.",
        toolNames: [MaiWeatherTool.name],
        options: [
          .init(
            id: "weatherLocation",
            label: "Default location",
            help: "Used when a call does not provide a location."),
          .init(id: "weatherLatitude", label: "Latitude", kind: .number),
          .init(id: "weatherLongitude", label: "Longitude", kind: .number),
        ]),
      ToolGroupDefinition(
        id: "web",
        displayName: "Web Search",
        description:
          "Look things up on the web: web_search finds pages for a focused query (the configured "
          + "provider decides where) and, when fetching is allowed, web_fetch returns the readable text "
          + "of one URL. Search first, then fetch only the pages worth reading; use them for current or "
          + "external facts the model cannot know.",
        toolNames: webTools,
        options: [
          .init(
            id: "webSearchProvider",
            label: "Search provider",
            kind: .choice,
            defaultValue: .string(MaiWebSearchProvider.exa.rawValue),
            choices: MaiWebSearchProvider.allCases.map(\.rawValue)),
          .init(id: "searXNGURL", label: "SearXNG URL"),
          .init(id: "searXNGUsername", label: "SearXNG username"),
          .init(id: "searXNGPassword", label: "SearXNG password", kind: .secret),
          .init(
            id: "searXNGPasswordEnvironment",
            label: "SearXNG password environment variable"),
          .init(id: "ollamaAPIKey", label: "Ollama API key", kind: .secret),
          .init(id: "ollamaAPIKeyEnvironment", label: "Ollama API key environment variable"),
          .init(
            id: "webSearchFetchingEnabled",
            label: "Allow fetching pages",
            kind: .boolean,
            defaultValue: .bool(true)),
        ]),
      ToolGroupDefinition(
        id: "mastodon",
        displayName: "Mastodon",
        description:
          "Use Mastodon through the configured instance: the mastodon tool searches posts by keyword "
          + "(toot_search), lists a user's recent posts (user_posts), and, when posting is allowed, "
          + "publishes a status or a reply (post). The instance and API key are settings of this group.",
        toolNames: [MaiMastodonTool.name],
        options: [
          .init(
            id: "mastodonInstance",
            label: "Instance",
            defaultValue: .string("mastodon.social")),
          .init(id: "mastodonAPIKey", label: "API key", kind: .secret),
          .init(id: "mastodonAPIKeyEnvironment", label: "API key environment variable"),
          .init(
            id: "mastodonWriteEnabled",
            label: "Allow posting and replying",
            kind: .boolean,
            defaultValue: .bool(false)),
        ]),
      ToolGroupDefinition(
        id: "github",
        displayName: "GitHub",
        description:
          "Browse public GitHub repositories without cloning them: list and read files, commits, pull "
          + "requests with their diffs, issues, releases, and CI runs with their logs. Use it to review "
          + "a change, answer a question about a project, or fetch one file; nothing here writes to GitHub.",
        toolNames: Set(MaiGitHubTool.toolNames)),
    ].compactMap { group in
      let names = group.toolNames.intersection(available)
      guard !names.isEmpty else { return nil }
      var group = group
      group.toolNames = names
      return group
    }
  }
}

extension PluginFactoryContext {
  fileprivate func string(
    _ option: String,
    environment name: String,
    default defaultValue: String = ""
  ) -> String {
    options[option]?.stringValue ?? environment[name] ?? defaultValue
  }

  fileprivate func secret(
    _ option: String,
    environmentOption: String,
    defaultEnvironment: String
  ) -> String {
    let environmentName = options[environmentOption]?.stringValue ?? defaultEnvironment
    return environment[environmentName] ?? options[option]?.stringValue ?? ""
  }
}

public struct MaiCurrentTimeTool: AgentTool {
  public static let name = "current_time"
  public static let toolDefinition = ToolDefinition(
    name: name,
    description: "Return the current ISO-8601 date and time.",
    inputSchema: objectSchema(properties: [:], required: []),
    annotations: ToolAnnotations(
      readOnly: true,
      idempotent: false,
      openWorld: false,
      approval: .automatic))

  public let definition = Self.toolDefinition

  public init() {}

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    ToolOutput(text: ISO8601DateFormatter().string(from: Date()))
  }
}

public struct MaiCalculatorTool: AgentTool {
  public static let name = "calc"
  public static let toolDefinition = ToolDefinition(
    name: name,
    description:
      "Evaluate a numeric math expression with parentheses using +, -, *, /, and unary signs.",
    inputSchema: objectSchema(
      properties: [
        "expression": .object([
          "type": .string("string"),
          "description": .string("Math expression to evaluate, such as (2 + 3) * 4 / 5."),
        ])
      ],
      required: ["expression"]),
    annotations: ToolAnnotations(
      readOnly: true,
      idempotent: true,
      openWorld: false,
      approval: .automatic))

  public let definition = Self.toolDefinition

  public init() {}

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    Self.evaluate(arguments.objectValue ?? [:])
  }

  public static func evaluate(_ arguments: [String: JSONValue]) -> ToolOutput {
    let expression =
      arguments["expression"]?.stringValue ?? arguments["expr"]?.stringValue
      ?? arguments["input"]?.stringValue ?? ""
    let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return ToolOutput(text: "Error: expression is required.", isError: true)
    }

    do {
      var parser = CalculatorParser(trimmed)
      return ToolOutput(text: format(try parser.parse()))
    } catch {
      return ToolOutput(
        text: "Error: invalid expression: \(error.localizedDescription)",
        isError: true)
    }
  }

  private static func format(_ value: Double) -> String {
    guard value.isFinite else { return "Error: calculation result is not finite." }
    if value.rounded() == value && value <= Double(Int64.max) && value >= Double(Int64.min) {
      return String(Int64(value))
    }
    return String(format: "%.15g", value)
  }
}

private struct CalculatorParser {
  private let text: String
  private var index: String.Index

  init(_ text: String) {
    self.text = text
    self.index = text.startIndex
  }

  mutating func parse() throws -> Double {
    let value = try parseExpression()
    skipWhitespace()
    guard index == text.endIndex else {
      throw CalculatorParserError("unexpected '\(text[index])'")
    }
    guard value.isFinite else { throw CalculatorParserError("result is not finite") }
    return value
  }

  private mutating func parseExpression() throws -> Double {
    var value = try parseTerm()
    while true {
      if consume("+") {
        value += try parseTerm()
      } else if consume("-") {
        value -= try parseTerm()
      } else {
        return value
      }
    }
  }

  private mutating func parseTerm() throws -> Double {
    var value = try parseFactor()
    while true {
      if consume("*") {
        value *= try parseFactor()
      } else if consume("/") {
        let divisor = try parseFactor()
        guard divisor != 0 else { throw CalculatorParserError("division by zero") }
        value /= divisor
      } else {
        return value
      }
    }
  }

  private mutating func parseFactor() throws -> Double {
    skipWhitespace()
    if consume("+") { return try parseFactor() }
    if consume("-") { return -(try parseFactor()) }
    if consume("(") {
      let value = try parseExpression()
      guard consume(")") else { throw CalculatorParserError("expected ')'") }
      return value
    }
    return try parseNumber()
  }

  private mutating func parseNumber() throws -> Double {
    skipWhitespace()
    let start = index
    var hasDigit = false
    while let char = current, char.isNumber {
      hasDigit = true
      advance()
    }
    if consumeRaw(".") {
      while let char = current, char.isNumber {
        hasDigit = true
        advance()
      }
    }
    guard hasDigit else { throw CalculatorParserError("expected number") }

    if let char = current, char == "e" || char == "E" {
      advance()
      _ = consumeRaw("+") || consumeRaw("-")
      var hasExponentDigit = false
      while let char = current, char.isNumber {
        hasExponentDigit = true
        advance()
      }
      guard hasExponentDigit else { throw CalculatorParserError("expected exponent digits") }
    }

    let raw = String(text[start..<index])
    guard let value = Double(raw), value.isFinite else {
      throw CalculatorParserError("invalid number '\(raw)'")
    }
    return value
  }

  private var current: Character? { index < text.endIndex ? text[index] : nil }

  private mutating func skipWhitespace() {
    while current?.isWhitespace == true { advance() }
  }

  private mutating func consume(_ char: Character) -> Bool {
    skipWhitespace()
    return consumeRaw(char)
  }

  private mutating func consumeRaw(_ char: Character) -> Bool {
    guard current == char else { return false }
    advance()
    return true
  }

  private mutating func advance() {
    index = text.index(after: index)
  }
}

private struct CalculatorParserError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

func objectSchema(
  properties: [String: JSONValue],
  required: [String]
) -> JSONValue {
  .object([
    "type": .string("object"),
    "properties": .object(properties),
    "required": .array(required.map(JSONValue.string)),
    "additionalProperties": .bool(false),
  ])
}
