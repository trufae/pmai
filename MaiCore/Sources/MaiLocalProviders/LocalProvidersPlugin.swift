import Foundation
import MaiCore

public struct MaiLocalProvidersPlugin: MaiPlugin {
  public let manifest = PluginManifest(
    id: "org.mai.local-providers", displayName: "Apple Intelligence and MLX",
    version: "1.0.0", capabilities: [.chatProvider])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(providerFactory: AppleProviderFactory(), from: manifest.id)
    try await registry.register(providerFactory: MLXProviderFactory(), from: manifest.id)
  }

  public static var defaultProviders: [ConfiguredProvider] {
    #if os(macOS)
      [
        .init(id: "apple", kind: .apple, defaultModel: AppleProvider.modelID),
        .init(id: "mlx", kind: .mlx, defaultModel: MLXProvider.defaultModelID),
      ]
    #else
      []
    #endif
  }

  public static func availabilityMessage(for kind: ConfiguredProviderKind) -> String? {
    switch kind {
    case .apple: AppleProvider.unavailabilityMessage
    case .mlx: MLXProvider.unavailabilityMessage
    default: nil
    }
  }
}

public struct AppleProviderFactory: ConfiguredProviderFactory {
  public let kind = ConfiguredProviderKind.apple
  public init() {}

  public func makeProvider(
    from configuration: ConfiguredProvider, environment: [String: String]
  ) throws -> any ChatProvider {
    AppleProvider(id: ProviderID(configuration.id), displayName: configuration.displayName)
  }
}

public struct MLXProviderFactory: ConfiguredProviderFactory {
  public let kind = ConfiguredProviderKind.mlx
  public init() {}

  public func makeProvider(
    from configuration: ConfiguredProvider, environment: [String: String]
  ) throws -> any ChatProvider {
    MLXProvider(configuration: configuration)
  }
}

struct LocalProviderError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Retain tool exchanges when switching from a native-tools provider to a text backend.
enum LocalProviderInput {
  static func messages(_ messages: [AgentMessage]) throws -> [AgentMessage] {
    try messages.map { message in
      let parts = try message.content.compactMap { part -> String? in
        switch part {
        case .reasoning: return nil
        case .toolCall(let call):
          return "Tool call \(call.id): \(call.name) \(call.arguments.compactJSONString)"
        case .toolResult(let result):
          let structured = result.structuredContent.map { "\n" + $0.compactJSONString } ?? ""
          return "Tool result \(result.callID)\(result.isError ? " (error)" : ""):\n\(result.text)\(structured)"
        case .image, .audio:
          throw LocalProviderError("This local provider accepts text. Use OCR or a provider that supports this attachment.")
        case .file(let file) where file.text == nil:
          throw LocalProviderError("This local provider needs extracted text for file attachments.")
        default: return part.textValue
        }
      }
      return AgentMessage(id: message.id, role: message.role, content: [.text(parts.joined(separator: "\n"))])
    }
  }
}
