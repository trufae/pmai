import Foundation
import MaiCore
import Testing

@testable import MaiDocuments

@Test("Skill zips may be flat or wrapped and retain resources without overwriting skills")
func skillZipLayouts() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let definition = Data(
    AgentSkillManager.document(
      name: "review", description: "Review a change", prompt: "Use references/guide.md"
    ).utf8)
  for prefix in ["", "download/skills/review/", ".pmai/skills/review/"] {
    let zip = ZipArchiveWriter.archive(entries: [
      (prefix + "SKILL.md", definition), (prefix + "references/guide.md", Data("Guide".utf8)),
      ("__MACOSX/._SKILL.md", Data()),
    ])
    let archive = try SkillArchiveImporter.archive(in: zip)
    let destination = root.appendingPathComponent(UUID().uuidString)
    let skill = try AgentSkillManager.install(archive, in: destination)
    #expect(skill.description == "Review a change")
    #expect(
      try String(
        contentsOf: skill.directoryURL.appendingPathComponent("references/guide.md"),
        encoding: .utf8) == "Guide")
    #expect(throws: AgentSkillManagerError.alreadyExists("review")) {
      try AgentSkillManager.install(archive, in: destination)
    }
  }
}

@Test("Skill zips reject traversal, multiple definitions, and oversized declared output")
func skillZipValidation() throws {
  let definition = Data("---\nname: review\ndescription: Review\n---\nInstructions".utf8)
  let traversal = ZipArchiveWriter.archive(entries: [
    ("review/SKILL.md", definition), ("review/../../outside.txt", Data("escape".utf8)),
  ])
  #expect(throws: MaiArchiveError.self) { try SkillArchiveImporter.archive(in: traversal) }
  let multiple = ZipArchiveWriter.archive(entries: [
    ("one/SKILL.md", definition), ("two/SKILL.md", definition),
  ])
  #expect(throws: SkillArchiveImporter.ImportError.multipleSkills) {
    try SkillArchiveImporter.archive(in: multiple)
  }
  #expect(throws: SkillArchiveImporter.ImportError.missingSkill) {
    try SkillArchiveImporter.archive(in: ZipArchiveWriter.archive(entries: []))
  }
  #expect(throws: SkillArchiveImporter.ImportError.missingSkill) {
    try SkillArchiveImporter.archive(
      in: ZipArchiveWriter.archive(entries: [("README.md", Data("No skill".utf8))]))
  }
  #expect(throws: ZipArchiveError.tooLarge) {
    try ZipArchiveReader.entries(
      in: ZipArchiveWriter.archive(entries: [("SKILL.md", definition)]),
      maximumUncompressedBytes: 10)
  }
}
