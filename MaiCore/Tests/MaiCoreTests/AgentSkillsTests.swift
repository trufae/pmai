import Foundation
import Testing

@testable import MaiCore

// Skills are folders with a SKILL.md: front matter names and describes them,
// the body is what the model follows. pmai reads the project's .pmai/skills
// and ~/.pmai/skills, offers each as a skills_<name> tool, and /skills prompt
// sends an enabled skill as a message.

@Test("Front matter yields the scalar fields and the body; quoting and block scalars are read")
func frontMatterParsing() {
  let parsed = AgentSkillFrontMatter.parse(
    """
    ---
    name: code-review
    description: "Review a diff: report only what is wrong"
    argument-hint: '[PR number]'
    long: |
      first line
        indented line
    folded: >
      one
      two

      three
    metadata:
      author: someone
    disable-model-invocation: true
    ---
    # Heading

    Body text.
    """)
  #expect(parsed.fields["name"] == "code-review")
  #expect(parsed.fields["description"] == "Review a diff: report only what is wrong")
  #expect(parsed.fields["argument-hint"] == "[PR number]")
  #expect(parsed.fields["long"] == "first line\n  indented line")
  #expect(parsed.fields["folded"] == "one two\nthree")
  #expect(parsed.fields["metadata"] == nil)
  #expect(parsed.fields["disable-model-invocation"] == "true")
  #expect(parsed.body.trimmingCharacters(in: .whitespacesAndNewlines) == "# Heading\n\nBody text.")

  // No front matter: the whole file is the body.
  let plain = AgentSkillFrontMatter.parse("# Just instructions\n\nDo it.")
  #expect(plain.fields.isEmpty)
  #expect(plain.body == "# Just instructions\n\nDo it.")

  // An unterminated fence is not front matter either.
  let open = AgentSkillFrontMatter.parse("---\nname: x\nno end")
  #expect(open.fields.isEmpty)
  #expect(open.body == "---\nname: x\nno end")
}

@Test(
  "A catalog lists skill folders by name; the project shadows the home and folders without SKILL.md are skipped"
)
func catalogDiscovery() throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appendingPathComponent(
    "skills-\(UUID().uuidString)", isDirectory: true)
  defer { try? files.removeItem(at: root) }
  let project = root.appendingPathComponent("project", isDirectory: true)
  let home = root.appendingPathComponent("home", isDirectory: true)
  try writeSkill(
    in: project, folder: "aicommit",
    text: "---\nname: aicommit\ndescription: Write a commit message.\n---\nProject version.")
  try writeSkill(
    in: home, folder: "aicommit",
    text: "---\nname: aicommit\ndescription: Home version.\n---\nHome version.")
  try writeSkill(
    in: home, folder: "review",
    text: "---\ndescription: Review the diff.\ndisable-model-invocation: yes\n---\nReview it.")
  try writeSkill(in: home, folder: "bare", text: "# Bare skill\n\nNo front matter at all.")
  try files.createDirectory(
    at: home.appendingPathComponent("not-a-skill"), withIntermediateDirectories: true)
  try "stray".write(
    to: home.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

  let catalog = AgentSkillCatalog.load(directories: [project, home])
  #expect(catalog.skills.map(\.name) == ["aicommit", "bare", "review"])

  let commit = try #require(catalog.skill(named: "AICOMMIT"))
  #expect(commit.body == "Project version.")
  #expect(commit.rootURL.lastPathComponent == "project")
  #expect(commit.isModelInvocable)
  #expect(commit.toolName == "skills_aicommit")
  #expect(catalog.skill(named: "skills_aicommit")?.name == "aicommit")

  let review = try #require(catalog.skill(named: "review"))
  #expect(review.name == "review")  // the folder name when the front matter has none
  #expect(review.description == "Review the diff.")
  #expect(!review.isModelInvocable)
  #expect(catalog.modelInvocable.map(\.name) == ["aicommit", "bare"])

  let bare = try #require(catalog.skill(named: "bare"))
  #expect(bare.description == "Bare skill")
  #expect(bare.body.hasPrefix("# Bare skill"))
  #expect(catalog.skill(named: "not-a-skill") == nil)
  #expect(AgentSkillCatalog.load(directories: [root.appendingPathComponent("missing")]).isEmpty)
}

@Test("The prompt wraps the body in a skill envelope and places the arguments where the body asks")
func promptRendering() {
  let skill = AgentSkill(
    name: "fix",
    description: "Fix it.",
    directoryURL: URL(fileURLWithPath: "/tmp/skills/fix", isDirectory: true),
    body: "Read AGENTS.md and fix the bug. Write report.md.")
  #expect(
    skill.prompt().hasPrefix("<skill name=\"fix\" directory=\"/tmp/skills/fix\">\n"))
  #expect(skill.prompt().contains("Project paths, including AGENTS.md and output files, are relative to the workspace"))
  #expect(skill.prompt().hasSuffix("Read AGENTS.md and fix the bug. Write report.md.\n</skill>"))
  #expect(skill.prompt(arguments: " in parser.c ").hasSuffix("</skill>\n\nin parser.c"))

  var templated = skill
  templated.body = "Fix $ARGUMENTS and nothing else."
  let rendered = templated.prompt(arguments: "the parser")
  #expect(rendered.contains("Fix the parser and nothing else."))
  #expect(rendered.hasSuffix("</skill>\n\nSkill invocation arguments:\nthe parser"))
  #expect(templated.prompt().contains("Fix  and nothing else."))
}

@Test(
  "Skill tools carry the skill's description, answer with the instructions, and read the file afresh"
)
func skillTools() async throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appendingPathComponent(
    "skill-tools-\(UUID().uuidString)", isDirectory: true)
  defer { try? files.removeItem(at: root) }
  try writeSkill(
    in: root, folder: "my skill",
    text: "---\nname: my skill\ndescription: Does the thing.\n---\nStep one.")
  let load = { @Sendable in AgentSkillCatalog.load(directories: [root]) }
  let tools = MaiSkillTools.makeTools(catalog: load)
  #expect(tools.count == 1)
  let tool = try #require(tools.first)
  #expect(tool.definition.name == "skills_my-skill")
  #expect(tool.definition.description.hasPrefix("Does the thing. This is a skill"))
  #expect(tool.definition.parameters.map(\.name) == ["arguments"])
  #expect(tool.definition.annotations.approval == .automatic)
  #expect(MaiSkillTools.isSkillTool(tool.definition.name))
  #expect(ToolGroupDefinition.inferred(from: tools).map(\.id) == [MaiSkillTools.groupID])

  let context = ToolExecutionContext(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "skills", depth: 0),
    modelTurn: 1)
  let output = try await tool.call(
    arguments: .object(["arguments": .string("the parser")]), context: context)
  #expect(!output.isError)
  #expect(output.text.hasPrefix("Follow the instructions of skill 'my skill' now."))
  #expect(!output.text.contains("Paths they mention are relative to"))
  #expect(output.text.contains("Project paths, including AGENTS.md and output files, are relative to the workspace"))
  #expect(output.text.contains("<skill name=\"my skill\" directory=\""))
  #expect(output.text.contains("Step one.\n</skill>\n\nthe parser"))

  // Editing the file between calls changes what the model gets.
  try writeSkill(
    in: root, folder: "my skill",
    text: "---\nname: my skill\ndescription: Does the thing.\n---\nStep two.")
  let again = try await tool.call(arguments: .object([:]), context: context)
  #expect(again.text.contains("Step two.\n</skill>"))
  #expect(!again.text.contains("Step one."))

  // Invocation settings are rechecked even before the host rescans tools.
  try writeSkill(
    in: root, folder: "my skill",
    text: "---\nname: my skill\ndisable-model-invocation: true\n---\nPrivate instructions.")
  let disabled = try await tool.call(arguments: .object([:]), context: context)
  #expect(disabled.isError)
  #expect(!disabled.text.contains("Private instructions."))

  // Removing it turns the tool into an error rather than stale instructions.
  try files.removeItem(at: root.appendingPathComponent("my skill"))
  let gone = try await tool.call(arguments: .object([:]), context: context)
  #expect(gone.isError)
}

@Test("The home names where skills live, beside the project's chats and under the root")
func homeSkillPaths() throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appendingPathComponent(
    "skills-home-\(UUID().uuidString)", isDirectory: true)
  let work = root.appendingPathComponent("work", isDirectory: true)
  try files.createDirectory(at: work, withIntermediateDirectories: true)
  defer { try? files.removeItem(at: root) }
  let home = AgentHome(rootURL: root.appendingPathComponent("pmai-home", isDirectory: true))
  let project = AgentProject(workingDirectory: work.path)
  #expect(home.skillsDirectoryURL.path == home.rootURL.appendingPathComponent("skills").path)
  #expect(
    home.skillsURL(for: project).path
      == AgentProject.standardizedPath(work.path) + "/.pmai/skills")
}

private func writeSkill(in root: URL, folder: String, text: String) throws {
  let directory = root.appendingPathComponent(folder, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try text.write(
    to: directory.appendingPathComponent(AgentSkill.filename), atomically: true, encoding: .utf8)
}
