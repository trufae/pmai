import Foundation
import Testing

@testable import MaiCore

@Test("Model selectors preserve model syntax and reject empty components")
func providerModelSelection() throws {
  let bare = try ModelSelection("org/model:tag", currentProvider: "local")
  #expect(bare.provider == "local")
  #expect(bare.model == "org/model:tag")
  let qualified = try ModelSelection("remote::org/model:tag", currentProvider: "local")
  #expect(qualified.provider == "remote")
  #expect(qualified.model == "org/model:tag")
  #expect(
    try ModelSelection("remote::model::part", currentProvider: "local").model == "model::part")
  for selector in ["", "remote::", "::model"] {
    #expect(throws: MaiConfigurationError.self) {
      try ModelSelection(selector, currentProvider: "local")
    }
  }
}

@Test("Configured provider default models survive JSON and reach the runtime descriptor")
func configuredProviderDefaultModel() async throws {
  let configured = ConfiguredProvider(id: "local", kind: .hello, defaultModel: "model-for-local")
  let decoded = try JSONDecoder().decode(
    ConfiguredProvider.self, from: JSONEncoder().encode(configured))
  #expect(decoded.defaultModel == "model-for-local")
  let registry = PluginRegistry()
  try await registry.install(MaiCoreBuiltinsPlugin())
  let provider = try await registry.makeProvider(from: decoded, environment: [:])
  #expect(provider.descriptor.defaultModel == "model-for-local")
}

@Test("Renaming providers preserves connection settings and updates task agents")
func providerRenameConfiguration() throws {
  let original = ConfiguredProvider(
    id: "remote", kind: .openAICompatible, displayName: "My endpoint",
    baseURL: URL(string: "http://localhost:1234/v1"), apiKey: "secret",
    apiKeyEnvironment: "REMOTE_KEY", apiKeyFile: "/key",
    headers: ["x-custom": "value"], headerEnvironment: ["x-token": "TOKEN"],
    timeout: 73, options: ["custom": .bool(true)])
  var configuration = MaiConfiguration(
    taskAgents: TaskAgentAssignments(compact: "summary"),
    providers: [original, ConfiguredProvider(id: "local", kind: .hello)],
    agents: [
      AgentDefinition(id: "main", provider: "remote", model: "model"),
      AgentDefinition(id: "summary", provider: "remote", model: "summary"),
      AgentDefinition(id: "other", provider: "local", model: "other"),
    ])
  try configuration.renameProvider("remote", to: "renamed")
  var expected = original
  expected.id = "renamed"
  #expect(configuration.providers[0] == expected)
  #expect(configuration.agents.map(\.provider) == ["renamed", "renamed", "local"])
  #expect(configuration.taskAgents.compact == "summary")
  try configuration.validate()
  let unchanged = configuration
  for destination in ["local", "", "bad name", "bad::name"] {
    #expect(throws: MaiConfigurationError.self) {
      try configuration.renameProvider("renamed", to: destination)
    }
    #expect(configuration == unchanged)
  }
  #expect(throws: MaiConfigurationError.unknownProvider("missing")) {
    try configuration.renameProvider("missing", to: "new")
  }
}

@Test("Runtime provider rename replaces the catalog and agent references")
func providerRenameRuntime() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider(id: "old"))
  try await runtime.register(agent: AgentDefinition(id: "main", provider: "old", model: "hello"))
  try await runtime.renameProvider("old", to: HelloProvider(id: "new"))
  #expect(await runtime.availableProviders().map(\.id) == ["new"])
  #expect(await runtime.availableAgents().first?.provider == "new")
  let result = try await runtime.run(
    AgentRequest(
      provider: "new", model: "hello", messages: [.user("Check renamed connection")]))
  #expect(!result.transcript.isEmpty)
}

@Test("An active request follows a provider rename at its next call")
func providerRenameActiveRequest() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider(id: "old", prefix: "Old connection"))
  try await runtime.register(HelloProvider(id: "occupied"))
  await #expect(throws: AgentRuntimeError.providerAlreadyRegistered("occupied")) {
    try await runtime.renameProvider("old", to: HelloProvider(id: "occupied"))
  }
  #expect(await runtime.availableProviders().contains { $0.id == "old" })
  let result = try await runtime.run(
    AgentRequest(provider: "old", model: "hello", messages: [.user("Still running")])
  ) { event in
    if case .started = event {
      do {
        try await runtime.renameProvider(
          "old", to: HelloProvider(id: "new", prefix: "New connection"))
      } catch {
        Issue.record("Rename failed: \(error)")
      }
    }
  }
  #expect(result.provider == "new")
  #expect(result.response.text == "New connection: Still running")
}
