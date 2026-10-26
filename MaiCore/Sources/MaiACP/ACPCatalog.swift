import Foundation
import MaiCore

/// A known external ACP agent: what to run, and one line on what it is. The
/// catalog exists so `/agent add --acp gemini` needs only a name, and so a
/// listing can say what is installed.
public struct ACPCatalogAgent: Sendable, Equatable {
  public var id: String
  public var displayName: String
  public var summary: String
  public var command: String
  public var arguments: [String]
  /// A one-line hint shown when the command is not on PATH.
  public var install: String?

  public init(
    id: String,
    displayName: String,
    summary: String,
    command: String,
    arguments: [String] = [],
    install: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.summary = summary
    self.command = command
    self.arguments = arguments
    self.install = install
  }

  /// True when the command resolves on PATH or as an absolute path.
  public var isInstalled: Bool { ACPCatalog.resolve(command) != nil }

  /// The configuration record that registers this agent as a provider.
  public func configuredProvider() -> ConfiguredProvider {
    var options: [String: JSONValue] = ["command": .string(command)]
    if !arguments.isEmpty { options["args"] = .array(arguments.map(JSONValue.string)) }
    return ConfiguredProvider(
      id: id, kind: ACPConfiguredProviderFactory.providerKind, displayName: displayName,
      defaultModel: id, options: options)
  }
}

/// The builtin roster, following the official ACP registry. Native agents speak
/// ACP directly; Claude Code and Codex are driven through adapters. Custom
/// agents override a builtin by using the same id in the configuration.
public enum ACPCatalog {
  public static let agents: [ACPCatalogAgent] = [
    ACPCatalogAgent(
      id: "gemini", displayName: "Gemini CLI",
      summary: "Google's Gemini coding agent.", command: "gemini", arguments: ["--acp"],
      install: "npm install -g @google/gemini-cli"),
    ACPCatalogAgent(
      id: "qwen", displayName: "Qwen Code",
      summary: "Alibaba's Qwen coding agent.", command: "qwen", arguments: ["--acp"],
      install: "npm install -g @qwen-code/qwen-code"),
    ACPCatalogAgent(
      id: "opencode", displayName: "opencode",
      summary: "The opencode terminal agent.", command: "opencode", arguments: ["acp"],
      install: "npm install -g opencode-ai"),
    ACPCatalogAgent(
      id: "goose", displayName: "Goose",
      summary: "Block's Goose agent.", command: "goose", arguments: ["acp"],
      install: "https://block.github.io/goose/"),
    ACPCatalogAgent(
      id: "claude", displayName: "Claude Code (adapter)",
      summary: "Claude Code through the ACP adapter.",
      command: "claude-agent-acp",
      install: "npm install -g @agentclientprotocol/claude-agent-acp"),
    ACPCatalogAgent(
      id: "codex", displayName: "Codex (adapter)",
      summary: "OpenAI Codex through the ACP adapter.",
      command: "codex-acp",
      install: "npm install -g @agentclientprotocol/codex-acp"),
  ]

  public static func agent(_ id: String) -> ACPCatalogAgent? {
    let lower = id.lowercased()
    return agents.first { $0.id == lower }
  }

  /// Resolves a command to an absolute path via PATH, as a shell would. Returns
  /// nil when nothing is found, so a caller can report it as not installed.
  public static func resolve(
    _ command: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    if command.contains("/") {
      return FileManager.default.isExecutableFile(atPath: command) ? command : nil
    }
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = "\(directory)/\(command)"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }
}
