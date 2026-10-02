import Foundation

/// The inference setup used by a chat, independent of installation defaults.
/// API key values stay in the current configuration/environment; references to
/// environment variables and key files survive if a provider is later removed.
public struct AgentChatConfiguration: Codable, Equatable, Sendable {
  public var providers: [ConfiguredProvider]
  public var agents: [AgentDefinition]
  public var taskAgents: TaskAgentAssignments

  public init(configuration: MaiConfiguration, providerBaseURLs: [String: URL] = [:]) {
    providers = configuration.providers.map { configured in
      var provider = configured
      provider.apiKey = nil
      provider.headers = provider.headers.filter { !Self.isCredentialHeader($0.key) }
      if let url = providerBaseURLs[provider.id] { provider.baseURL = url }
      return provider
    }
    agents = configuration.agents
    taskAgents = configuration.taskAgents
  }

  /// Restores definitions without rewriting shared defaults or reapplying
  /// named prompts over the instructions saved with each agent.
  public func applying(to configuration: MaiConfiguration) -> MaiConfiguration {
    var restored = configuration
    for var provider in providers {
      if let index = restored.providers.firstIndex(where: { $0.id == provider.id }) {
        let current = restored.providers[index]
        provider.apiKey = current.apiKey
        provider.apiKeyEnvironment = current.apiKeyEnvironment
        provider.apiKeyFile = current.apiKeyFile
        provider.headers = provider.headers.filter { !Self.isCredentialHeader($0.key) }
        for (name, value) in current.headers where Self.isCredentialHeader(name) {
          provider.headers[name] = value
        }
        provider.headerEnvironment = provider.headerEnvironment.filter {
          !Self.isCredentialHeader($0.key)
        }
        for (name, value) in current.headerEnvironment where Self.isCredentialHeader(name) {
          provider.headerEnvironment[name] = value
        }
        restored.providers[index] = provider
      } else {
        provider.apiKey = nil
        provider.headers = provider.headers.filter { !Self.isCredentialHeader($0.key) }
        restored.providers.append(provider)
      }
    }
    for agent in agents {
      if let index = restored.agents.firstIndex(where: { $0.id == agent.id }) {
        restored.agents[index] = agent
      } else {
        restored.agents.append(agent)
      }
      if let name = agent.systemPrompt {
        var prompts = restored.prompts ?? ConfiguredPrompts()
        prompts.system[name] = agent.instructions
        restored.prompts = prompts
      }
    }
    restored.taskAgents = taskAgents
    return restored
  }

  private static func isCredentialHeader(_ name: String) -> Bool {
    ["authorization", "proxy-authorization", "x-api-key", "api-key", "cookie"]
      .contains(name.lowercased())
  }
}
