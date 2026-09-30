import Foundation
import Testing

@testable import MaiCore

@Test("A Mai archive round-trips directly and from a legacy PocketMai wrapper")
func archiveRoundTripAndEmbedding() throws {
  let provider = ConfiguredProvider(
    id: "local", kind: .openAICompatible, displayName: "Local",
    baseURL: URL(string: "http://127.0.0.1:11434/v1"), apiKey: "secret")
  let prompts = ConfiguredPrompts(
    compact: "Summarize {{transcript}}",
    system: ["review": "Review carefully."],
    user: ["ship": "Ship $ARGUMENTS"])
  let agent = AgentDefinition(
    id: "reviewer", instructions: "Review carefully.", systemPrompt: "review",
    provider: "local", model: "model")
  let childRunID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  let child = AgentProcessRecord(
    process: AgentProcessInfo(
      pid: 2, parent: 1, runID: childRunID, agentID: "researcher",
      task: "Find the source", state: .completed, depth: 1,
      startedAt: Date(timeIntervalSince1970: 1_700_000_010),
      finishedAt: Date(timeIntervalSince1970: 1_700_000_020)),
    messages: [.user("Find the source"), .assistant("Found it")])
  let grandchild = AgentProcessRecord(
    process: AgentProcessInfo(
      pid: 3, parent: 2, runID: UUID(), agentID: "researcher.worker",
      task: "Read the source", state: .completed, depth: 2,
      startedAt: Date(timeIntervalSince1970: 1_700_000_012),
      finishedAt: Date(timeIntervalSince1970: 1_700_000_018)),
    messages: [.user("Read it"), .assistant("Details")],
    parentRunID: childRunID)
  let chat = AgentChat(
    id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
    title: "Portable chat",
    primaryAgent: agent,
    messages: [.system("Review carefully."), .user("Please review this."), .assistant("Done.")],
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
    subagents: [child, grandchild])
  let skill = MaiArchiveSkill(
    name: "review",
    files: [MaiArchiveSkillFile(path: "SKILL.md", data: Data("Review it.".utf8))])
  let archive = MaiArchive(
    generator: "tests",
    exportedAt: Date(timeIntervalSince1970: 1_700_000_200),
    settings: MaiArchiveSettings(
      providers: [provider], prompts: prompts, mcpServers: [], agents: [agent],
      defaultAgent: agent.id),
    chats: [chat],
    skills: [skill])

  let data = try archive.encoded()
  let decoded = try MaiArchive.decode(from: data)
  #expect(decoded == archive)
  #expect(
    decoded.chats?.first?.subagents.map { $0.messages.last?.text }
      == ["Found it", "Details"])
  #expect(decoded.chats?.first?.subagents.last?.parentRunID == childRunID)

  struct Wrapper: Encodable {
    var format = "pocketmai.settings"
    var portable: MaiArchive
  }
  let wrapped = try MaiJSONCoding.default.makeEncoder().encode(Wrapper(portable: archive))
  #expect(try MaiArchive.decode(from: wrapped) == archive)
}

@Test("Portable settings merge by identifier and prompt name without removing local values")
func archiveSettingsMerge() throws {
  let oldProvider = ConfiguredProvider(
    id: "shared", kind: .openAICompatible, displayName: "Old",
    baseURL: URL(string: "https://old.example/v1"))
  let keptProvider = ConfiguredProvider(id: "kept", kind: .hello)
  let oldAgent = AgentDefinition(
    id: "reviewer", instructions: "Old instructions", systemPrompt: "review",
    provider: "shared", model: "old")
  let keptAgent = AgentDefinition(
    id: "kept", instructions: "Keep me", systemPrompt: "kept",
    provider: "kept", model: "")
  var configuration = MaiConfiguration(
    defaultAgent: keptAgent.id,
    providers: [oldProvider, keptProvider],
    mcpServers: [ConfiguredMCPServer(id: "kept-mcp", enabled: false)],
    agents: [oldAgent, keptAgent],
    prompts: ConfiguredPrompts(
      system: ["review": "Old instructions", "kept": "Keep me"],
      user: ["local": "Local prompt"]))

  let newProvider = ConfiguredProvider(
    id: "shared", kind: .openAICompatible, displayName: "New",
    baseURL: URL(string: "https://new.example/v1"))
  let newAgent = AgentDefinition(
    id: "reviewer", instructions: "Archive instructions", systemPrompt: "review",
    provider: "shared", model: "new")
  let summary = try configuration.mergeArchiveSettings(
    MaiArchiveSettings(
      providers: [newProvider],
      prompts: ConfiguredPrompts(
        compact: "Compact {{transcript}}",
        recap: "Recap {{transcript}}",
        system: ["review": "Imported prompt"],
        user: ["remote": "Remote prompt"]),
      mcpServers: [ConfiguredMCPServer(id: "remote-mcp", enabled: false)],
      agents: [newAgent],
      defaultAgent: newAgent.id))

  #expect(configuration.providers.count == 2)
  #expect(configuration.providers.first { $0.id == "shared" }?.displayName == "New")
  #expect(configuration.providers.contains { $0.id == "kept" })
  #expect(configuration.mcpServers.map(\.id).sorted() == ["kept-mcp", "remote-mcp"])
  #expect(configuration.agents.count == 2)
  #expect(configuration.agents.first { $0.id == "reviewer" }?.model == "new")
  #expect(configuration.agents.first { $0.id == "reviewer" }?.instructions == "Imported prompt")
  #expect(configuration.agents.contains { $0.id == "kept" })
  #expect(configuration.prompts?.system["kept"] == "Keep me")
  #expect(configuration.prompts?.user["local"] == "Local prompt")
  #expect(configuration.prompts?.user["remote"] == "Remote prompt")
  #expect(configuration.prompts?.recap == "Recap {{transcript}}")
  #expect(configuration.defaultAgent == "reviewer")
  #expect(summary.providers == 1)
  #expect(summary.prompts == 4)
  #expect(summary.mcpServers == 1)
  #expect(summary.agents == 1)
}

@Test("Skill archives preserve nested files and reject paths outside their folder")
func archiveSkillCaptureAndInstall() throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appendingPathComponent(
    "mai-archive-\(UUID().uuidString)", isDirectory: true)
  defer { try? files.removeItem(at: root) }
  let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
  let source = sourceRoot.appendingPathComponent("review", isDirectory: true)
  try files.createDirectory(
    at: source.appendingPathComponent("scripts", isDirectory: true),
    withIntermediateDirectories: true)
  try Data("---\nname: review\ndescription: Review code.\n---\nDo it.\n".utf8).write(
    to: source.appendingPathComponent(AgentSkill.filename))
  let script = source.appendingPathComponent("scripts/run.sh")
  try Data("#!/bin/sh\necho review\n".utf8).write(to: script)
  try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

  let loaded = try #require(AgentSkill.load(directory: source, rootURL: sourceRoot))
  let archived = try MaiArchiveSkill(skill: loaded)
  #expect(archived.name == "review")
  #expect(archived.files.map(\.path) == ["SKILL.md", "scripts/run.sh"])
  #expect(archived.files.first { $0.path == "scripts/run.sh" }?.executable == true)

  let destination = root.appendingPathComponent("destination", isDirectory: true)
  try archived.install(in: destination)
  #expect(
    try Data(contentsOf: destination.appendingPathComponent("review/scripts/run.sh"))
      == Data("#!/bin/sh\necho review\n".utf8))
  let permissions = try files.attributesOfItem(
    atPath: destination.appendingPathComponent("review/scripts/run.sh").path)[.posixPermissions]
    as? NSNumber
  #expect(((permissions?.intValue ?? 0) & 0o111) != 0)

  let escaping = MaiArchiveSkill(
    name: "bad", files: [MaiArchiveSkillFile(path: "../outside", data: Data())])
  #expect(throws: MaiArchiveError.self) { try escaping.install(in: destination) }
  #expect(!files.fileExists(atPath: root.appendingPathComponent("outside").path))

  let duplicate = MaiArchiveSkill(
    name: "bad", files: [
      MaiArchiveSkillFile(path: "SKILL.md", data: Data()),
      MaiArchiveSkillFile(path: "SKILL.md", data: Data()),
    ])
  #expect(throws: MaiArchiveError.self) { try duplicate.validate() }
}
