import Foundation
import Testing

@testable import MaiCore

private func selectionSkill(_ name: String) -> AgentSkill {
  AgentSkill(
    name: name, description: "Use \(name).",
    directoryURL: URL(fileURLWithPath: "/skills/\(name)"), body: "Instructions for \(name).")
}

@Test("Skill approval offers only enabled skills and preserves native IDs and task arguments")
func skillSelection() throws {
  let definitions =
    [selectionSkill("review"), selectionSkill("fix")].map(MaiSkillTools.definition)
    + [ToolDefinition(name: "files_read", description: "Read a file.")]
  let call = ParsedToolCall(
    name: "skills_review", arguments: ["arguments": "parser.swift"],
    rawBlock: "original", toolCallID: "native-42")
  let selection = try #require(SkillToolSelection(call: call, definitions: definitions))
  #expect(selection.skills.map(\.name) == ["skills_review", "skills_fix"])
  let replacement = try #require(selection.selecting("skills_fix"))
  #expect(replacement.name == "skills_fix")
  #expect(replacement.argumentValues == call.argumentValues)
  #expect(replacement.toolCallID == "native-42")
  #expect(replacement.rawBlock == "original")
  #expect(selection.selecting("skills_disabled") == nil)
  #expect(selection.selecting("files_read") == nil)
  #expect(SkillToolSelection(call: replacement, definitions: [definitions[0]]) == nil)
}

@Test("Choosing a different proxied skill keeps the proxy envelope and does not nest arguments")
func proxiedSkillSelection() throws {
  let definitions = [selectionSkill("review"), selectionSkill("fix")].map(MaiSkillTools.definition)
  let arguments: [String: JSONValue] = ["arguments": .string("Fix the parser")]
  let call = ParsedToolCall(
    name: ToolProxy.callName, arguments: [:],
    argumentValues: ["name": .string("skills_review"), "arguments": .object(arguments)],
    rawBlock: "proxy", toolCallID: "call-1")
  let selection = try #require(SkillToolSelection(call: call, definitions: definitions))
  #expect(selection.proposed.name == "skills_review")
  let replacement = try #require(selection.selecting("skills_fix"))
  #expect(replacement.name == ToolProxy.callName)
  #expect(replacement.toolCallID == "call-1")
  let resolved = ToolProxy.resolveCall(
    arguments: replacement.argumentValues, definitions: definitions)
  #expect(resolved.call?.name == "skills_fix")
  #expect(resolved.call?.argumentValues == arguments)
  #expect(SkillToolSelection(call: call, definitions: []) == nil)
  #expect(
    SkillToolSelection(
      call: ParsedToolCall(name: ToolProxy.listName, arguments: [:], rawBlock: ""),
      definitions: definitions) == nil)
}

@Test("Sanitized skill names cannot register duplicate tools or resolve the wrong skill")
func skillToolNameCollisions() {
  let first = selectionSkill("code review")
  let shadowed = selectionSkill("code-review")
  let prefixed = selectionSkill("skills_code-review")
  let catalog = AgentSkillCatalog(skills: [first, shadowed, prefixed])
  #expect(catalog.modelInvocable.map(\.name) == [first.name, prefixed.name])
  #expect(MaiSkillTools.makeTools(catalog: { catalog }).count == 2)
  #expect(catalog.skill(named: "code-review")?.name == shadowed.name)
  #expect(catalog.skill(named: "skills_code-review")?.name == prefixed.name)
}
