import Foundation

public struct WebXDCRevision: Codable, Identifiable, Sendable, Equatable {
  public var number: Int
  public var date: Date
  public var note: String

  public var id: Int { number }
}

public struct WebXDCAppInfo: Codable, Identifiable, Sendable, Equatable {
  public var id: UUID
  public var name: String
  public var appDescription: String
  public var createdAt: Date
  public var revisions: [WebXDCRevision]
  public var currentRevision: Int

  public var currentRevisionInfo: WebXDCRevision? {
    revisions.first { $0.number == currentRevision }
  }
}

public struct WebXDCImportResult: Identifiable, Sendable, Equatable {
  public let id = UUID()
  public let app: WebXDCAppInfo
  public let alreadyImported: Bool

  public var title: String { alreadyImported ? "Already Imported" : "App Imported" }
  public var message: String {
    alreadyImported
      ? "\(app.name) is already in Apps. Your app data and permissions have been kept."
      : "\(app.name) was added to Apps."
  }
}

public enum WebXDCError: LocalizedError {
  case message(String)

  public var errorDescription: String? {
    switch self {
    case .message(let text): return text
    }
  }
}

public struct WebXDCStore: Sendable {
  public let rootURL: URL

  public init(rootURL: URL) { self.rootURL = rootURL }

  public let maxFileBytes = 4_000_000
  public let maxAppFiles = 200
  private let metadataFilename = "app.json"
  private let revisionPrefix = "rev-"

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: - Locations

  @discardableResult
  public func ensureRoot() throws -> URL {
    let url = rootURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  public func appURL(_ id: UUID) -> URL {
    rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  public func revisionURL(_ app: WebXDCAppInfo, revision: Int) -> URL {
    appURL(app.id).appendingPathComponent("\(revisionPrefix)\(revision)", isDirectory: true)
  }

  public func currentRevisionURL(_ app: WebXDCAppInfo) -> URL {
    revisionURL(app, revision: app.currentRevision)
  }

  // MARK: - App metadata

  public func listApps() -> [WebXDCAppInfo] {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
    else { return [] }
    return entries.compactMap { entry in
      guard let data = try? Data(contentsOf: entry.appendingPathComponent(metadataFilename)),
        let info = try? decoder.decode(WebXDCAppInfo.self, from: data)
      else { return nil }
      return info
    }.sorted { $0.createdAt < $1.createdAt }
  }

  public func app(id: UUID) -> WebXDCAppInfo? {
    guard let data = try? Data(contentsOf: appURL(id).appendingPathComponent(metadataFilename)),
      let info = try? decoder.decode(WebXDCAppInfo.self, from: data)
    else { return nil }
    return info
  }

  public func findApp(matching query: String) -> WebXDCAppInfo? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lower = trimmed.lowercased()
    let apps = listApps()
    if let byID = apps.first(where: { $0.id.uuidString.lowercased().hasPrefix(lower) }) {
      return byID
    }
    if let exact = apps.first(where: { $0.name.lowercased() == lower }) {
      return exact
    }
    return apps.first { $0.name.lowercased().contains(lower) }
  }

  public func save(_ app: WebXDCAppInfo) throws {
    let data = try encoder.encode(app)
    try data.write(
      to: appURL(app.id).appendingPathComponent(metadataFilename), options: [.atomic])
  }

  public func deleteApp(id: UUID) throws {
    try FileManager.default.removeItem(at: appURL(id))
  }

  // MARK: - Creation and revisions

  @discardableResult
  public func createApp(name: String, description: String, indexHTML: String? = nil) throws
    -> WebXDCAppInfo
  {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { throw WebXDCError.message("App name is required.") }
    try ensureRoot()
    var app = WebXDCAppInfo(
      id: UUID(),
      name: trimmedName,
      appDescription: description.trimmingCharacters(in: .whitespacesAndNewlines),
      createdAt: Date(),
      revisions: [WebXDCRevision(number: 1, date: Date(), note: "created")],
      currentRevision: 1)
    let revURL = revisionURL(app, revision: 1)
    try FileManager.default.createDirectory(at: revURL, withIntermediateDirectories: true)
    let html = indexHTML ?? templateIndexHTML(name: trimmedName)
    try Data(html.utf8).write(to: revURL.appendingPathComponent("index.html"))
    let manifest = "name = \"\(trimmedName.replacingOccurrences(of: "\"", with: "'"))\"\n"
    try Data(manifest.utf8).write(to: revURL.appendingPathComponent("manifest.toml"))
    app.revisions[0].date = Date()
    try save(app)
    return app
  }

  /// Copies the current revision into a new numbered revision directory and
  /// returns the updated app whose currentRevision points at the copy.
  @discardableResult
  public func beginRevision(_ app: WebXDCAppInfo, note: String, from source: Int? = nil) throws
    -> WebXDCAppInfo
  {
    var app = app
    let sourceNumber = source ?? app.currentRevision
    guard app.revisions.contains(where: { $0.number == sourceNumber }) else {
      throw WebXDCError.message("Revision \(sourceNumber) does not exist.")
    }
    let next = (app.revisions.map(\.number).max() ?? 0) + 1
    let sourceURL = revisionURL(app, revision: sourceNumber)
    let destinationURL = revisionURL(app, revision: next)
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    app.revisions.append(WebXDCRevision(number: next, date: Date(), note: note))
    app.currentRevision = next
    try save(app)
    return app
  }

  @discardableResult
  public func rollback(_ app: WebXDCAppInfo, to revision: Int) throws -> WebXDCAppInfo {
    try beginRevision(app, note: "rollback to revision \(revision)", from: revision)
  }

  @discardableResult
  public func selectRevision(_ app: WebXDCAppInfo, revision: Int) throws -> WebXDCAppInfo {
    var app = app
    guard app.revisions.contains(where: { $0.number == revision }) else {
      throw WebXDCError.message("Revision \(revision) does not exist.")
    }
    app.currentRevision = revision
    try save(app)
    return app
  }

  @discardableResult
  public func deleteRevision(_ app: WebXDCAppInfo, revision: Int) throws -> WebXDCAppInfo {
    var app = app
    guard app.revisions.count > 1 else {
      throw WebXDCError.message("Cannot delete the only revision.")
    }
    guard let index = app.revisions.firstIndex(where: { $0.number == revision }) else {
      throw WebXDCError.message("Revision \(revision) does not exist.")
    }
    try? FileManager.default.removeItem(at: revisionURL(app, revision: revision))
    app.revisions.remove(at: index)
    if app.currentRevision == revision {
      app.currentRevision = app.revisions.map(\.number).max() ?? 1
    }
    try save(app)
    return app
  }

  @discardableResult
  public func deleteOtherRevisions(_ app: WebXDCAppInfo, keeping revision: Int) throws
    -> WebXDCAppInfo
  {
    var app = app
    guard let keptRevision = app.revisions.first(where: { $0.number == revision }) else {
      throw WebXDCError.message("Revision \(revision) does not exist.")
    }

    let appRoot = appURL(app.id)
    let keptURL = revisionURL(app, revision: revision)
    let canonicalURL = revisionURL(app, revision: 1)
    let temporaryURL =
      appRoot
      .appendingPathComponent(".rev-\(revision)-keep-\(UUID().uuidString)", isDirectory: true)

    if revision != 1 {
      try FileManager.default.moveItem(at: keptURL, to: temporaryURL)
    }

    for oldRevision in app.revisions {
      if oldRevision.number == revision && revision == 1 {
        continue
      }
      let oldURL = revisionURL(app, revision: oldRevision.number)
      try? FileManager.default.removeItem(at: oldURL)
    }

    if revision != 1 {
      try FileManager.default.moveItem(at: temporaryURL, to: canonicalURL)
    }

    app.revisions = [
      WebXDCRevision(number: 1, date: keptRevision.date, note: "created")
    ]
    app.currentRevision = 1
    try save(app)
    return app
  }

  // MARK: - Files

  public func validatedRelativePath(_ rawPath: String) throws -> String {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw WebXDCError.message("Path is required.") }
    guard !trimmed.contains("\\"), !trimmed.contains("\0"), !(trimmed as NSString).isAbsolutePath
    else { throw WebXDCError.message("Path must be relative with forward slashes.") }
    let components = trimmed.split(separator: "/").map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != metadataFilename })
    else { throw WebXDCError.message("Path contains an invalid component.") }
    return components.joined(separator: "/")
  }

  public func listFiles(_ app: WebXDCAppInfo, revision: Int? = nil) -> [String] {
    let root = revisionURL(app, revision: revision ?? app.currentRevision)
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [])
    else { return [] }
    var paths: [String] = []
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
        continue
      }
      let full = url.standardizedFileURL.path
      let rootPath = root.standardizedFileURL.path
      guard full.hasPrefix(rootPath + "/") else { continue }
      paths.append(String(full.dropFirst(rootPath.count + 1)))
    }
    return paths.sorted()
  }

  public func readFile(_ app: WebXDCAppInfo, path: String, revision: Int? = nil) throws -> Data {
    let relative = try validatedRelativePath(path)
    let url = revisionURL(app, revision: revision ?? app.currentRevision)
      .appendingPathComponent(relative)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw WebXDCError.message("File '\(relative)' does not exist.")
    }
    return try Data(contentsOf: url)
  }

  /// Writes a file into a fresh revision copied from the current one.
  @discardableResult
  public func writeFile(_ app: WebXDCAppInfo, path: String, data: Data) throws -> WebXDCAppInfo {
    let relative = try validatedRelativePath(path)
    guard data.count <= maxFileBytes else {
      throw WebXDCError.message("Files are limited to \(maxFileBytes) bytes.")
    }
    let isNew = !FileManager.default.fileExists(
      atPath: currentRevisionURL(app).appendingPathComponent(relative).path)
    if !isNew, listFiles(app).count >= maxAppFiles {
      throw WebXDCError.message("An app is limited to \(maxAppFiles) files.")
    }
    let updated = try beginRevision(app, note: "\(isNew ? "add" : "edit") \(relative)")
    let url = currentRevisionURL(updated).appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
    return updated
  }

  /// Writes a file in place after the editor UI explicitly created a revision.
  public func writeFileInPlace(_ app: WebXDCAppInfo, path: String, data: Data) throws {
    let relative = try validatedRelativePath(path)
    guard data.count <= maxFileBytes else {
      throw WebXDCError.message("Files are limited to \(maxFileBytes) bytes.")
    }
    let url = currentRevisionURL(app).appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
  }

  @discardableResult
  public func deleteFile(_ app: WebXDCAppInfo, path: String) throws -> WebXDCAppInfo {
    let relative = try validatedRelativePath(path)
    guard relative != "index.html" else {
      throw WebXDCError.message("index.html cannot be deleted.")
    }
    guard FileManager.default.fileExists(
      atPath: currentRevisionURL(app).appendingPathComponent(relative).path)
    else { throw WebXDCError.message("File '\(relative)' does not exist.") }
    let updated = try beginRevision(app, note: "delete \(relative)")
    try FileManager.default.removeItem(
      at: currentRevisionURL(updated).appendingPathComponent(relative))
    return updated
  }

  public func iconData(_ app: WebXDCAppInfo, revision: Int? = nil) -> Data? {
    let root = revisionURL(app, revision: revision ?? app.currentRevision)
    for name in ["icon.png", "icon.jpg", "icon.svg"] {
      if let data = try? Data(contentsOf: root.appendingPathComponent(name)) {
        return data
      }
    }
    return nil
  }

  // MARK: - Export / import

  public func exportXDC(_ app: WebXDCAppInfo, revision: Int? = nil) throws -> URL {
    let revisionNumber = revision ?? app.currentRevision
    let root = revisionURL(app, revision: revisionNumber)
    var entries: [(path: String, data: Data)] = []
    for path in listFiles(app, revision: revisionNumber) {
      let data = try Data(contentsOf: root.appendingPathComponent(path))
      entries.append((path, data))
    }
    guard entries.contains(where: { $0.path == "index.html" }) else {
      throw WebXDCError.message("The app has no index.html to export.")
    }
    if !entries.contains(where: { $0.path == "manifest.toml" }) {
      let manifest = "name = \"\(app.name.replacingOccurrences(of: "\"", with: "'"))\"\n"
      entries.append(("manifest.toml", Data(manifest.utf8)))
    }
    let safeName = app.name.replacingOccurrences(
      of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    let exportDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("webxdc-export", isDirectory: true)
    try FileManager.default.createDirectory(
      at: exportDirectory, withIntermediateDirectories: true)
    let url = exportDirectory.appendingPathComponent(
      "\(safeName.isEmpty ? "app" : safeName)-r\(revisionNumber).xdc")
    try ZipArchiveWriter.write(entries: entries, to: url)
    return url
  }

  @discardableResult
  public func importXDC(from url: URL, fallbackName: String) throws -> WebXDCImportResult {
    let entries = try ZipArchiveReader.entries(at: url)
    guard entries.contains(where: { $0.path == "index.html" }) else {
      throw WebXDCError.message("The .xdc file has no index.html.")
    }
    guard entries.count <= maxAppFiles else {
      throw WebXDCError.message("The .xdc file has more than \(maxAppFiles) files.")
    }
    var files: [String: Data] = [:]
    for entry in entries {
      guard let relative = try? validatedRelativePath(entry.path) else { continue }
      guard entry.data.count <= maxFileBytes else {
        throw WebXDCError.message("File '\(relative)' exceeds the \(maxFileBytes) byte limit.")
      }
      guard files.updateValue(entry.data, forKey: relative) == nil else {
        throw WebXDCError.message("The .xdc file repeats '\(relative)'.")
      }
    }
    let apps = listApps()
    // Compare extracted files, so ZIP timestamps, compression and entry order
    // do not turn an identical app into a second installation.
    let paths = Set(files.keys)
    if let existing = apps.first(where: { app in
      Set(listFiles(app)) == paths
        && files.allSatisfy { (try? readFile(app, path: $0.key)) == $0.value }
    }) {
      return WebXDCImportResult(app: existing, alreadyImported: true)
    }
    var name = fallbackName
    var description = ""
    if let manifest = entries.first(where: { $0.path == "manifest.toml" }),
      let text = String(data: manifest.data, encoding: .utf8)
    {
      if let parsed = tomlValue(text, key: "name") { name = parsed }
      if let parsed = tomlValue(text, key: "description") { description = parsed }
    }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { name = "App" }
    let baseName = name
    let names = Set(apps.map { $0.name.lowercased() })
    var suffix = 2
    while names.contains(name.lowercased()) {
      name = "\(baseName) (\(suffix))"
      suffix += 1
    }
    try ensureRoot()
    var app = WebXDCAppInfo(
      id: UUID(),
      name: name,
      appDescription: description,
      createdAt: Date(),
      revisions: [WebXDCRevision(number: 1, date: Date(), note: "imported")],
      currentRevision: 1)
    let revURL = revisionURL(app, revision: 1)
    try FileManager.default.createDirectory(at: revURL, withIntermediateDirectories: true)
    var installed = false
    defer { if !installed { try? FileManager.default.removeItem(at: appURL(app.id)) } }
    for (relative, data) in files {
      let destination = revURL.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: destination)
    }
    app.revisions[0].date = Date()
    try save(app)
    installed = true
    return WebXDCImportResult(app: app, alreadyImported: false)
  }

  private func tomlValue(_ text: String, key: String) -> String? {
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1)
      guard parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespaces) == key
      else { continue }
      var value = parts[1].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      return value.isEmpty ? nil : value
    }
    return nil
  }

  public func templateIndexHTML(name: String) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(name)</title>
    <style>
    body { font-family: -apple-system, sans-serif; margin: 2em; }
    </style>
    </head>
    <body>
    <h1>\(name)</h1>
    <p>Hello from webxdc.</p>
    <script src="webxdc.js"></script>
    <script>
    window.webxdc.setUpdateListener(function (update) {
      console.log("update", update.payload);
    });
    </script>
    </body>
    </html>
    """
  }
}
