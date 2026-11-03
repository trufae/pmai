import Foundation
import MaiCore

public struct MaiOpenAIPlugin: MaiPlugin {
  private let credentialsDirectory: URL?
  public let manifest = PluginManifest(
    id: "org.mai.openai",
    displayName: "OpenAI-compatible provider",
    version: "1.0.0",
    capabilities: [.chatProvider])

  public init(credentialsDirectory: URL? = nil) { self.credentialsDirectory = credentialsDirectory }

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      providerFactory: ChatGPTConfiguredProviderFactory(credentialsDirectory: credentialsDirectory),
      from: manifest.id)
    try await registry.register(
      providerFactory: OpenAIConfiguredProviderFactory(),
      from: manifest.id)
    try await registry.register(
      providerFactory: SystemOneConfiguredProviderFactory(),
      from: manifest.id)
  }
}

public struct OpenAIConfiguredProviderFactory: ConfiguredProviderFactory {
  public let kind = ConfiguredProviderKind.openAI

  public init() {}

  public func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    guard let baseURL = configuration.baseURL else {
      throw MaiConfigurationError.providerMissingBaseURL(configuration.id)
    }
    let selection = configuration.options["httpTransport"]?.stringValue ?? "auto"
    guard let transport = ProviderHTTPTransport(rawValue: selection.lowercased()) else {
      throw NSError(domain: "pmai.http", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "Unknown httpTransport '\(selection)'; use auto, curl, or urlsession."])
    }
    return OpenAICompatibleProvider(
      configuration: .init(
        id: ProviderID(configuration.id),
        displayName: configuration.displayName ?? "OpenAI-compatible",
        baseURL: baseURL,
        apiKey: try configuration.resolvedAPIKey(environment: environment),
        additionalHeaders: try configuration.resolvedHeaders(environment: environment),
        requestTimeout: configuration.timeout ?? 600,
        httpTransport: transport))
  }
}
