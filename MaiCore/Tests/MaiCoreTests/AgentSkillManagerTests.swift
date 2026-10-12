import Foundation
import Testing

@testable import MaiCore

@Test("Managing skills preserves metadata and supporting files and rejects duplicate names")
func managedSkillLifecycle() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let skill = try AgentSkillManager.create(
    name: "writer's notes", description: "Summarize: 'notes'\n---\nKeep details.",
    prompt: "Write a summary for $ARGUMENTS.\n---\nKeep the format.", in: root)
  #expect(skill.description == "Summarize: 'notes'\n---\nKeep details.")
  #expect(skill.name == "writer's notes")
  let resource = skill.directoryURL.appendingPathComponent("reference.txt")
  try "Keep me".write(to: resource, atomically: true, encoding: .utf8)
  let text = try String(contentsOf: skill.fileURL, encoding: .utf8)
    .replacingOccurrences(
      of: "\n---\n",
      with:
        "\nmetadata:\n  author: someone\n  tags: [one, two]\ndisable-model-invocation: true\n---\n")
  try text.write(to: skill.fileURL, atomically: true, encoding: .utf8)
  let updated = try AgentSkillManager.update(
    skill, description: "Edited description", prompt: "New instructions.\n---\nDetails.")
  #expect(updated.body == "New instructions.\n---\nDetails.")
  #expect(updated.description == "Edited description")
  #expect(!updated.isModelInvocable)
  #expect(
    try String(contentsOf: updated.fileURL, encoding: .utf8).contains(
      "metadata:\n  author: someone\n  tags: [one, two]"))
  #expect(try String(contentsOf: resource, encoding: .utf8) == "Keep me")
  #expect(throws: AgentSkillManagerError.alreadyExists(skill.name)) {
    try AgentSkillManager.create(name: skill.name, description: "Other", prompt: "Other", in: root)
  }
  #expect(throws: AgentSkillManagerError.missingPrompt) {
    try AgentSkillManager.update(updated, description: "Other", prompt: "  ")
  }
  #expect(AgentSkill.load(directory: skill.directoryURL)?.body == updated.body)
  try AgentSkillManager.remove(updated)
  #expect(AgentSkillCatalog.load(directories: [root]).isEmpty)
  #expect(!FileManager.default.fileExists(atPath: resource.path))
}

@Test("Invalid names, archive paths and symlink edits cannot reach outside a skills folder")
func managedSkillBoundaries() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  for name in ["../escape", "/absolute", ".", "..", ".hidden", "bad\\name", "bad\nname"] {
    #expect(throws: AgentSkillManagerError.invalidName) {
      try AgentSkillManager.create(
        name: name, description: "Description", prompt: "Prompt", in: root)
    }
  }
  let archive = MaiArchiveSkill(
    name: "unsafe",
    files: [
      .init(path: "SKILL.md", data: Data("Instructions".utf8)),
      .init(path: "../escape.txt", data: Data("escape".utf8)),
    ])
  #expect(throws: MaiArchiveError.self) { try AgentSkillManager.install(archive, in: root) }
  #expect(!FileManager.default.fileExists(atPath: root.path))
  let skill = try AgentSkillManager.create(
    name: "safe", description: "Description", prompt: "Original", in: root)
  let outside = root.appendingPathComponent("outside.txt")
  try "Untouched".write(to: outside, atomically: true, encoding: .utf8)
  try FileManager.default.removeItem(at: skill.fileURL)
  try FileManager.default.createSymbolicLink(at: skill.fileURL, withDestinationURL: outside)
  #expect(throws: AgentSkillManagerError.outsideRoot) {
    try AgentSkillManager.saveDocument("Changed", for: skill)
  }
  #expect(try String(contentsOf: outside, encoding: .utf8) == "Untouched")
}

@Test("Imports retain executable resources, reject duplicates, and leave no partial skill")
func managedSkillImport() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = MaiArchiveSkill(
    name: "review",
    files: [
      .init(
        path: "SKILL.md",
        data: Data(
          AgentSkillManager.document(
            name: "review", description: "Review changes", prompt: "Run scripts/check.sh"
          ).utf8)),
      .init(path: "scripts/check.sh", data: Data("#!/bin/sh\nexit 0\n".utf8), executable: true),
    ])
  let skill = try AgentSkillManager.install(archive, in: root)
  #expect(
    FileManager.default.isExecutableFile(
      atPath: skill.directoryURL.appendingPathComponent("scripts/check.sh").path))
  #expect(throws: AgentSkillManagerError.alreadyExists("review")) {
    try AgentSkillManager.install(archive, in: root)
  }
  let invalid = MaiArchiveSkill(
    name: "broken",
    files: [
      .init(path: "SKILL.md", data: Data("Prompt".utf8)),
      .init(path: "file", data: Data()), .init(path: "file/child", data: Data()),
    ])
  #expect(throws: (any Error).self) { try AgentSkillManager.install(invalid, in: root) }
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("broken").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["review"])
}
