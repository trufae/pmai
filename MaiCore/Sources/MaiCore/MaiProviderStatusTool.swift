import Foundation

/// `provider_status`: the limits `/status` prints, as structured content. ACP
/// exposes it through `runTool`, so an editor, a phone, or an external agent
/// reaches one implementation instead of calling the provider itself.
public struct MaiProviderStatusTool: AgentTool {
  public static let name = "provider_status"

  public static let toolDefinition = ToolDefinition(
    name: name,
    description:
      "Report how much of the current provider's limits are left and when they reset: Ollama Cloud's session and week, or the limits Codex and Claude Code report themselves.",
    parameters: [
      ToolParameterDef(
        name: "provider", type: "string",
        description: "Configured provider id. Omit for the one this chat is using.",
        required: false),
      ToolParameterDef(
        name: "model", type: "string",
        description: "Model to report for. Omit for the chat's model.",
        required: false),
      ToolParameterDef(
        name: "refresh", type: "boolean",
        description: "Fetch again instead of reusing the answer from the last minute.",
        required: false),
    ], annotations: ToolAnnotations(requiresInternet: true))

  public let definition = Self.toolDefinition
  public let isHostTool = true
  private let resolve: @Sendable (String?, String?, Bool) async throws -> MaiProviderStatus?

  /// - Parameter resolve: takes the requested provider id, model, and refresh
  ///   flag, and returns nil for a provider that publishes no limits.
  public init(
    resolve: @escaping @Sendable (String?, String?, Bool) async throws -> MaiProviderStatus?
  ) {
    self.resolve = resolve
  }

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws
    -> ToolOutput
  {
    let arguments = arguments.objectValue ?? [:]
    let provider = arguments["provider"]?.coercedStringValue
    let model = arguments["model"]?.coercedStringValue
    let refresh = arguments["refresh"]?.coercedBoolValue ?? false
    guard let status = try await resolve(provider, model, refresh) else {
      return ToolOutput(
        text: "Account quota information is unavailable for this provider.")
    }
    return ToolOutput(
      content: [.text(status.summary())],
      structuredContent: Self.structured(status))
  }

  /// The same facts a host reads over ACP, one shape for both. Clients read it
  /// back with `MaiProviderStatus(payload:)`.
  public static func structured(_ status: MaiProviderStatus) -> JSONValue {
    structured(status.payload)
  }

  private static func structured(_ fields: [String: Any]) -> JSONValue {
    .object(
      fields.mapValues { value in
        switch value {
        case let text as String: return .string(text)
        case let number as Int: return .integer(number)
        case let number as Double: return .number(number)
        case let flag as Bool: return .bool(flag)
        case let nested as [String: Any]: return structured(nested)
        case let list as [[String: Any]]: return .array(list.map { structured($0) })
        case let list as [String]: return .array(list.map(JSONValue.string))
        default: return .null
        }
      })
  }
}

extension AgentRuntime {
  /// Offers `provider_status` to the model. `configuration` returns the
  /// settings in force now, so the tool follows a provider switch.
  public func registerProviderStatusTool(
    _ store: ProviderStatusStore, configuration: @escaping @Sendable () -> MaiConfiguration?
  ) {
    registerProviderStatus(store, configuration: configuration)
    let tool = MaiProviderStatusTool { [weak self] provider, model, refresh in
      guard let self else { return nil }
      let requested = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let id = try await providerStatusDefaultID(requested, configuration: configuration())
      guard let id else { return nil }
      return try await providerStatus(for: id, model: model, refresh: refresh)
    }
    try? register(tool: tool, replacingExisting: true)
  }

  /// The provider a status request means: the one named, else the provider of
  /// the most recent run, else the only cloud provider configured. Hosts that
  /// have not run anything yet still get an answer.
  public func providerStatusDefaultID(
    _ requested: String, configuration: MaiConfiguration?
  ) async throws -> String? {
    guard requested.isEmpty else { return requested }
    let settings = configuration ?? MaiConfiguration()
    // A run in flight names the provider the person is using now.
    if let latest = liveRequests.values.first?.provider.rawValue, !latest.isEmpty {
      return latest
    }
    if let latest = conversationRequests.values.first?.provider.rawValue, !latest.isEmpty {
      return latest
    }
    let hosted = settings.providers.filter {
      MaiProviderStatusService.isOllamaCloud($0.baseURL?.host?.lowercased() ?? "")
    }
    return hosted.count == 1 ? hosted[0].id : hosted.first?.id
  }
}
