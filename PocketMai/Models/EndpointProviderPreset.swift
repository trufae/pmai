import Foundation
import MaiCore

struct EndpointProviderPreset {
  let name: String
  let url: String
  let authMethods: [EndpointAuthMethod]
  let oauthDefaults: OAuthPresetDefaults?
  let preferredAuthMethod: EndpointAuthMethod?
  /// Headers the provider needs on every request. They are filled in when the
  /// preset is picked and sent for any endpoint at this URL that lacks them.
  let headers: [String: String]

  init(
    name: String,
    url: String,
    authMethods: [EndpointAuthMethod] = [.apiKey],
    oauthDefaults: OAuthPresetDefaults? = nil,
    preferredAuthMethod: EndpointAuthMethod? = nil,
    headers: [String: String] = [:]
  ) {
    self.name = name
    self.url = url
    self.authMethods = authMethods
    self.oauthDefaults = oauthDefaults
    self.preferredAuthMethod = preferredAuthMethod
    self.headers = headers
  }

  var tag: String {
    url
  }
}

let endpointProviderPresets: [EndpointProviderPreset] = [
  EndpointProviderPreset(
    name: "OpenAI",
    url: "https://api.openai.com/v1",
    authMethods: [.apiKey, .oauth],
    oauthDefaults: OpenAIEndpoint.openAIAuthDefaults
  ),
  EndpointProviderPreset(name: "Ollama", url: "http://localhost:11434/v1"),
  EndpointProviderPreset(name: "Ollama Cloud", url: "https://ollama.com/v1"),
  EndpointProviderPreset(name: "OpenRouter", url: "https://openrouter.ai/api/v1"),
  // OpenCode meters the Go plan per session and rejects requests that do not
  // present a stable session id, so both presets send the chat's.
  EndpointProviderPreset(
    name: "OpenCode Zen", url: "https://opencode.ai/zen/v1",
    headers: openCodeSessionHeaders),
  EndpointProviderPreset(
    name: "OpenCode Go", url: "https://opencode.ai/zen/go/v1",
    headers: openCodeSessionHeaders),
  EndpointProviderPreset(name: "Hugging Face", url: "https://router.huggingface.co/v1"),
  EndpointProviderPreset(
    name: "Anthropic",
    url: OpenAIEndpoint.anthropicOAuthDefaults.baseURL,
    oauthDefaults: OpenAIEndpoint.anthropicOAuthDefaults
  ),
  EndpointProviderPreset(
    name: "Google Gemini",
    url: "https://generativelanguage.googleapis.com/v1beta/openai"
  ),
  EndpointProviderPreset(
    name: "Google Vertex AI",
    url: OpenAIEndpoint.googleOAuthDefaults.baseURL,
    authMethods: [.oauth],
    oauthDefaults: OpenAIEndpoint.googleOAuthDefaults,
    preferredAuthMethod: .oauth
  ),
  EndpointProviderPreset(name: "Mistral", url: "https://api.mistral.ai/v1"),
  EndpointProviderPreset(name: "MiniMax", url: "https://api.minimax.io/v1"),
  EndpointProviderPreset(name: "xAI", url: "https://api.x.ai/v1"),
  EndpointProviderPreset(name: "DeepSeek", url: "https://api.deepseek.com/v1"),
  EndpointProviderPreset(name: "Groq", url: "https://api.groq.com/openai/v1"),
  EndpointProviderPreset(name: "Cerebras", url: "https://api.cerebras.ai/v1"),
  EndpointProviderPreset(name: "NVIDIA", url: "https://integrate.api.nvidia.com/v1"),
]

let openCodeSessionHeaders = ["x-opencode-session": ProviderHeaders.sessionPlaceholder]

extension OpenAIEndpoint {
  /// The headers every request sends: the endpoint's own, plus the ones the
  /// preset at its URL requires that the user has not set themselves, so an
  /// endpoint saved before presets carried headers works too.
  var effectiveHeaders: [String: String] {
    guard let preset = EndpointNameResolution.providerPreset(forBaseURL: baseURL) else {
      return headers
    }
    return preset.headers.merging(headers) { _, own in own }
  }
}

enum EndpointNameResolution {
  static func savedName(for endpoint: OpenAIEndpoint) -> String? {
    let trimmedName = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedName.isEmpty {
      return trimmedName
    }
    return providerName(for: endpoint)
  }

  static func validationMessage(for endpoint: OpenAIEndpoint, in endpoints: [OpenAIEndpoint])
    -> String?
  {
    if let message = baseURLValidationMessage(for: endpoint) {
      return message
    }
    if let message = nameValidationMessage(for: endpoint, in: endpoints) {
      return message
    }
    return nil
  }

  static func nameValidationMessage(for endpoint: OpenAIEndpoint, in endpoints: [OpenAIEndpoint])
    -> String?
  {
    let trimmedName = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName: String
    if trimmedName.isEmpty {
      guard let fallbackName = providerName(for: endpoint) else {
        return "Specify a name for this provider."
      }
      resolvedName = fallbackName
    } else {
      resolvedName = trimmedName
    }
    if hasDuplicateName(resolvedName, excluding: endpoint.id, in: endpoints) {
      return "Another provider is already named \"\(resolvedName)\". Specify a name."
    }
    return nil
  }

  static func connectionValidationMessage(for endpoint: OpenAIEndpoint) -> String? {
    baseURLValidationMessage(for: endpoint)
  }

  private static func baseURLValidationMessage(for endpoint: OpenAIEndpoint) -> String? {
    let baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !baseURL.isEmpty else {
      return "Specify a base URL for this provider."
    }
    guard let components = URLComponents(string: baseURL),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = components.host,
      !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return "Specify a valid http or https base URL."
    }
    return nil
  }

  private static func providerName(for endpoint: OpenAIEndpoint) -> String? {
    if endpoint.kind == .chatGPT { return "ChatGPT subscription" }
    let baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if let preset = providerPreset(forBaseURL: baseURL) {
      return preset.name
    }
    return nil
  }

  static func providerPreset(forBaseURL baseURL: String) -> EndpointProviderPreset? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return endpointProviderPresets.first(where: { $0.url == trimmed })
  }

  static func matchingOAuthPreset(for endpoint: OpenAIEndpoint) -> EndpointProviderPreset? {
    let authorize = endpoint.oauthAuthorizeURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let issuer = endpoint.oauthIssuer.trimmingCharacters(in: .whitespacesAndNewlines)
    return endpointProviderPresets.first { preset in
      guard preset.authMethods.contains(.oauth) else { return false }
      guard let defaults = preset.oauthDefaults else { return false }
      if !authorize.isEmpty, !defaults.authorizeURL.isEmpty {
        return defaults.authorizeURL == authorize
      }
      return !issuer.isEmpty && defaults.issuer == issuer
    }
  }

  private static func hasDuplicateName(
    _ name: String,
    excluding endpointID: UUID,
    in endpoints: [OpenAIEndpoint]
  ) -> Bool {
    let normalized = normalizedName(name)
    return endpoints.contains { endpoint in
      guard endpoint.id != endpointID,
        let endpointName = savedName(for: endpoint)
      else { return false }
      return normalizedName(endpointName) == normalized
    }
  }

  private static func normalizedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
