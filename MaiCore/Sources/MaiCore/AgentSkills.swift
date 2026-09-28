import Foundation

/// A skill: a folder holding a `SKILL.md` whose front matter names and
/// describes it and whose body is the instructions to follow, with any
/// scripts or reference files beside it. The layout is the one coding agents
/// share (`<skills dir>/<name>/SKILL.md`), so a skill written for another
/// tool works here unchanged. pmai reads them from the project's
/// `.pmai/skills` and from `~/.pmai/skills`.
public struct AgentSkill: Equatable, Identifiable, Sendable {
  public static let filename = "SKILL.md"
  /// The placeholder a body may use for whatever the caller passes along.
  public static let argumentsPlaceholder = "$ARGUMENTS"
  private static let fallbackDescriptionLength = 200

  public var name: String
  public var description: String
  /// The folder holding SKILL.md and whatever files it refers to.
  public var directoryURL: URL
  /// The skills directory the folder was found in.
  public var rootURL: URL
  /// The instructions: SKILL.md after its front matter.
  public var body: String
  /// Every scalar front-matter field by lowercased key, for what a host
  /// wants to honor beyond the name and description.
  public var frontMatter: [String: String]

  public init(
    name: String,
    description: String,
    directoryURL: URL,
    rootURL: URL? = nil,
    body: String,
    frontMatter: [String: String] = [:]
  ) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    self.directoryURL = directoryURL
    self.rootURL = rootURL ?? directoryURL.deletingLastPathComponent()
    self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    self.frontMatter = frontMatter
  }

  public var id: String { name }

  public var fileURL: URL { directoryURL.appendingPathComponent(Self.filename) }

  /// The tool the model calls to receive these instructions.
  public var toolName: String { MaiSkillTools.toolName(for: name) }

  /// False when the front matter says `disable-model-invocation: true`: the
  /// skill is for people to send, never a tool the model may call.
  public var isModelInvocable: Bool {
    !(frontMatter["disable-model-invocation"].map(Self.isTrue) ?? false)
  }

  /// Reads one skill folder; nil when it holds no readable SKILL.md.
  public static func load(
    directory: URL,
    rootURL: URL? = nil,
    fileManager: FileManager = .default
  ) -> AgentSkill? {
    guard let file = skillFile(in: directory, fileManager: fileManager),
      let text = try? String(contentsOf: file, encoding: .utf8)
    else { return nil }
    let parsed = AgentSkillFrontMatter.parse(text)
    let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let name =
      parsed.fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
      ?? directory.lastPathComponent
    let description =
      parsed.fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
      ?? fallbackDescription(from: body)
      ?? "Skill \(name)."
    return AgentSkill(
      name: name,
      description: description,
      directoryURL: directory,
      rootURL: rootURL,
      body: body,
      frontMatter: parsed.fields)
  }

  /// The text a host sends for the skill: the instructions inside a `<skill>`
  /// envelope identifying its resource folder without changing the project paths,
  /// and the caller's own words after it. A body that mentions `$ARGUMENTS`
  /// takes them there instead.
  public func prompt(arguments: String? = nil) -> String {
    let extra = arguments?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var instructions = body
    var consumed = false
    if instructions.contains(Self.argumentsPlaceholder) {
      instructions = instructions.replacingOccurrences(of: Self.argumentsPlaceholder, with: extra)
      consumed = true
    }
    var text = "<skill name=\"\(name)\" directory=\"\(directoryURL.path)\">\n"
    text += "Apply this skill in the current workspace. Project paths, including AGENTS.md and output files, are relative to the workspace, not the skill directory.\n\n"
    text += instructions
    text += "\n</skill>"
    if !extra.isEmpty, !consumed { text += "\n\n" + extra }
    return text
  }

  private static func skillFile(in directory: URL, fileManager: FileManager) -> URL? {
    let exact = directory.appendingPathComponent(filename)
    if fileManager.fileExists(atPath: exact.path) { return exact }
    let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    return entries.first { $0.lowercased() == filename.lowercased() }.map {
      directory.appendingPathComponent($0)
    }
  }

  /// The first line of the body, without its heading marks, when the front
  /// matter gave no description.
  private static func fallbackDescription(from body: String) -> String? {
    guard
      let line = body.components(separatedBy: .newlines).first(where: {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
      })
    else { return nil }
    let text = line.drop { $0 == "#" || $0.isWhitespace }.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return text.count > fallbackDescriptionLength
      ? String(text.prefix(fallbackDescriptionLength)) + "…" : text
  }

  static func isTrue(_ value: String) -> Bool {
    ["true", "yes", "on", "1"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
  }
}

/// The YAML block between the `---` lines at the top of a Markdown file.
/// Only the subset skills use is read: `key: value` pairs, quoted or not, and
/// `|` or `>` block scalars. Nested maps and lists are skipped, not rejected,
/// so a skill carrying settings for another host still loads.
public enum AgentSkillFrontMatter {
  public static func parse(_ text: String) -> (fields: [String: String], body: String) {
    var lines = text.components(separatedBy: "\n").map { line in
      line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
    if let first = lines.first, first.hasPrefix("\u{FEFF}") {
      lines[0] = String(first.dropFirst())
    }
    guard let first = lines.first, isFence(first),
      let end = lines.indices.dropFirst().first(where: { isFence(lines[$0]) })
    else { return ([:], text) }
    let body = lines[(end + 1)...].joined(separator: "\n")
    return (fields(from: Array(lines[1..<end])), body)
  }

  private static func isFence(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed == "---" || trimmed == "..."
  }

  static func fields(from lines: [String]) -> [String: String] {
    var fields: [String: String] = [:]
    var index = 0
    while index < lines.count {
      let line = lines[index]
      index += 1
      guard let first = line.first, !first.isWhitespace, first != "#",
        let colon = line.firstIndex(of: ":")
      else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      guard !key.isEmpty else { continue }
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      var block: [String] = []
      while index < lines.count {
        let next = lines[index]
        let blank = next.trimmingCharacters(in: .whitespaces).isEmpty
        guard blank || next.first?.isWhitespace == true else { break }
        block.append(next)
        index += 1
      }
      while let last = block.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        block.removeLast()
      }
      if value.hasPrefix("|") || value.hasPrefix(">") {
        fields[key] = blockScalar(block, folded: value.hasPrefix(">"))
      } else if !value.isEmpty {
        fields[key] = unquote(value)
      }
    }
    return fields
  }

  private static func blockScalar(_ lines: [String], folded: Bool) -> String {
    let indent =
      lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
    let stripped = lines.map { line in
      String(line.dropFirst(min(indent, line.prefix { $0 == " " || $0 == "\t" }.count)))
    }
    guard folded else { return stripped.joined(separator: "\n") }
    var paragraphs: [[String]] = [[]]
    for line in stripped {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        paragraphs.append([])
      } else {
        paragraphs[paragraphs.count - 1].append(trimmed)
      }
    }
    return paragraphs.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
      value.last == first
    else { return value }
    let inner = String(value.dropFirst().dropLast())
    guard first == "\"" else { return inner.replacingOccurrences(of: "''", with: "'") }
    return
      inner
      .replacingOccurrences(of: "\\\"", with: "\"")
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\\\", with: "\\")
  }
}

/// Every skill a host can offer, in name order. Built from a list of skills
/// directories where an earlier one shadows a later one holding the same
/// name, so a project's copy wins over the person's.
public struct AgentSkillCatalog: Equatable, Sendable {
  public var skills: [AgentSkill]

  public init(skills: [AgentSkill] = []) {
    self.skills = skills
  }

  public var isEmpty: Bool { skills.isEmpty }

  /// The skills the model may be offered as tools.
  public var modelInvocable: [AgentSkill] { skills.filter(\.isModelInvocable) }

  /// A skill by its name or by its tool name, ignoring case.
  public func skill(named selector: String) -> AgentSkill? {
    let wanted = selector.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { return nil }
    return skills.first { skill in
      skill.name.caseInsensitiveCompare(wanted) == .orderedSame
        || skill.toolName.caseInsensitiveCompare(wanted) == .orderedSame
    }
  }

  public static func load(directories: [URL], fileManager: FileManager = .default)
    -> AgentSkillCatalog
  {
    var seen: Set<String> = []
    var skills: [AgentSkill] = []
    for directory in directories {
      for skill in load(directory: directory, fileManager: fileManager)
      where seen.insert(skill.name.lowercased()).inserted {
        skills.append(skill)
      }
    }
    return AgentSkillCatalog(
      skills: skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
  }

  /// The skill folders directly under one directory, alphabetical; a folder
  /// without a SKILL.md is not a skill and is skipped.
  public static func load(directory: URL, fileManager: FileManager = .default) -> [AgentSkill] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    let folders = entries.filter { url in
      var isDirectory: ObjCBool = false
      return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
    return folders.compactMap {
      AgentSkill.load(
        directory: URL(fileURLWithPath: $0.path, isDirectory: true), rootURL: directory,
        fileManager: fileManager)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

/// Skills as tools: one `skills_<name>` per skill, described by the skill's
/// own description, that answers with the instructions to follow. Enabling a
/// skill for an agent is enabling its tool, so the usual allow-list persists
/// the choice, and `/tools` shows them as the `skills` group.
public enum MaiSkillTools {
  public static let toolPrefix = "skills_"
  public static let groupID = "skills"

  public static func toolName(for skillName: String) -> String {
    let safe = skillName.trimmingCharacters(in: .whitespacesAndNewlines).map { character in
      character.isLetter || character.isNumber || character == "_" || character == "-"
        ? String(character) : "-"
    }.joined()
    return toolPrefix + safe
  }

  public static func isSkillTool(_ name: String) -> Bool {
    name.hasPrefix(toolPrefix)
  }

  /// What `/tools` shows for the family, over the skill tools a host holds.
  public static func group(toolNames: Set<String>) -> ToolGroupDefinition {
    ToolGroupDefinition(
      id: groupID,
      sourceID: "runtime",
      displayName: "Skills",
      description:
        "Instructions for particular kinds of task, kept in SKILL.md folders and read only when "
        + "needed: each skills_* tool is one skill, and calling it returns the instructions to follow, "
        + "with any details passed as its argument. The model picks a skill when a task matches its "
        + "description; /skills lists, shows, and enables them.",
      toolNames: toolNames)
  }

  public static func definition(for skill: AgentSkill) -> ToolDefinition {
    ToolDefinition(
      name: skill.toolName,
      description:
        "\(skill.description) This is a skill: calling it returns the instructions to follow for the task; pass any details as arguments.",
      parameters: [
        ToolParameterDef(
          name: "arguments", type: "string",
          description: "What the skill should be applied to, or extra details, if any.",
          required: false)
      ],
      annotations: ToolAnnotations(
        readOnly: true, destructive: false, idempotent: true, openWorld: false,
        approval: .automatic))
  }

  /// One tool for a skill. `catalog` is read at every call, so an edited
  /// SKILL.md is what the model gets, not what was there at startup.
  public static func makeTool(
    for skill: AgentSkill,
    catalog: @escaping @Sendable () -> AgentSkillCatalog
  ) -> any AgentTool {
    let name = skill.name
    return ClosureTool(definition: definition(for: skill)) { arguments, _ in
      guard let current = catalog().skill(named: name) else {
        return ToolOutput(
          text: "Error: skill '\(name)' is no longer available; its SKILL.md was removed.",
          isError: true)
      }
      return execute(skill: current, arguments: arguments.objectValue ?? [:])
    }
  }

  /// A tool for every model-invocable skill in the catalog.
  public static func makeTools(
    catalog: @escaping @Sendable () -> AgentSkillCatalog
  ) -> [any AgentTool] {
    catalog().modelInvocable.map { makeTool(for: $0, catalog: catalog) }
  }

  public static func execute(skill: AgentSkill, arguments: [String: JSONValue]) -> ToolOutput {
    let extra = ["arguments", "args", "input", "request", "task", "text"].lazy
      .compactMap { arguments[$0]?.coercedStringValue }
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let text =
      "Follow the instructions of skill '\(skill.name)' now.\n\n"
      + skill.prompt(arguments: extra)
    return ToolOutput(text: text)
  }
}

extension String {
  fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
