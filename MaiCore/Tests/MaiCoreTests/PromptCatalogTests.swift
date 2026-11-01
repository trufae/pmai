import Foundation
import Testing

@testable import MaiCore

// Prompts run by name: `/name` in the iOS app, `$name` in pmai. The catalog
// resolves system prompts, user prompts, MaiCore's builtin prompts, and skills
// in that order, and a user prompt takes the words after its name the way a
// skill does.

@Test("A prompt's command name is one word without slashes")
func promptCommandNames() {
  #expect(PromptSlashCommand.commandName(for: "  Code review ") == "Code-review")
  #expect(PromptSlashCommand.commandName(for: "a/b") == "a-b")
  #expect(PromptSlashCommand.commandName(for: "--") == "prompt")
  #expect(UserPrompt(name: "", text: "x").displayName == "Untitled")
}

@Test("Both / and $ introduce a prompt line; the rest is the arguments")
func promptLineParsing() {
  #expect(
    PromptSlashCommand.parse("/commit fix the build")
      == .init(command: "commit", remainder: "fix the build"))
  #expect(PromptSlashCommand.parse("$commit") == .init(command: "commit", remainder: ""))
  #expect(PromptSlashCommand.parse("  $tldr  now ") == .init(command: "tldr", remainder: "now"))
  #expect(PromptSlashCommand.parse("commit") == nil)
  #expect(PromptSlashCommand.fragment(in: "$co") == "co")
  #expect(PromptSlashCommand.visualText(commandName: "tldr", remainder: " x ") == "/tldr x")
}

@Test("A user prompt takes its arguments at $ARGUMENTS, or after the text")
func userPromptMessages() {
  let placeholder = UserPrompt(name: "commit", text: "Commit message: $ARGUMENTS\nShort.")
  #expect(placeholder.message(arguments: " one line ") == "Commit message: one line\nShort.")
  #expect(placeholder.message(arguments: "") == "Commit message: \nShort.")
  let plain = UserPrompt(name: "tldr", text: "Summarise.")
  #expect(plain.message(arguments: "the last reply") == "Summarise.\n\nthe last reply")
  #expect(plain.message(arguments: "") == "Summarise.")
  #expect(UserPrompt(name: "empty", text: " ").message(arguments: "hello") == "hello")
}

@Test("The catalog looks names up case-insensitively in kind order, skills included")
func promptCatalogLookup() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("prompt-catalog-\(UUID().uuidString)", isDirectory: true)
  let skillDirectory = root.appendingPathComponent("review", isDirectory: true)
  try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try """
  ---
  name: review
  description: Review a diff
  ---
  Look at $ARGUMENTS and report defects.
  """.write(
    to: skillDirectory.appendingPathComponent(AgentSkill.filename), atomically: true,
    encoding: .utf8)
  let skills = AgentSkillCatalog.load(directory: root)
  #expect(skills.count == 1)

  let catalog = PromptCatalog(
    system: [SystemPrompt(name: "Reviewer", text: "You review.")],
    user: [UserPrompt(name: "tldr", text: "Mine."), UserPrompt(name: "Review", text: "user one")],
    skills: skills)

  // A user prompt hides the builtin of the same name; a system prompt comes first.
  #expect(catalog.entry(named: "TLDR")?.kind == .user)
  #expect(catalog.entry(named: "goal")?.kind == .builtin)
  #expect(catalog.entry(named: "reviewer")?.kind == .system)
  #expect(catalog.entry(named: "review")?.kind == .user)
  #expect(catalog.entry(named: "review")?.message(arguments: "x") == "user one\n\nx")
  #expect(catalog.entry(named: "reviewer")?.message(arguments: "x") == nil)
  #expect(catalog.entry(named: "missing") == nil)
  #expect(catalog.entry(named: "") == nil)
  #expect(catalog.entries(of: .skill).map(\.commandName) == ["review"])
  #expect(catalog.entries(of: .skill).first?.summary == "Review a diff")
  #expect(
    catalog.entries(of: .builtin).map(\.commandName) == ["goal", "newapp", "tldr", "followup"])
  let skillEntry = try #require(catalog.entries(of: .skill).first)
  let restored = try JSONDecoder().decode(PromptCatalog.self, from: JSONEncoder().encode(catalog))
  #expect(restored == catalog)
  #expect(
    skillEntry.message(arguments: "this diff")?.contains("Look at this diff and report defects.")
      == true)
  #expect(
    catalog.entries(matching: "rev").map(\.id) == [
      "system:reviewer", "user:review", "skill:review",
    ])
  #expect(PromptCatalog.summary(of: "\n\n  first line here\nsecond", limit: 5) == "first…")
}

@Test("Local and remote prompts remain callable when names collide")
func promptCatalogRemoteNames() throws {
  let local = PromptCatalog(user: [UserPrompt(name: "build", text: "Local $ARGUMENTS")], builtins: [])
  var remote = PromptCatalog(user: [UserPrompt(name: "BUILD", text: "Remote $ARGUMENTS")], builtins: [])
  remote.entries.append(.init(kind: .user, name: "test", commandName: "test", text: "",
    invocation: "test"))
  let catalog = local.merging(remote, source: "Worker")
  #expect(catalog.entry(named: "build")?.message(arguments: "one") == "Local one")
  #expect(catalog.entry(named: "remote:build")?.message(arguments: "two") == "Remote two")
  #expect(catalog.entry(named: "test")?.message(arguments: "three") == "/test three")
  #expect(catalog.entries(matching: "build").count == 2)
  let restored = try JSONDecoder().decode(PromptCatalog.self, from: JSONEncoder().encode(catalog))
  #expect(restored == catalog)
}

@Test("Stored names resolve exactly, or by case when that leaves one")
func promptNameResolution() {
  let names = ["Commit", "commit", "Tldr"]
  #expect(PromptCatalog.resolvedName("commit", among: names) == "commit")
  #expect(PromptCatalog.resolvedName("tldr", among: names) == "Tldr")
  #expect(PromptCatalog.resolvedName("COMMIT", among: names) == nil)
  #expect(PromptCatalog.resolvedName("goal", among: names) == nil)
}

@Test("User prompts live under prompts.user and round-trip through the configuration")
func configuredUserPrompts() throws {
  var configuration = MaiConfiguration(
    defaultAgent: "main",
    providers: [ConfiguredProvider(id: "hello", kind: .hello)],
    agents: [
      AgentDefinition(
        id: "main", instructions: "Be brief.", provider: .init(rawValue: "hello"), model: "hello")
    ])
  #expect(configuration.userPrompts.isEmpty)
  let created = configuration.setUserPrompt("commit", text: "Commit: $ARGUMENTS")
  #expect(created)
  let createdAgain = configuration.setUserPrompt("commit", text: "Commit again: $ARGUMENTS")
  #expect(!createdAgain)
  #expect(configuration.userPromptName(matching: "COMMIT") == "commit")
  #expect(configuration.userPromptName(matching: "nope") == nil)
  #expect(configuration.userPrompts.map(\.name) == ["commit"])
  #expect(configuration.userPrompts.first?.id == configuration.userPrompts.first?.id)
  #expect(
    configuration.promptCatalog().entry(named: "commit")?.message(arguments: "x")
      == "Commit again: x")

  let data = try JSONEncoder().encode(configuration)
  let decoded = try JSONDecoder().decode(MaiConfiguration.self, from: data)
  #expect(decoded.prompts?.user == ["commit": "Commit again: $ARGUMENTS"])
  try decoded.validate()

  let removed = configuration.removeUserPrompt("commit")
  #expect(removed)
  let removedAgain = configuration.removeUserPrompt("commit")
  #expect(!removedAgain)
  #expect(configuration.promptCatalog().entry(named: "commit") == nil)

  var invalid = configuration
  invalid.setUserPrompt(" ", text: "x")
  #expect(throws: MaiConfigurationError.self) { try invalid.validate() }
}
