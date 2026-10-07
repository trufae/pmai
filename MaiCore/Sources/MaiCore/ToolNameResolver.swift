import Foundation

public struct AgentToolNameResolver: Sendable {
  private let canonicalByAlias: [String: String]
  private let canonicalByShortAlias: [String: String]
  private let apiByCanonical: [String: String]

  public init(tools: [ToolDefinition]) {
    var aliases: [String: String] = [:]
    var shortAliases: [String: String] = [:]
    var ambiguousShortAliases = Set<String>()
    var apiNames: [String: String] = [:]
    var usedAPI = Set<String>()

    for tool in tools {
      let preferredName = tool.providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let api = Self.uniqueAPIName(
        for: preferredName.flatMap { $0.isEmpty ? nil : $0 } ?? tool.name,
        used: &usedAPI)
      apiNames[tool.name] = api
      var candidates = [
        tool.name,
        api,
        tool.name.replacingOccurrences(of: "::", with: "."),
        tool.name.replacingOccurrences(of: "::", with: "_"),
        tool.name.replacingOccurrences(of: "::", with: "__"),
      ]
      if let preferredName, !preferredName.isEmpty {
        candidates.append(preferredName)
      }
      for candidate in candidates {
        aliases[Self.key(candidate)] = tool.name
        let candidateShortKey = Self.shortKey(candidate)
        if let existing = shortAliases[candidateShortKey], existing != tool.name {
          ambiguousShortAliases.insert(candidateShortKey)
        } else {
          shortAliases[candidateShortKey] = tool.name
        }
      }
      let shortKey = Self.shortKey(tool.name)
      if let existing = shortAliases[shortKey], existing != tool.name {
        ambiguousShortAliases.insert(shortKey)
      } else {
        shortAliases[shortKey] = tool.name
      }
    }
    for key in ambiguousShortAliases {
      shortAliases.removeValue(forKey: key)
    }

    canonicalByAlias = aliases
    canonicalByShortAlias = shortAliases
    apiByCanonical = apiNames
  }

  public init(definitions: [ToolDefinition]) {
    self.init(tools: definitions)
  }

  public func canonicalName(for name: String) -> String? {
    if let known = canonicalByAlias[Self.key(name)] ?? canonicalByShortAlias[Self.shortKey(name)] {
      return known
    }
    // A model writing a call in its own syntax can hand the server a name with
    // the arguments glued on ("run_shell Optimize:", "files_read.arguments"). The
    // leading identifier is the tool it meant; failing it costs a whole turn.
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let head = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    guard !head.isEmpty, head.count < trimmed.count else { return nil }
    return canonicalByAlias[Self.key(String(head))]
  }

  public func apiName(for canonical: String) -> String {
    apiByCanonical[canonical] ?? Self.sanitizeAPIName(canonical)
  }

  public func providerName(for canonicalName: String) -> String {
    apiName(for: canonicalName)
  }

  private static func key(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  private static func shortKey(_ name: String) -> String {
    let normalized = name.replacingOccurrences(of: "::", with: ".")
    guard let last = normalized.split(separator: ".").last else { return key(name) }
    return key(String(last))
  }

  private static func uniqueAPIName(for name: String, used: inout Set<String>) -> String {
    let base = sanitizeAPIName(name)
    var candidate = base
    var n = 2
    while used.contains(candidate) {
      let suffix = "_\(n)"
      candidate = String(base.prefix(max(1, 64 - suffix.count))) + suffix
      n += 1
    }
    used.insert(candidate)
    return candidate
  }

  private static func sanitizeAPIName(_ name: String) -> String {
    var out = ""
    var lastWasUnderscore = false
    for scalar in name.unicodeScalars {
      let isAllowed =
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
      if isAllowed {
        out.unicodeScalars.append(scalar)
        lastWasUnderscore = false
      } else if !lastWasUnderscore {
        out.append("_")
        lastWasUnderscore = true
      }
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    if out.isEmpty { out = "tool" }
    if out.first?.isNumber == true { out = "tool_\(out)" }
    if out.count > 64 {
      out = String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }
    return out
  }
}

/// Provider-facing tool naming uses the same resolver as textual tool protocols.
public typealias ToolNameResolver = AgentToolNameResolver
