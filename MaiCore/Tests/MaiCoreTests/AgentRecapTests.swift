import Foundation
import Testing

@testable import MaiCore

@Test("Recaps retain compacted context and tool evidence, excluding instructions and reasoning")
func recapTranscript() {
  let messages: [AgentMessage] = [
    .system("Private system instructions"),
    .developer("Private developer instructions"),
    .system("Conversation summary (compacted):\n\nEarlier goal and completed work"),
    .user("Finish the remaining task"),
    AgentMessage(
      role: .assistant,
      content: [
        .text("<think>Private reasoning</think>Running checks"),
        .toolCall(
          ToolCall(
            id: "check", name: "run_sh", arguments: .object(["command": .string("make test")]))),
      ]),
    AgentMessage(
      role: .tool, content: [.toolResult(ToolResult(callID: "check", text: "Tests passed"))]),
    .assistant("Deployment remains pending"),
  ]
  let transcript = AgentRecapPrompt.transcript(of: messages)
  #expect(transcript.contains("Earlier goal and completed work"))
  #expect(transcript.contains("Finish the remaining task"))
  #expect(transcript.contains("make test"))
  #expect(transcript.contains("Tests passed"))
  #expect(transcript.contains("Deployment remains pending"))
  #expect(!transcript.contains("Private"))
  #expect(AgentRecapPrompt.transcript(of: [.system("Instructions only")]).isEmpty)
}

@Test("Recap templates persist, require context, and default when empty or absent")
func recapConfiguration() throws {
  let custom = "Status report:\n{{transcript}}"
  let configuration = MaiConfiguration(prompts: ConfiguredPrompts(recap: custom))
  try configuration.validate()
  #expect(
    try JSONDecoder().decode(MaiConfiguration.self, from: configuration.encoded()) == configuration)
  #expect(try JSONDecoder().decode(ConfiguredPrompts.self, from: Data("{}".utf8)).recap == nil)
  #expect(
    AgentRecapPrompt.render(transcript: "Evidence", template: custom) == "Status report:\nEvidence")
  #expect(
    AgentRecapPrompt.render(transcript: "Evidence", template: " \n")
      == AgentRecapPrompt.render(transcript: "Evidence"))
  #expect(
    throws: MaiConfigurationError.missingPromptPlaceholder(
      prompt: "recap", placeholder: "{{transcript}}")
  ) {
    try MaiConfiguration(prompts: ConfiguredPrompts(recap: "Missing context")).validate()
  }
}
