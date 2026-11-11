import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct EditorError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

// A small lexer keeps comments and quoted text out of structural searches. Byte
// ranges let saves replace literals without reformatting the surrounding Swift.
struct SourceToken {
  let text: String
  let range: Range<Int>
}

func sourceTokens(_ bytes: [UInt8]) throws -> [SourceToken] {
  var result: [SourceToken] = []
  var i = 0
  func pair(_ a: UInt8, _ b: UInt8) -> Bool {
    i + 1 < bytes.count && bytes[i] == a && bytes[i + 1] == b
  }
  while i < bytes.count {
    let start = i
    if [9, 10, 13, 32].contains(bytes[i]) { i += 1; continue }
    if pair(47, 47) {
      while i < bytes.count && bytes[i] != 10 { i += 1 }
      continue
    }
    if pair(47, 42) {
      i += 2
      var depth = 1
      while i < bytes.count && depth > 0 {
        if pair(47, 42) { depth += 1; i += 2 }
        else if pair(42, 47) { depth -= 1; i += 2 }
        else { i += 1 }
      }
      guard depth == 0 else { throw EditorError("Unterminated Swift comment.") }
      continue
    }
    if bytes[i] == 34 {
      i += 1
      while i < bytes.count && bytes[i] != 34 {
        i += bytes[i] == 92 ? 2 : 1
      }
      guard i < bytes.count else { throw EditorError("Unterminated Swift string.") }
      i += 1
    } else if (65...90).contains(bytes[i]) || (97...122).contains(bytes[i]) || bytes[i] == 95 {
      while i < bytes.count && ((65...90).contains(bytes[i]) || (97...122).contains(bytes[i])
        || (48...57).contains(bytes[i]) || bytes[i] == 95) { i += 1 }
    } else { i += 1 }
    result.append(SourceToken(text: String(decoding: bytes[start..<i], as: UTF8.self), range: start..<i))
  }
  return result
}

func literalValue(_ text: String) throws -> String {
  if text == "true" || text == "false" { return text }
  guard text.first == "\"", text.last == "\"", !text.contains("\\") else {
    throw EditorError("Expected a plain string or Boolean literal, found \(text).")
  }
  return String(text.dropFirst().dropLast())
}

struct ThemeField {
  let name: String
  let shortName: String
  let initial: String
  let isFlag: Bool
  func literal(_ value: String) throws -> String {
    if isFlag {
      guard ["true", "false"].contains(value) else { throw EditorError("Expected true or false.") }
      return value
    }
    guard let normalized = ThemeColor.normalize(value) else {
      throw EditorError("Use none, an ANSI name, #rrggbb, or rgb:rgb.")
    }
    return "\"\(normalized)\""
  }
}

struct ThemeArgument {
  let name: SourceToken
  let value: SourceToken
}

struct SourceTheme {
  let name: String
  let nameStart: Int
  let open: Int
  let close: Int
  let arguments: [ThemeArgument]
}

func parseThemes(_ bytes: [UInt8]) throws -> [SourceTheme] {
  let tokens = try sourceTokens(bytes)
  guard let start = tokens.firstIndex(where: { $0.text == "builtins" }),
    let equal = tokens[start...].firstIndex(where: { $0.text == "=" }),
    equal + 1 < tokens.count, tokens[equal + 1].text == "["
  else { throw EditorError("Cannot find TerminalTheme.builtins.") }
  var i = equal + 2
  var themes: [SourceTheme] = []
  while i < tokens.count && tokens[i].text != "]" {
    guard i + 5 < tokens.count,
      tokens[(i + 1)...(i + 4)].map(\.text) == [":", ".", "init", "("]
    else { throw EditorError("Expected a named theme with a literal .init(...).") }
    let name = try literalValue(tokens[i].text)
    let nameStart = tokens[i].range.lowerBound
    let open = tokens[i + 4].range.upperBound
    i += 5
    var arguments: [ThemeArgument] = []
    while i < tokens.count && tokens[i].text != ")" {
      guard i + 2 < tokens.count, tokens[i + 1].text == ":",
        !arguments.contains(where: { $0.name.text == tokens[i].text })
      else { throw EditorError("Unsupported or duplicate argument in theme \(name).") }
      _ = try literalValue(tokens[i + 2].text)
      arguments.append(ThemeArgument(name: tokens[i], value: tokens[i + 2]))
      i += 3
      if i < tokens.count && tokens[i].text == "," { i += 1 }
      else if i >= tokens.count || tokens[i].text != ")" {
        throw EditorError("Expected a comma or closing parenthesis in theme \(name).")
      }
    }
    guard i < tokens.count, !themes.contains(where: { $0.name == name }) else {
      throw EditorError("Missing closing parenthesis or duplicate theme \(name).")
    }
    themes.append(SourceTheme(name: name, nameStart: nameStart, open: open,
      close: tokens[i].range.lowerBound, arguments: arguments))
    i += 1
    if i < tokens.count && tokens[i].text == "," { i += 1 }
    else if i >= tokens.count || tokens[i].text != "]" { throw EditorError("Expected a theme separator.") }
  }
  guard i < tokens.count, !themes.isEmpty else { throw EditorError("No complete theme dictionary found.") }
  return themes
}

struct ThemeDocument {
  let sourceURL: URL
  let configurationURL: URL
  private(set) var source: [UInt8]
  private let configuration: Data
  let fields: [ThemeField]
  private(set) var themes: [SourceTheme]
  private(set) var original: [String: [String: String]]
  var values: [String: [String: String]]

  init(sourceURL: URL, configurationURL: URL) throws {
    self.sourceURL = sourceURL
    self.configurationURL = configurationURL
    source = Array(try Data(contentsOf: sourceURL))
    configuration = try Data(contentsOf: configurationURL)
    themes = try parseThemes(source)
    // Read the editable names from TerminalTheme.colors/flags, and their order
    // and defaults from ConfiguredTerminalUI's initializer. No copied palette.
    let themeTokens = try sourceTokens(source)
    var names: [String: String] = [:]
    for i in themeTokens.indices where i + 7 < themeTokens.count {
      if themeTokens[i].text == "(", themeTokens[i + 1].text.hasPrefix("\""),
        themeTokens[(i + 2)...(i + 4)].map(\.text) == [",", "\\", "."],
        themeTokens[i + 6].text == ")" {
        names[themeTokens[i + 5].text] = try literalValue(themeTokens[i + 1].text)
      }
    }
    let configTokens = try sourceTokens(Array(configuration))
    guard let type = configTokens.firstIndex(where: { $0.text == "ConfiguredTerminalUI" }),
      let initializer = configTokens[type...].firstIndex(where: { $0.text == "init" })
    else { throw EditorError("Cannot find ConfiguredTerminalUI's initializer.") }
    var fields: [ThemeField] = []
    for i in initializer..<configTokens.count where i + 4 < configTokens.count {
      if configTokens[i].text == "{" { break }
      let name = configTokens[i].text
      guard let shortName = names[name], configTokens[i + 1].text == ":",
        ["String", "Bool"].contains(configTokens[i + 2].text), configTokens[i + 3].text == "="
      else { continue }
      let field = ThemeField(name: name, shortName: shortName,
        initial: try literalValue(configTokens[i + 4].text), isFlag: configTokens[i + 2].text == "Bool")
      _ = try field.literal(field.initial)
      fields.append(field)
    }
    guard !fields.isEmpty, fields.count == names.count else {
      throw EditorError("Cannot resolve all theme fields from ConfiguredTerminalUI.")
    }
    self.fields = fields
    var initial: [String: [String: String]] = [:]
    for theme in themes {
      var values = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.initial) })
      for argument in theme.arguments {
        guard let field = fields.first(where: { $0.name == argument.name.text }) else {
          throw EditorError("Unsupported theme field \(argument.name.text).")
        }
        let value = try literalValue(argument.value.text)
        _ = try field.literal(value)
        values[field.name] = value
      }
      initial[theme.name] = values
    }
    original = initial
    values = initial
  }

  var dirty: Bool { values != original }
  var changedCount: Int {
    themes.reduce(0) { count, theme in
      count + fields.filter { values[theme.name]?[$0.name] != original[theme.name]?[$0.name] }.count
    }
  }

  func editedSource() throws -> [UInt8] {
    var bytes = source
    let newline = source.contains(13) ? "\r\n" : "\n"
    func linePrefix(_ position: Int) -> String {
      let start = bytes[..<position].lastIndex(of: 10).map { $0 + 1 } ?? 0
      return String(decoding: bytes[start..<position].prefix { $0 == 32 || $0 == 9 }, as: UTF8.self)
    }
    func startsLine(_ position: Int) -> Bool {
      let start = bytes[..<position].lastIndex(of: 10).map { $0 + 1 } ?? 0
      return position - start == linePrefix(position).utf8.count
    }
    for theme in themes {
      for (order, field) in fields.enumerated() {
        guard let value = values[theme.name]?[field.name], value != original[theme.name]?[field.name]
        else { continue }
        let literal = try field.literal(value)
        let current = try parseThemes(bytes).first { $0.name == theme.name }!
        if let argument = current.arguments.first(where: { $0.name.text == field.name }) {
          bytes.replaceSubrange(argument.value.range, with: literal.utf8)
        } else if let next = current.arguments.first(where: { argument in
          fields.firstIndex(where: { $0.name == argument.name.text })! > order
        }) {
          let at = next.name.range.lowerBound
          let prefix = linePrefix(at)
          let separator = startsLine(at) ? newline + prefix : " "
          bytes.insert(contentsOf: "\(field.name): \(literal),\(separator)".utf8, at: at)
        } else if let last = current.arguments.last {
          let first = current.arguments[0].name.range.lowerBound
          let indent = startsLine(first) ? linePrefix(first) : linePrefix(current.nameStart) + "  "
          let suffix = Array(bytes[last.value.range.upperBound..<current.close])
          if suffix.contains(47) {
            // Leave a trailing comment with its original argument. A comma
            // belongs before that comment; the new field belongs after it.
            let comma = try sourceTokens(suffix).contains { $0.text == "," }
            let closingIndent = linePrefix(current.close)
            let at = startsLine(current.close) ? current.close - closingIndent.utf8.count : current.close
            let insertion = (startsLine(current.close) ? "" : newline)
              + "\(indent)\(field.name): \(literal)\(comma ? "," : "")\(newline)"
            bytes.insert(contentsOf: insertion.utf8, at: at)
            if !comma { bytes.insert(44, at: last.value.range.upperBound) }
          } else {
            bytes.insert(contentsOf: ",\(newline)\(indent)\(field.name): \(literal)".utf8,
              at: last.value.range.upperBound)
          }
        } else {
          let indent = linePrefix(current.nameStart) + "  "
          // Keep any comments inside an otherwise empty initializer.
          bytes.insert(contentsOf: "\(newline)\(indent)\(field.name): \(literal)".utf8, at: current.open)
        }
      }
    }
    _ = try parseThemes(bytes)
    return bytes
  }

  mutating func save() throws {
    guard try Data(contentsOf: sourceURL) == Data(source),
      try Data(contentsOf: configurationURL) == configuration
    else { throw EditorError("Source changed on disk. R reloads; your edits are still in memory.") }
    guard dirty else { return }
    let edited = try editedSource()
    try Data(edited).write(to: sourceURL, options: .atomic)
    source = edited
    themes = try parseThemes(edited)
    original = values
  }
}

enum ThemeColor {
  static let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "bright-black", "bright-red", "bright-green", "bright-yellow", "bright-blue",
    "bright-magenta", "bright-cyan", "bright-white"]
  static let aliases = ["brown": "yellow", "dark-blue": "blue", "purple": "magenta",
    "grey": "bright-black", "orange": "bright-yellow", "violet": "bright-magenta", "pink": "bright-magenta"]

  static func rgb(_ value: String) -> [Int]? {
    let hex: String
    if value.hasPrefix("#"), value.count == 7 { hex = String(value.dropFirst()) }
    else if value.hasPrefix("rgb:"), value.count == 7 {
      hex = value.dropFirst(4).map { "\($0)\($0)" }.joined()
    } else { return nil }
    guard hex.allSatisfy({ $0.isASCII && $0.isHexDigit }), let packed = Int(hex, radix: 16) else { return nil }
    return [(packed >> 16) & 255, (packed >> 8) & 255, packed & 255]
  }

  static func normalize(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["", "none", "default", "off", "-"].contains(value) { return "" }
    return rgb(value) != nil || names.contains(value) || aliases[value] != nil ? value : nil
  }

  static func code(_ value: String, background: Bool = false) -> String {
    if let rgb = rgb(value.lowercased()) { return "\(background ? 48 : 38);2;\(rgb[0]);\(rgb[1]);\(rgb[2])" }
    let name = value.lowercased()
    if let index = names.firstIndex(of: aliases[name] ?? name) {
      return String((index < 8 ? 30 + index : 90 + index - 8) + (background ? 10 : 0))
    }
    return background ? "49" : "39"
  }
}

enum Key: Equatable {
  case character(Character), up, down, left, right, fastLeft, fastRight
  case tab, backTab, enter, escape, backspace, home, end, pageUp, pageDown, interrupt, eof, listPageUp, listPageDown
}

// Signal handlers only set a flag; terminal restoration happens on the main loop.
nonisolated(unsafe) var stopSignal: Int32 = 0
private func editorSignal(_ number: Int32) { stopSignal = number }

struct Terminal {
  static let reset = "\u{1b}[0m"
  static func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
  static var size: (columns: Int, rows: Int) {
    var size = winsize()
    _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size)
    return (size.ws_col > 0 ? Int(size.ws_col) : 80, size.ws_row > 0 ? Int(size.ws_row) : 24)
  }

  static func readByte(timeout: Int32) -> Int? {
    var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&fd, 1, timeout) > 0 else { return nil }
    var byte: UInt8 = 0
    let count = read(STDIN_FILENO, &byte, 1)
    if count < 0 && errno == EINTR { return nil }
    return count == 1 ? Int(byte) : -1
  }

  static func readKey() -> Key? {
    guard let byte = readByte(timeout: 100) else { return nil }
    switch byte {
    case -1: return .eof
    case 3: return .interrupt
    case 9: return .tab
    case 21: return .listPageUp
    case 4: return .listPageDown
    case 10, 13: return .enter
    case 8, 127: return .backspace
    case 27:
      guard let next = readByte(timeout: 100) else { return .escape }
      guard next == 91 || next == 79 else { return .escape }
      var sequence = ""
      while sequence.count < 16, let value = readByte(timeout: 100), value >= 0 {
        sequence.append(Character(UnicodeScalar(value)!))
        if (64...126).contains(value) { break }
      }
      return ["A": .up, "B": .down, "C": .right, "D": .left, "Z": .backTab,
        "H": .home, "F": .end, "1~": .home, "4~": .end, "7~": .home, "8~": .end,
        "5~": .pageUp, "6~": .pageDown, "1;2C": .fastRight, "1;2D": .fastLeft][sequence]
    default:
      return byte == 19 ? .character("s") : (32...126).contains(byte)
        ? .character(Character(UnicodeScalar(byte)!)) : nil
    }
  }

  static func run(_ body: () throws -> Void) throws {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
      throw EditorError("ThemeEditor needs an interactive terminal. Use --help for usage.")
    }
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw EditorError("Cannot read terminal settings.") }
    var raw = original
    cfmakeraw(&raw)
    let oldINT = signal(SIGINT, editorSignal)
    let oldTERM = signal(SIGTERM, editorSignal)
    let oldHUP = signal(SIGHUP, editorSignal)
    // Raw mode disables Ctrl-Z, avoiding a stopped process leaving a raw terminal.
    defer {
      write(reset + "\u{1b}[?25h\u{1b}[?1049l")
      _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
      signal(SIGINT, oldINT); signal(SIGTERM, oldTERM); signal(SIGHUP, oldHUP)
    }
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { throw EditorError("Cannot enter raw mode.") }
    write("\u{1b}[?1049h\u{1b}[?25l")
    try body()
  }
}

@main
struct ThemeEditor {
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments == ["--help"] || arguments == ["-h"] {
        print("""
          Usage: swift run --package-path sys/theme-editor ThemeEditor [--root REPOSITORY]

          Edit MaiCore/Sources/MaiCLI/Terminal/TerminalTheme.swift in a terminal.
          Tab/Shift-Tab switch themes; j/k or Up/Down select grouped elements.
          h/l cycle fg/bg/bold; f/b/v select a component; Enter/e edits.
          Left/Right adjusts values; 1/2/3 selects an RGB channel; Shift+arrows +/-16.
          c cycles None/ANSI/RGB; n clears; y/p copies/pastes; u/U undoes/redoes.
          PgUp/PgDn scrolls the preview; . blinks the affected sample; ? shows help.
          e enters a color: none, an ANSI name, #rrggbb, or rgb:rgb.
          s/Ctrl-S saves all edited themes; r resets a field; R reloads; q quits.
          Ctrl-C exits without saving. The layout adapts to the terminal size.
          Rebuild pmai after saving to use the edited built-in themes.
          """)
        return
      }
      guard arguments.isEmpty || arguments.count == 2 && arguments[0] == "--root" else {
        throw EditorError("Unknown arguments. Use --help for usage.")
      }
      let root = try repositoryRoot(explicit: arguments.last)
      var ui = ThemeEditorUI(document: try ThemeDocument(
        sourceURL: root.appendingPathComponent("MaiCore/Sources/MaiCLI/Terminal/TerminalTheme.swift"),
        configurationURL: root.appendingPathComponent("MaiCore/Sources/MaiCore/Configuration.swift")))
      try ui.run()
      if stopSignal != 0 { exit(128 + stopSignal) }
    } catch {
      FileHandle.standardError.write(Data("ThemeEditor: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  static func repositoryRoot(explicit: String?) throws -> URL {
    if let explicit { return URL(fileURLWithPath: explicit).standardizedFileURL }
    for start in [URL(fileURLWithPath: FileManager.default.currentDirectoryPath), URL(fileURLWithPath: #filePath)] {
      var candidate = start
      while candidate.path != "/" {
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(
          "MaiCore/Sources/MaiCLI/Terminal/TerminalTheme.swift").path) { return candidate }
        candidate.deleteLastPathComponent()
      }
    }
    throw EditorError("Cannot find the pmai checkout. Pass --root /path/to/pmai.")
  }
}
