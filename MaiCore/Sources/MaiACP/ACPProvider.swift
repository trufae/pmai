import Foundation
import MaiCore

/// A remote ACP agent seen as a MaiCore provider.
///
/// This is the whole trick to "use ACP agents like any other agent": an ACP
/// connection answers `complete` the way an LLM backend does, so an
/// `AgentDefinition` pointing at it flows through `AgentRuntime`, `/agent`,
/// subagents, and delegation with no special cases anywhere else. The external
/// agent's own tools, model, and reasoning live behind the boundary; MaiCore
/// only sees a reply.
public actor ACPProvider: ChatProvider {
  public nonisolated let descriptor: ProviderDescriptor

  private let configuration: ACPClient.Configuration
  /// One live agent per working directory: a prompt from a child run in a
  /// different cwd must not land in the parent's session.
  private var clients: [String: ACPClient] = [:]

  public init(id: ProviderID, displayName: String, configuration: ACPClient.Configuration) {
    self.descriptor = ProviderDescriptor(
      id: id,
      displayName: displayName,
      // ACP agents stream, and they carry their own tools, so MaiCore never
      // offers them its tool schema — tool calling stays behind the boundary.
      capabilities: [.streaming, .reasoning])
    self.configuration = configuration
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    // ACP does not enumerate models; the agent picks its own.
    [ModelDescriptor(id: descriptor.id.rawValue, displayName: descriptor.displayName)]
  }

  public func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let client = client(for: configuration.workingDirectory ?? AgentExecutionScope.directory)
    // The runtime hands over the whole transcript each turn, but the ACP agent
    // keeps its own session, so only the latest user turn is new to it.
    let text = ACPProvider.latestUserText(request.messages)
    let collector = TextCollector()
    let stopReason = try await client.prompt(text) { event in
      if case .textDelta(let delta) = event { await collector.append(delta) }
      await emit(event)
    }
    let answer = await collector.text
    return ProviderResponse(
      message: .assistant(answer),
      usage: nil,
      stopReason: stopReason)
  }

  public func shutdown() async {
    for client in clients.values { await client.close() }
    clients.removeAll()
  }

  private func client(for workingDirectory: URL?) -> ACPClient {
    let key = workingDirectory?.standardizedFileURL.path ?? "."
    if let existing = clients[key] { return existing }
    var configuration = self.configuration
    if configuration.workingDirectory == nil { configuration.workingDirectory = workingDirectory }
    let client = ACPClient(configuration: configuration)
    clients[key] = client
    return client
  }

  /// The last user message, which is the only turn the agent has not seen.
  /// Its own session holds everything before it.
  static func latestUserText(_ messages: [AgentMessage]) -> String {
    if let last = messages.last(where: { $0.role == .user }) {
      let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { return text }
    }
    return messages.last?.text ?? ""
  }
}

/// Accumulates streamed deltas into the authoritative final answer.
private actor TextCollector {
  private(set) var text = ""
  func append(_ delta: String) { text += delta }
}

/// Registers the ACP provider factory, so a `kind: "acp"` provider in the
/// configuration builds an `ACPProvider` like any other backend.
public struct MaiACPPlugin: MaiPlugin {
  public let manifest = PluginManifest(
    id: "org.mai.acp",
    displayName: "ACP agent provider",
    version: "1.0.0",
    capabilities: [.chatProvider])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      providerFactory: ACPConfiguredProviderFactory(), from: manifest.id)
  }
}

/// Builds `ACPProvider`s from configuration. An ACP provider stores its command
/// line in `options`, so no new configuration schema is needed:
///
///     { "id": "gemini", "kind": "acp",
///       "options": { "command": "gemini", "args": ["--acp"],
///                    "permission": "auto" } }
public struct ACPConfiguredProviderFactory: ConfiguredProviderFactory {
  public static let providerKind: ConfiguredProviderKind = "acp"
  public let kind = ACPConfiguredProviderFactory.providerKind

  public init() {}

  public func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    let options = configuration.options
    guard let command = options["command"]?.stringValue, !command.isEmpty else {
      throw ACPConfigurationError.missingCommand(configuration.id)
    }
    let arguments = options["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
    var childEnvironment = environment
    for (key, value) in options["env"]?.objectValue ?? [:] {
      childEnvironment[key] = value.coercedStringValue
    }
    let permission =
      options["permission"]?.stringValue.flatMap(ACPPermissionPolicy.init(rawValue:)) ?? .auto
    let workingDirectory = options["cwd"]?.stringValue.map {
      URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
    }
    return ACPProvider(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? configuration.id,
      configuration: ACPClient.Configuration(
        command: command,
        arguments: arguments,
        environment: childEnvironment,
        workingDirectory: workingDirectory,
        permission: permission,
        promptTimeout: configuration.timeout ?? 600,
        remoteWorkingDirectory: options["remoteCwd"]?.stringValue,
        readClientFiles: options["readClientFiles"]?.boolValue ?? true))
  }
}

public enum ACPConfigurationError: LocalizedError, Equatable, Sendable {
  case missingCommand(String)

  public var errorDescription: String? {
    switch self {
    case .missingCommand(let id):
      "ACP provider '\(id)' is missing its command in options.command."
    }
  }
}
