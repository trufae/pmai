import Foundation
import MaiCore

/// Accepts a skill zipped directly or inside a containing folder, and keeps
/// resources beside SKILL.md. Installation uses the shared skill manager.
public enum SkillArchiveImporter {
  public static let maximumArchiveBytes = 25_000_000
  public static let maximumUncompressedBytes = 50_000_000

  public enum ImportError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case missingSkill
    case multipleSkills

    public var errorDescription: String? {
      switch self {
      case .tooLarge: "Choose a skill zip smaller than 25 MB."
      case .missingSkill: "The zip must contain a SKILL.md with instructions."
      case .multipleSkills: "Choose a zip containing one skill folder."
      }
    }
  }

  public static func archive(at url: URL) throws -> MaiArchiveSkill {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maximumArchiveBytes else { throw ImportError.tooLarge }
    return try archive(in: Data(contentsOf: url))
  }

  public static func archive(in data: Data) throws -> MaiArchiveSkill {
    guard data.count <= maximumArchiveBytes else { throw ImportError.tooLarge }
    let entries = try ZipArchiveReader.entries(
      in: data, maximumUncompressedBytes: maximumUncompressedBytes
    )
    .filter {
      let components = $0.path.split(separator: "/")
      return !components.contains("__MACOSX") && components.last != ".DS_Store"
        && components.last?.hasPrefix("._") != true
    }
    guard !entries.isEmpty else { throw ImportError.missingSkill }
    // Validate all paths before selecting a subtree: never normalize away '..'.
    try MaiArchiveSkill(
      name: "validation",
      files: entries.map {
        .init(path: $0.path, data: $0.data)
      }
    ).validate()
    let definitions = entries.filter {
      $0.path.split(separator: "/").last?.lowercased() == AgentSkill.filename.lowercased()
    }
    guard !definitions.isEmpty else { throw ImportError.missingSkill }
    guard definitions.count == 1 else { throw ImportError.multipleSkills }
    let definition = definitions[0]
    guard let text = String(data: definition.data, encoding: .utf8) else {
      throw ImportError.missingSkill
    }
    let components = definition.path.split(separator: "/").dropLast()
    let prefix = components.isEmpty ? "" : components.joined(separator: "/") + "/"
    let parsed = AgentSkillFrontMatter.parse(text)
    let name = parsed.fields["name"] ?? components.last.map(String.init)
    guard let name else { throw ImportError.missingSkill }
    try AgentSkillManager.validateName(name)
    guard !parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentSkillManagerError.missingPrompt
    }
    let archive = MaiArchiveSkill(
      name: name,
      files: entries.filter { $0.path.hasPrefix(prefix) }.map {
        MaiArchiveSkillFile(
          path: String($0.path.dropFirst(prefix.count)), data: $0.data, executable: $0.executable)
      })
    try archive.validate()
    return archive
  }
}
