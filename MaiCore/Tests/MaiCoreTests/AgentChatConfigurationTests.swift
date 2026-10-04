import Foundation
import Testing

@testable import MaiCore

@Test(
  "Chat inference snapshots keep endpoints, provider options, task models and subagent definitions")
func chatConfigurationRoundTrip() throws {
  let primary = AgentDefinition(id: "main", provider: "remote", model: "chat")
  let worker = AgentDefinition(
    id: "worker", instructions: "Saved instructions", systemPrompt: "worker-prompt",
    provider: "remote", model: "worker",
    subagentNames: ["nested"])
  let nested = AgentDefinition(id: "nested", provider: "remote", model: "nested")
  let provider = ConfiguredProvider(
    id: "remote", kind: .openAICompatible,
    baseURL: URL(string: "https://configured.example/v1"), defaultModel: "original-default",
    apiKey: "do-not-copy",
    apiKeyEnvironment: "REMOTE_KEY",
    headers: ["x-session": "{{session}}", "Authorization": "Bearer private-header"],
    timeout: 91, options: ["custom": .bool(true)])
  let configuration = MaiConfiguration(
    taskAgents: .init(compact: "worker", tool: "nested", approval: "worker"),
    providers: [provider], agents: [primary, worker, nested])
  let snapshot = AgentChatConfiguration(
    configuration: configuration,
    providerBaseURLs: ["remote": URL(string: "https://effective.example/v1")!])
  let chat = AgentChat(primaryAgent: primary, runtimeConfiguration: snapshot)
  let data = try MaiJSONCoding.default.makeEncoder().encode(chat)
  #expect(!String(decoding: data, as: UTF8.self).contains("do-not-copy"))
  #expect(!String(decoding: data, as: UTF8.self).contains("private-header"))
  let loaded = try MaiJSONCoding.default.makeDecoder().decode(AgentChat.self, from: data)
  #expect(loaded.runtimeConfiguration == snapshot)

  var changed = configuration
  changed.providers[0].baseURL = URL(string: "https://changed.example/v1")
  changed.providers[0].defaultModel = "new-default"
  changed.providers[0].apiKey = "rotated-key"
  changed.providers[0].apiKeyEnvironment = "NEW_KEY"
  changed.providers[0].headers["Authorization"] = "Bearer rotated-header"
  changed.agents = [primary]
  changed.taskAgents = .init()
  let restored = snapshot.applying(to: changed)
  #expect(restored.providers[0].baseURL?.absoluteString == "https://effective.example/v1")
  #expect(restored.providers[0].defaultModel == "new-default")
  #expect(restored.providers[0].apiKey == "rotated-key")
  #expect(restored.providers[0].apiKeyEnvironment == "NEW_KEY")
  #expect(restored.providers[0].headers["x-session"] == "{{session}}")
  #expect(restored.providers[0].headers["Authorization"] == "Bearer rotated-header")
  #expect(restored.providers[0].timeout == 91)
  #expect(restored.providers[0].options == provider.options)
  #expect(restored.agents == configuration.agents)
  #expect(restored.taskAgents == configuration.taskAgents)

  let missing = snapshot.applying(to: MaiConfiguration())
  #expect(missing.providers[0].apiKey == nil)
  #expect(missing.providers[0].defaultModel == "original-default")
  #expect(missing.providers[0].apiKeyEnvironment == "REMOTE_KEY")
  #expect(missing.agents == configuration.agents)
  #expect(missing.prompts?.system["worker-prompt"] == "Saved instructions")
  try missing.validate()

  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object["runtimeConfiguration"] = nil
  let legacy = try MaiJSONCoding.default.makeDecoder().decode(
    AgentChat.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(legacy.runtimeConfiguration == nil)
  #expect(legacy.primaryAgent == primary)
}
