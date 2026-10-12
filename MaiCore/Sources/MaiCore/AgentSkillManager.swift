import Foundation

public enum AgentSkillManagerError: LocalizedError, Equatable, Sendable {
  case invalidName
  case missingDescription
  case missingPrompt
  case alreadyExists(String)
  case invalidSkill
  case renamedSkill
  case outsideRoot

  public var errorDescription: String? {
    switch self {
    case .invalidName: "Enter a skill name without slashes or control characters."
    case .missingDescription: "Enter a description of when to use this skill."
    case .missingPrompt: "Enter the instructions for this skill."
    case .alreadyExists(let name):
      "A skill named '\(name)' already exists. Edit it or choose another name."
    case .invalidSkill: "Choose a skill containing a readable SKILL.md and instructions."
    case .renamedSkill: "Keep the skill's name unchanged when editing."
    case .outsideRoot: "The skill is outside its skills folder or uses a symbolic link."
    }
  }
}

/// File operations shared by the app and REPL. New folders are staged before
/// installation; editing only touches SKILL.md and keeps supporting files.
public enum AgentSkillManager {
  public static func validateName(_ name: String) throws {
    guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
      name != ".", name != "..", !name.hasPrefix("."), !name.contains("/"),
      !name.contains("\\"),
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw AgentSkillManagerError.invalidName }
  }

  public static func document(name: String, description: String, prompt: String) -> String {
    let name = name.replacingOccurrences(of: "'", with: "''")
    let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")
    return "---\nname: '\(name)'\ndescription: |-\n\(description)\n---\n\n"
      + prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  @discardableResult
  public static func create(
    name: String, description: String, prompt: String, in root: URL
  ) throws -> AgentSkill {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    try validate(name: name, description: description, prompt: prompt)
    return try install(
      MaiArchiveSkill(
        name: name,
        files: [
          .init(
            path: AgentSkill.filename,
            data: Data(document(name: name, description: description, prompt: prompt).utf8))
        ]), in: root)
  }

  /// Imports never replace an existing skill. Portable settings backup merging
  /// continues to use MaiArchiveSkill.install's separate update semantics.
  @discardableResult
  public static func install(_ archive: MaiArchiveSkill, in root: URL) throws -> AgentSkill {
    try archive.validate()
    try validateName(archive.name)
    var paths = Set<String>()
    for file in archive.files where !paths.insert(file.path.lowercased()).inserted {
      throw MaiArchiveError.duplicateSkillPath(archive.name, file.path)
    }
    let definitions = archive.files.filter {
      $0.path.lowercased() == AgentSkill.filename.lowercased()
    }
    guard definitions.count == 1, let definition = definitions.first,
      let text = String(data: definition.data, encoding: .utf8)
    else { throw AgentSkillManagerError.invalidSkill }
    let parsed = AgentSkillFrontMatter.parse(text)
    let name = parsed.fields["name"] ?? archive.name
    try validateName(name)
    guard !parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentSkillManagerError.missingPrompt
    }
    try ensureAvailable(name: name, folder: archive.name, in: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let staging = root.appendingPathComponent(
      ".skill-import-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    try archive.install(in: staging)
    let staged = staging.appendingPathComponent(archive.name, isDirectory: true)
    let destination = root.appendingPathComponent(archive.name, isDirectory: true)
    try FileManager.default.moveItem(at: staged, to: destination)
    guard let skill = AgentSkill.load(directory: destination, rootURL: root) else {
      throw AgentSkillManagerError.invalidSkill
    }
    return skill
  }

  @discardableResult
  public static func update(_ skill: AgentSkill, description: String, prompt: String) throws
    -> AgentSkill
  {
    try validateLocation(skill)
    let source = try String(contentsOf: skill.fileURL, encoding: .utf8)
    try validate(name: skill.name, description: description, prompt: prompt)
    // Keep unknown YAML, including nested metadata and lists, verbatim.
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
      .components(separatedBy: "\n")
    var extra: [String] = []
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let end = lines.indices.dropFirst().first(where: {
        lines[$0].first?.isWhitespace != true
          && ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces))
      })
    {
      var replacing = false
      for line in lines[1..<end] {
        if let first = line.first, !first.isWhitespace, first != "#" {
          let key = line.split(separator: ":", maxSplits: 1).first?.lowercased()
            .trimmingCharacters(in: .whitespaces)
          replacing = key == "name" || key == "description"
        }
        if !replacing || line.hasPrefix("#") { extra.append(line) }
      }
    }
    var text = document(name: skill.name, description: description, prompt: prompt)
    if !extra.isEmpty, let fence = text.range(of: "\n---\n") {
      text.insert(contentsOf: "\n" + extra.joined(separator: "\n"), at: fence.lowerBound)
    }
    return try saveDocument(text, for: skill)
  }

  @discardableResult
  public static func saveDocument(_ text: String, for skill: AgentSkill) throws -> AgentSkill {
    try validateLocation(skill)
    let parsed = AgentSkillFrontMatter.parse(text)
    let name = parsed.fields["name"] ?? skill.name
    guard name == skill.name else { throw AgentSkillManagerError.renamedSkill }
    try validate(
      name: name, description: parsed.fields["description"] ?? skill.description,
      prompt: parsed.body)
    try text.write(to: skill.fileURL, atomically: true, encoding: .utf8)
    guard let updated = AgentSkill.load(directory: skill.directoryURL, rootURL: skill.rootURL)
    else {
      throw AgentSkillManagerError.invalidSkill
    }
    return updated
  }

  public static func remove(_ skill: AgentSkill) throws {
    try validateLocation(skill)
    try FileManager.default.removeItem(at: skill.directoryURL)
  }

  public static func ensureAvailable(name: String, folder: String? = nil, in root: URL) throws {
    try validateName(name)
    let folder = folder ?? name
    let existing = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    let catalog = AgentSkillCatalog.load(directories: [root])
    guard !existing.contains(where: { $0.caseInsensitiveCompare(folder) == .orderedSame }),
      !catalog.skills.contains(where: {
        $0.name.caseInsensitiveCompare(name) == .orderedSame
          || $0.toolName.caseInsensitiveCompare(MaiSkillTools.toolName(for: name)) == .orderedSame
      })
    else { throw AgentSkillManagerError.alreadyExists(name) }
  }

  private static func validate(name: String, description: String, prompt: String) throws {
    try validateName(name)
    guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentSkillManagerError.missingDescription
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentSkillManagerError.missingPrompt
    }
  }

  private static func validateLocation(_ skill: AgentSkill) throws {
    guard
      skill.directoryURL.deletingLastPathComponent().standardizedFileURL
        == skill.rootURL.standardizedFileURL,
      (try? FileManager.default.destinationOfSymbolicLink(atPath: skill.directoryURL.path)) == nil,
      (try? FileManager.default.destinationOfSymbolicLink(atPath: skill.fileURL.path)) == nil
    else { throw AgentSkillManagerError.outsideRoot }
  }
}
