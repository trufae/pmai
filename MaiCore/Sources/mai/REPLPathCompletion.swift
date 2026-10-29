import Foundation

/// Filesystem candidates are discovered on Tab, relative to the current cwd.
/// Some commands take the entire remaining argument literally; others use shell words.
enum REPLPathCompletion {
  private struct Context {
    var prefix: String
    var path: String
    var shell: Bool
    var directoriesOnly: Bool = false
  }

  private static let patterns: [(NSRegularExpression, Bool, Bool)] = [
    (#"^(\s*\.\s+)(.*)$"#, true, false),
    (#"^(\s*/projects\s+(?:open|switch|del)\s+)(.*)$"#, true, true),
    (#"^(\s*/project\s+del\s+)(.*)$"#, false, true),
    (#"^(\s*/skills\s+import\s+(?:(?:--user|--project)\s+)?)(.*)$"#, true, false),
    (#"^(\s*/remote\s+pair\s+)(.*)$"#, true, false),
    (#"^(\s*/provider\s+add\s+.*?--api-key-file\s+)(.*)$"#, true, false),
    (#"^(\s*/mcp\s+add\s+(?:.*?\s+)?--cwd\s+)(.*)$"#, true, true),
    (#"^(\s*/cd\s+)(.*)$"#, false, true),
    (#"^(\s*/attach\s+(?:source|markdown|copy)\s+)(.*)$"#, false, false),
    (#"^(\s*/(?:import|attach)\s+)(.*)$"#, false, false),
    (#"^(\s*/copy\s+(?:[0-9]+\s+)?)(.*)$"#, false, false),
    (#"^(\s*/export\s+(?:archive|pack|portable|txt|text|md|markdown|html|json|debug|epub|docx)\s+)(.*)$"#, false, false),
    (#"^(\s*/image\s+(?:tiny|small|medium|big|full|ocr)\s+)(.*)$"#, false, false),
    (#"^(\s*/vdb\s+(?:index|del)\s+)(.*)$"#, false, false),
    (#"^(\s*/path\s+(?:allow|add|deny|reject|ask|prompt|del)\s+)(.*)$"#, false, false),
    (#"^(\s*/set\s+debugfile\s+(?:=\s*)?)(.*)$"#, false, false),
  ].map { (try! NSRegularExpression(pattern: $0.0), $0.1, $0.2) }

  static func candidates(for line: String, directory: URL = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) -> [String] {
    guard !line.contains("\n"), let context = context(for: line) else { return [] }
    var path = context.path
    var quote: Character?
    if path.first == "\"" || path.first == "'" {
      quote = path.removeFirst()
      if path.last == quote { path.removeLast() }
    }
    if context.shell {
      // Decode an unfinished shell word without running a shell or expanding variables.
      var decoded = ""
      var escaped = false
      for character in path {
        if escaped { decoded.append(character); escaped = false }
        else if character == "\\", quote != "'" { escaped = true }
        else if quote == nil, character.isWhitespace { return [] }
        else { decoded.append(character) }
      }
      path = decoded
    }
    let slash = path.lastIndex(of: "/")
    let parent = slash.map { String(path[...$0]) } ?? ""
    let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
    let expanded = NSString(string: parent.isEmpty ? "." : parent).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: directory)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: nil) else { return [] }
    return entries.compactMap { entry in
      let filename = entry.lastPathComponent
      guard filename.hasPrefix(name), !filename.hasPrefix(".") || name.hasPrefix(".") else { return nil }
      var directoryFlag: ObjCBool = false
      _ = FileManager.default.fileExists(atPath: entry.path, isDirectory: &directoryFlag)
      let isDirectory = directoryFlag.boolValue
      guard !context.directoriesOnly || isDirectory else { return nil }
      let value = parent + filename + (isDirectory ? "/" : "")
      let argument: String
      if context.shell {
        if let quote, !value.contains(quote), !value.contains("\\"),
          quote == "'" || !value.contains("$") && !value.contains("`")
        {
          argument = String(quote) + value + (isDirectory ? "" : String(quote))
        } else {
          argument = value.reduce(into: "") { result, character in
            if character.isWhitespace || "\\\"'`$;&|<>()*?[]{}!".contains(character) { result.append("\\") }
            result.append(character)
          }
        }
      } else {
        // These commands already accept spaces as part of the remaining path.
        argument = value
      }
      return context.prefix + argument
    }.sorted()
  }

  private static func context(for line: String) -> Context? {
    if line.hasPrefix("/then "), var nested = context(for: String(line.dropFirst(6))) {
      nested.prefix = "/then " + nested.prefix
      return nested
    }
    // Appending a marker lets the redirect parser recognize an empty destination too.
    let marker = "__pmai_path_completion__"
    if let redirect = try? REPLRedirectSyntax.parse(line + marker) {
      guard case .file(let target, _) = redirect.destination else { return nil }
      let path = String(target.dropLast(marker.count))
      return Context(prefix: String(line.dropLast(path.count)), path: path, shell: true)
    }
    // --path takes several shell words; complete only the last, including quoted spaces.
    if line.trimmingCharacters(in: .whitespaces).hasPrefix("/remote serve "),
      let flag = line.range(of: #"--paths?\s+"#, options: .regularExpression, range: nil, locale: nil)
    {
      var start = flag.upperBound
      var quote: Character?
      var escaped = false
      for index in line.indices where index >= flag.upperBound {
        let character = line[index]
        if escaped { escaped = false; continue }
        if character == "\\", quote != "'" { escaped = true; continue }
        if character == quote { quote = nil }
        else if quote == nil, character == "'" || character == "\"" { quote = character }
        else if quote == nil, character.isWhitespace { start = line.index(after: index) }
      }
      let rest = String(line[flag.upperBound...])
      guard !rest.contains("--") else { return nil }
      return Context(prefix: String(line[..<start]), path: String(line[start...]), shell: true, directoriesOnly: true)
    }
    for (regex, shell, directoriesOnly) in patterns {
      guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let prefix = Range(match.range(at: 1), in: line),
        let path = Range(match.range(at: 2), in: line) else { continue }
      return Context(prefix: String(line[prefix]), path: String(line[path]), shell: shell, directoriesOnly: directoriesOnly)
    }
    return nil
  }
}
