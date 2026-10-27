import Foundation
import Testing

@testable import MaiCore

@Test("Voice and voiceover are separate named prompts without model assignments")
func voicePromptCatalogDefaults() {
  var configuration = MaiConfiguration()
  #expect(configuration.promptCatalog().entry(named: "voice")?.text == VoicePrompt.instructions)
  #expect(configuration.systemPrompt(named: "VOICEOVER")?.text == AgentTask.voiceover.instructions)
  configuration.setSystemPrompt("voice", text: "Custom conversation instructions")
  #expect(configuration.systemPrompt(named: "voice")?.text == "Custom conversation instructions")
  #expect(configuration.systemPrompt(named: "voiceover")?.text == AgentTask.voiceover.instructions)
  let removed = configuration.removeSystemPrompt("voice")
  #expect(removed)
  #expect(configuration.systemPrompt(named: "voice")?.text == VoicePrompt.instructions)
}

@Test("Legacy voice instructions migrate to the named prompt and round-trip")
func voicePromptLegacyMigration() throws {
  let configuration = try JSONDecoder().decode(
    MaiConfiguration.self, from: Data(#"{"voice":{"language":"ca-ES","instructions":"Legacy\nvoice rules"}}"#.utf8))
  #expect(configuration.prompts?.system["voice"] == "Legacy\nvoice rules")
  #expect(configuration.voice.language == "ca-ES")
  let encoded = try configuration.encoded()
  let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  #expect((object["voice"] as? [String: Any])?["instructions"] == nil)
  #expect(!ConfiguredVoice.settingNames.contains("instructions"))
  let restored = try JSONDecoder().decode(MaiConfiguration.self, from: encoded)
  #expect(restored.systemPrompt(named: "voice")?.text == "Legacy\nvoice rules")
}

@Test("A configured named voice prompt wins over legacy audio instructions")
func voicePromptMigrationPrecedence() throws {
  for prompt in ["New voice rules", ""] {
    let data = try JSONSerialization.data(withJSONObject: [
      "voice": ["instructions": "Legacy rules"], "prompts": ["system": ["Voice": prompt]],
    ])
    let configuration = try JSONDecoder().decode(MaiConfiguration.self, from: data)
    #expect(configuration.systemPrompt(named: "voice")?.text == prompt)
    #expect(configuration.systemPrompts.filter { $0.name.lowercased() == "voice" }.count == 1)
  }
}

@Test("Legacy voice customization replaces a generated task's built-in prompt")
func voicePromptMigrationGeneratedDefault() throws {
  let data = try JSONSerialization.data(withJSONObject: [
    "voice": ["instructions": "Legacy custom speech rules"],
    "prompts": ["system": ["voice": VoicePrompt.instructions]],
    "agents": [["id": "speaker", "provider": "hello", "model": "hello",
                 "systemPrompt": "voice", "instructions": VoicePrompt.instructions]],
  ] as [String: Any])
  let configuration = try JSONDecoder().decode(MaiConfiguration.self, from: data)
  #expect(configuration.prompts?.system["voice"] == "Legacy custom speech rules")
  #expect(configuration.agents[0].instructions == "Legacy custom speech rules")
}

@Test("Built-in speech prompts can be assigned to agents and saved")
func voicePromptAssignment() throws {
  var configuration = MaiConfiguration(
    providers: [.init(id: "hello", kind: .hello)],
    agents: [.init(id: "speaker", instructions: "Old instructions", provider: "hello", model: "hello")])
  let assigned = configuration.assignSystemPrompt("VOICE", to: "speaker")
  #expect(assigned)
  #expect(configuration.agents[0].systemPrompt == "voice")
  #expect(configuration.agents[0].instructions == VoicePrompt.instructions)
  try configuration.validate()
  let restored = try JSONDecoder().decode(MaiConfiguration.self, from: configuration.encoded())
  #expect(restored.agents[0].instructions == restored.prompts?.system["voice"])
}

@Test("Generated speech task agents share their named prompts without merging their roles")
func voicePromptTaskAssignments() throws {
  let main = AgentDefinition(id: "main", provider: "hello", model: "hello")
  var configuration = MaiConfiguration(
    providers: [.init(id: "hello", kind: .hello)], agents: [main],
    prompts: .init(system: ["voice": "Custom conversation rules"]))
  for task in [AgentTask.voice, .voiceover] {
    try configuration.assignTask(task, selector: "hello::speech", current: main)
    let agent = try #require(configuration.agents.first { $0.id == configuration.taskAgents[task] })
    #expect(agent.systemPrompt == task.rawValue)
    #expect(agent.instructions == configuration.systemPrompt(named: task.rawValue)?.text)
  }
  configuration.setSystemPrompt("voice", text: "Updated conversation rules")
  #expect(configuration.agents.first { $0.id == configuration.taskAgents.voice }?.instructions == "Updated conversation rules")
  #expect(configuration.systemPrompt(named: "voiceover")?.text == AgentTask.voiceover.instructions)
}
