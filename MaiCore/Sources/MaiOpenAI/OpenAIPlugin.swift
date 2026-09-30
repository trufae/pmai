import Foundation
import MaiCore

public struct MaiOpenAIPlugin: MaiPlugin {
  public let manifest = PluginManifest(
    id: "org.mai.openai",
    displayName: "OpenAI-compatible provider",
    version: "1.0.0",
    capabilities: [.chatProvider])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      providerFactory: OpenAIConfiguredProviderFactory(),
      from: manifest.id)
    try await registry.register(
      providerFactory: SystemOneConfiguredProviderFactory(),
      from: manifest.id)
  }
}

public struct OpenAIConfiguredProviderFactory: ConfiguredProviderFactory {
  public let kind = ConfiguredProviderKind.openAICompatible

  public init() {}

  public func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    guard let baseURL = configuration.baseURL else {
      throw MaiConfigurationError.providerMissingBaseURL(configuration.id)
    }
    return OpenAICompatibleProvider(
      configuration: .init(
        id: ProviderID(configuration.id),
        displayName: configuration.displayName ?? "OpenAI-compatible",
        baseURL: baseURL,
        apiKey: try configuration.resolvedAPIKey(environment: environment),
        additionalHeaders: try configuration.resolvedHeaders(environment: environment),
        requestTimeout: configuration.timeout ?? 600))
  }
}
