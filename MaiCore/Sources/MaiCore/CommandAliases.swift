import Foundation

/// Global slash-command shortcuts. Frontends dispatch the expanded lines using
/// their ordinary input path, waiting for each action before starting the next.
public struct CommandAliasStore: Sendable {
  public struct Error: Swift.Error, LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  public let url: URL

  public init(home: AgentHome) {
    url = home.rootURL.appendingPathComponent("aliases.json")
  }

  public static let help = """
    /alias                 List global aliases
    /alias NAME            Show an alias
    /alias NAME TEXT       Register or replace an alias
    /unalias NAME          Unregister an alias

    Use Shift+Enter to separate commands or prompts in a definition.
    Extra invocation text is appended to the first line only:
      /alias hello your name is
      /hello john          Sends: your name is john
    Lines run in order, waiting for each response. Blank lines are ignored.
    Aliases are saved in the global pmai home, across projects and sessions.
    Builtin command names are reserved. Aliases cannot run /alias or another
    alias, including through /then or an agent address.
    """

  /// Names implemented by pmai's frontends, even when unavailable on this host.
  public static let builtinNames: Set<String> = Set("""
    alias unalias about agent agents app attach baseurl btw cd chat clear continue copy
    cwd edit exit export fork help hey highlight history image import job jobs keys
    last mcp mcps memory model models msg nothink path plugins project projects
    prompt prompts provider providers ps pwd queue quit recover remote reply reset
    set shell skills stats stop subagents theme then todo tools unthen vdb version
    view voice
    """.split(whereSeparator: \.isWhitespace).map(String.init))

  public func load() throws -> [String: String] {
    do {
      return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    } catch CocoaError.fileReadNoSuchFile { return [:] }
  }

  /// Handles management only. A nil result means ordinary frontend input.
  public func handle(_ input: String) throws -> String? {
    let (command, argument) = Self.fields(input)
    if command == "/help", ["alias", "/alias", "unalias", "/unalias"].contains(argument) {
      return Self.help
    }
    guard command == "/alias" || command == "/unalias" else { return nil }
    let (rawName, body) = Self.fields(argument)
    if rawName.isEmpty {
      if command == "/unalias" { throw Error("Usage: /unalias NAME") }
      let aliases = try load()
      return aliases.isEmpty ? "No aliases registered.\n" + Self.help
        : aliases.keys.sorted().map { "/\($0)\n\(aliases[$0]!)" }.joined(separator: "\n\n")
    }
    let name = try Self.name(rawName)
    if command == "/unalias" {
      guard body.isEmpty else { throw Error("Usage: /unalias NAME") }
      try update { aliases in
        guard aliases.removeValue(forKey: name) != nil else { throw Error("Unknown alias '/\(name)'.") }
      }
      return "Unregistered alias /\(name)."
    }
    if body.isEmpty {
      guard let value = try load()[name] else { throw Error("Unknown alias '/\(name)'.") }
      return "/\(name)\n\(value)"
    }
    guard !Self.builtinNames.contains(name) else { throw Error("/\(name) is a reserved command name.") }
    try update { aliases in
      aliases[name] = body
      // Also reject forward references: a formerly unknown command in another
      // definition must not become a nested alias after this registration.
      for definition in aliases.values {
        try Self.validate(Self.lines(definition), aliases: aliases)
      }
    }
    return "Registered alias /\(name)."
  }

  public func expand(_ input: String) throws -> [String]? {
    let (command, argument) = Self.fields(input)
    guard command.hasPrefix("/"), !Self.builtinNames.contains(String(command.dropFirst())) else { return nil }
    let aliases = try load()
    guard let body = aliases[String(command.dropFirst())] else { return nil }
    var lines = Self.lines(body)
    guard !lines.isEmpty else { throw Error("Alias \(command) is empty.") }
    if !argument.isEmpty { lines[0] += " " + argument }
    try Self.validate(lines, aliases: aliases)
    return lines
  }

  /// Recheck immediately before dispatch, since another frontend may have
  /// registered an alias while earlier lines were running.
  public func validateExecution(_ input: String) throws {
    try Self.validate([input], aliases: load())
  }

  private static func validate(_ lines: [String], aliases: [String: String]) throws {
    for line in lines {
      var (command, argument) = fields(line)
      // These wrappers dispatch their arguments as input, rather than text.
      while command == "/then" || command.hasPrefix("@") {
        (command, argument) = fields(argument)
      }
      if command == "/alias"
        || (command.hasPrefix("/") && aliases[String(command.dropFirst())] != nil) {
        throw Error("Aliases cannot run \(command).")
      }
    }
  }

  private static func fields(_ input: String) -> (String, String) {
    let fields = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    return (fields.first.map(String.init) ?? "",
      fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
  }

  private static func lines(_ body: String) -> [String] {
    body.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
  }

  private static func name(_ raw: String) throws -> String {
    let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    guard !name.isEmpty, name.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
    }) else { throw Error("Alias names must contain only letters, numbers, '-' or '_'.") }
    return name
  }

  private func update(_ edit: (inout [String: String]) throws -> Void) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lock = try MaiFileLock(url: url.appendingPathExtension("lock"))
    defer { withExtendedLifetime(lock) {} }
    var aliases = try load()
    try edit(&aliases)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(aliases).write(to: url, options: .atomic)
  }
}
