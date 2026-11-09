import Foundation

/// An editable CLI configuration that retains fields a newer version or plugin
/// owns and refuses to overwrite a file changed since the editor opened it.
public struct ConfigurationDocument: Sendable {
  public let url: URL
  public private(set) var configuration: MaiConfiguration
  private var originalData: Data?
  private var source: JSONValue

  public init(url: URL, initialData: Data = Data("{}".utf8)) throws {
    self.url = url.resolvingSymlinksInPath()
    originalData = try Self.readIfPresent(self.url)
    let data = originalData ?? initialData
    configuration = try JSONDecoder().decode(MaiConfiguration.self, from: data)
    try configuration.validate()
    source = try JSONDecoder().decode(JSONValue.self, from: data)
  }

  public mutating func save(_ updated: MaiConfiguration) throws {
    try updated.validate()
    let before = try JSONDecoder().decode(JSONValue.self, from: configuration.encoded())
    let after = try JSONDecoder().decode(JSONValue.self, from: updated.encoded())
    let merged = Self.merge(source, before: before, after: after)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(merged)
    let manager = FileManager.default
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lock = try MaiFileLock(url: url.appendingPathExtension("lock"), wait: false)
    defer { withExtendedLifetime(lock) {} }
    guard try Self.readIfPresent(url) == originalData else {
      throw MaiConfigurationError.invalidFile("Configuration changed in another app. Reload Settings before saving again.")
    }
    let staging = url.deletingLastPathComponent().appendingPathComponent(".pmai-settings-\(UUID()).json")
    guard manager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { try? manager.removeItem(at: staging) }
    try MaiFileReplacement.replaceItem(at: url, withItemAt: staging)
    originalData = data
    source = merged
    configuration = updated
  }

  private static func readIfPresent(_ url: URL) throws -> Data? {
    do { return try Data(contentsOf: url) }
    catch CocoaError.fileReadNoSuchFile { return nil }
  }

  private static func merge(_ source: JSONValue?, before: JSONValue?, after: JSONValue) -> JSONValue {
    if before == after { return source ?? after }
    if let old = before?.objectValue, let new = after.objectValue {
      var result = source?.objectValue ?? [:]
      for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
        result[key] = new[key].map { merge(result[key], before: old[key], after: $0) }
      }
      return .object(result)
    }
    if let old = before?.arrayValue, let new = after.arrayValue,
      old.allSatisfy({ $0.objectValue?["id"]?.stringValue != nil }),
      new.allSatisfy({ $0.objectValue?["id"]?.stringValue != nil }) {
      let raw = source?.arrayValue ?? []
      return .array(new.map { value in
        let id = value.objectValue?["id"]
        return merge(raw.first { $0.objectValue?["id"] == id },
          before: old.first { $0.objectValue?["id"] == id }, after: value)
      })
    }
    return after
  }
}
