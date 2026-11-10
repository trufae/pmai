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
  case tab, backTab, enter, escape, backspace, home, end, pageUp, pageDown, interrupt, eof
}

// Signal handlers only set a flag; terminal restoration happens on the main loop.
nonisolated(unsafe) private var stopSignal: Int32 = 0
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
    case 3, 4: return .interrupt
    case 9: return .tab
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

struct ThemeEditorUI {
  var document: ThemeDocument
  var themeIndex = 0
  var fieldIndex = 0
  var focus = 0
  var popup: (options: [String], selected: Int)?
  var input: String?
  var confirmation: String?
  var status = "Ready. Edits stay in memory until you save."
  var theme: String { document.themes[themeIndex].name }
  var field: ThemeField { document.fields[fieldIndex] }
  var value: String { document.values[theme]![field.name]! }
  var mode: Int { value.isEmpty ? 0 : ThemeColor.rgb(value) == nil ? 1 : 2 }
  var focusCount: Int { !field.isFlag && mode == 2 ? 7 : 4 }
  var controlRow: Int { [4, 6, 8, 10, 12, 13, 14][focus] }

  mutating func setValue(_ value: String) {
    document.values[theme]![field.name] = value
    status = "\(theme).\(field.name) = \(value.isEmpty ? "none" : value)"
    focus = min(focus, focusCount - 1)
  }

  func choices() -> (options: [String], selected: Int) {
    switch focus {
    case 0: return (document.themes.map(\.name), themeIndex)
    case 1: return (document.fields.map(\.name), fieldIndex)
    case 2:
      return field.isFlag ? (["false", "true"], value == "true" ? 1 : 0)
        : (["None", "ANSI", "RGB"], mode)
    default:
      return field.isFlag ? (["false", "true"], value == "true" ? 1 : 0)
        : (ThemeColor.names, ThemeColor.names.firstIndex(of: ThemeColor.aliases[value] ?? value) ?? 0)
    }
  }

  mutating func select(_ index: Int) {
    switch focus {
    case 0: themeIndex = index
    case 1: fieldIndex = index
    case 2:
      if field.isFlag { setValue(index == 1 ? "true" : "false") }
      else if index != mode { setValue(["", "white", "#808080"][index]) }
    default: setValue(field.isFlag ? (index == 1 ? "true" : "false") : ThemeColor.names[index])
    }
    focus = min(focus, focusCount - 1)
  }

  mutating func save() -> Bool {
    do {
      let count = document.changedCount
      try document.save()
      status = count == 0 ? "No changes to save." : "Saved \(count) changes to TerminalTheme.swift."
      return true
    } catch { status = error.localizedDescription; return false }
  }

  mutating func handle(_ key: Key) -> Bool {
    if key == .interrupt || key == .eof { return false }
    if let confirmation {
      if key == .escape || key == .character("n") { self.confirmation = nil }
      else if confirmation == "quit" {
        if key == .character("d") { return false }
        if key == .character("s") { self.confirmation = nil; return !save() }
      } else if key == .character("y") {
        self.confirmation = nil
        reload()
      }
      return true
    }
    if var input = input {
      switch key {
      case .escape: self.input = nil
      case .backspace: if !input.isEmpty { input.removeLast() }; self.input = input
      case .character(let character): if input.count < 32 { self.input = input + String(character) }
      case .enter:
        if let color = ThemeColor.normalize(input) { self.input = nil; setValue(color) }
        else { status = "Invalid color. Use none, blue, bright-red, #aabbcc, or rgb:abc." }
      default: break
      }
      return true
    }
    if var popup = popup {
      switch key {
      case .escape: self.popup = nil
      case .enter: self.popup = nil; select(popup.selected)
      case .up: popup.selected = max(0, popup.selected - 1); self.popup = popup
      case .down: popup.selected = min(popup.options.count - 1, popup.selected + 1); self.popup = popup
      case .home: popup.selected = 0; self.popup = popup
      case .end: popup.selected = popup.options.count - 1; self.popup = popup
      case .pageUp: popup.selected = max(0, popup.selected - 8); self.popup = popup
      case .pageDown: popup.selected = min(popup.options.count - 1, popup.selected + 8); self.popup = popup
      case .character(let c):
        let indices = Array(popup.options.indices.dropFirst(popup.selected + 1))
          + Array(popup.options.indices.prefix(popup.selected + 1))
        if let index = indices.first(where: { popup.options[$0].lowercased().hasPrefix(String(c).lowercased()) }) {
          popup.selected = index; self.popup = popup
        }
      default: break
      }
      return true
    }
    switch key {
    case .character("q"), .escape:
      if !document.dirty { return false }
      confirmation = "quit"
    case .character("s"): _ = save()
    case .character("r"): setValue(document.original[theme]![field.name]!)
    case .character("R"):
      if document.dirty { confirmation = "reload" } else { reload() }
    case .character("e") where !field.isFlag: input = ""
    case .tab, .down: focus = (focus + 1) % focusCount
    case .backTab, .up: focus = (focus + focusCount - 1) % focusCount
    case .enter, .character(" "):
      if focus == 3 && !field.isFlag && mode != 1 { input = "" }
      else if focus < 4 { popup = choices() }
    case .left, .right, .fastLeft, .fastRight, .character("-"), .character("+"), .home, .end:
      let direction = [.left, .fastLeft, .character("-")].contains(key) ? -1 : 1
      if focus >= 4, var rgb = ThemeColor.rgb(value) {
        let channel = focus - 4
        let step = key == .fastLeft || key == .fastRight ? 16 : 1
        rgb[channel] = key == .home ? 0 : key == .end ? 255 : max(0, min(255, rgb[channel] + direction * step))
        setValue(String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2]))
      } else if focus < 3 || field.isFlag || mode == 1 {
        let items = choices()
        select(key == .home ? 0 : key == .end ? items.options.count - 1
          : (items.selected + items.options.count + direction) % items.options.count)
      }
    default: break
    }
    return true
  }

  mutating func reload() {
    do {
      let name = theme
      let fieldName = field.name
      document = try ThemeDocument(sourceURL: document.sourceURL, configurationURL: document.configurationURL)
      themeIndex = document.themes.firstIndex(where: { $0.name == name }) ?? 0
      fieldIndex = document.fields.firstIndex(where: { $0.name == fieldName }) ?? 0
      focus = min(focus, focusCount - 1)
      status = "Reloaded themes from disk."
    } catch { status = error.localizedDescription }
  }

  func draw(columns: Int, rows: Int) {
    var output = Terminal.reset + "\u{1b}[H\u{1b}[2J"
    // UI labels are clipped separately from ANSI styling, so narrow windows
    // never wrap escape sequences or overwrite the preview.
    func put(_ x: Int, _ y: Int, _ text: String, width: Int, style: String = "") {
      guard y > 0, y <= rows, x <= columns else { return }
      let width = max(0, min(width, columns - x))
      let safe = text.map { $0.isASCII && !$0.isNewline && $0.asciiValue! >= 32 ? $0 : "?" }
      let clipped = String(safe.prefix(width))
      output += "\u{1b}[\(y);\(x)H" + Terminal.reset + style + clipped
        + String(repeating: " ", count: max(0, width - clipped.count)) + Terminal.reset
    }
    put(2, 1, "PMAI THEME EDITOR  |  \(theme)\(document.dirty ? "  * unsaved" : "")", width: columns - 3,
      style: "\u{1b}[1m")
    if columns < 78 || rows < 24 {
      put(2, 3, "Resize to at least 78 x 24 (now \(columns) x \(rows)).", width: columns - 3)
      put(2, 5, "s save  q quit  Ctrl-C exit", width: columns - 3)
    } else {
      func control(_ index: Int, _ row: Int, _ label: String, _ value: String) {
        put(2, row - 1, label, width: 37, style: "\u{1b}[2m")
        put(2, row, "\(focus == index ? ">" : " ") [ \(value) ]", width: 37,
          style: focus == index ? "\u{1b}[7m" : "")
      }
      control(0, 4, "Theme", theme + (document.values[theme] != document.original[theme] ? " *" : ""))
      control(1, 6, "Field  (\(field.shortName))", field.name)
      control(2, 8, field.isFlag ? "Flag" : "Color type", field.isFlag ? value : ["None", "ANSI", "RGB"][mode])
      control(3, 10, input == nil ? "Value  (e to type)" : "Type color, Enter apply, Esc cancel",
        input.map { $0 + "_" } ?? (value.isEmpty ? "none" : value))
      if !field.isFlag, let rgb = ThemeColor.rgb(value) {
        for channel in 0..<3 {
          let filled = rgb[channel] * 19 / 255
          let bar = String(repeating: "=", count: filled) + "|" + String(repeating: "-", count: 19 - filled)
          put(2, 12 + channel, "\(focus == channel + 4 ? ">" : " ") \(["R", "G", "B"][channel]) [\(bar)] \(rgb[channel])", width: 37,
            style: focus == channel + 4 ? "\u{1b}[7m" : "")
        }
        put(2, 16, "Left/Right: 1   Shift+arrow: 16", width: 37)
        put(2, 17, "Home/End: 0/255", width: 37)
      } else {
        put(2, 12, field.isFlag ? "Enter opens the selector." : mode == 1
          ? "ANSI uses your terminal palette." : "None uses the terminal default", width: 37)
        if !field.isFlag && mode == 0 { put(2, 13, "or the surrounding role's color.", width: 37) }
      }
      put(2, 19, "\(document.changedCount) changed fields across all themes", width: 37)
      put(2, 20, "r reset field   R reload source", width: 37)
      let x = 41
      let width = columns - x - 2
      let palette = document.values[theme]!
      func color(_ key: String) -> String { palette[key] ?? "" }
      func fallback(_ key: String, _ base: String) -> String { color(key).isEmpty ? color(base) : color(key) }
      func style(_ fg: String, _ bg: String, bold: Bool = false, italic: Bool = false) -> String {
        "\u{1b}[\(ThemeColor.code(fg));\(ThemeColor.code(bg, background: true));\(bold ? 1 : 22);\(italic ? 3 : 23)m"
      }
      let base = style(color("foreground"), color("background"))
      let edge = style(color("infoForeground"), color("background"))
      put(x, 3, "+" + String(repeating: "-", count: width - 2) + "+", width: width, style: edge)
      for y in 4...21 {
        put(x, y, "|", width: 1, style: edge)
        put(x + 1, y, "", width: width - 2, style: base)
        put(x + width - 1, y, "|", width: 1, style: edge)
      }
      func sample(_ y: Int, _ text: String, fg: String = "foreground", bg: String = "background",
        inheritFG: Bool = false, inheritBG: Bool = false, bold: Bool = false, italic: Bool = false) {
        put(x + 2, y, text, width: width - 4,
          style: style(inheritFG ? fallback(fg, "foreground") : color(fg),
            inheritBG ? fallback(bg, "background") : color(bg), bold: bold, italic: italic))
      }
      sample(4, " pmai / \(theme)", fg: "infoForeground", bg: "backgroundLine", bold: true)
      let bubble = color("bubbleBackground").isEmpty
      sample(5, bubble ? "+-----------------------------+" : "                               ",
        fg: "bubbleForeground", bg: "bubbleBackground", inheritFG: true, inheritBG: true)
      sample(6, bubble ? "| You: Update the greeting.    |" : "  You: Update the greeting.",
        fg: "bubbleForeground", bg: "bubbleBackground", inheritFG: true, inheritBG: true, bold: color("bold") == "true")
      sample(7, bubble ? "+-----------------------------+" : "                               ",
        fg: "bubbleForeground", bg: "bubbleBackground", inheritFG: true, inheritBG: true)
      sample(8, "Thinking... reading the source", fg: "thinkingForeground")
      sample(9, "-> file_read Sources/main.swift", fg: "toolCallForeground", bg: "toolCallBackground",
        inheritBG: true, bold: color("toolCallBold") == "true")
      sample(10, "<- Found the greeting", fg: "toolResultForeground", bg: "toolResultBackground", inheritBG: true)
      sample(11, "pmai: Here is the change:")
      sample(12, "@@ main.swift @@", fg: "diffHeaderForeground")
      sample(13, "- print(\"Hello\")", fg: "diffRemovedForeground", bg: "diffRemovedBackground")
      sample(14, "+ print(\"Hello, world!\")", fg: "diffAddedForeground", bg: "diffAddedBackground")
      sample(15, "Bold Markdown emphasis", fg: "boldForeground", inheritFG: true, bold: true)
      sample(16, "Italic Markdown emphasis", fg: "italicForeground", inheritFG: true, italic: true)
      sample(17, "Success: greeting updated", fg: "successForeground")
      sample(18, "Warning: unsaved changes", fg: "warningForeground")
      sample(19, "Error: example failure", fg: "errorForeground")
      sample(20, "Selected conversation", fg: "selectionForeground", bg: "selectionBackground")
      sample(21, "> Ask a follow-up", bg: "promptBackground", inheritBG: true, bold: color("bold") == "true")
      put(x + 2, 21, ">", width: 1, style: style(color("promptForeground"), fallback("promptBackground", "background")))
      put(x, 22, "+" + String(repeating: "-", count: width - 2) + "+", width: width, style: edge)
      if let popup {
        let top = controlRow + 1
        let height = min(9, rows - top - 3, popup.options.count)
        let start = max(0, min(popup.selected - height / 2, popup.options.count - height))
        for offset in 0..<height {
          let index = start + offset
          put(2, top + offset, "\(index == popup.selected ? ">" : " ") \(popup.options[index])", width: 37,
            style: index == popup.selected ? "\u{1b}[7m" : "\u{1b}[0m")
        }
        put(2, top + height, "  \(popup.selected + 1)/\(popup.options.count)  Enter select / Esc close", width: 37,
          style: "\u{1b}[2m")
      }
    }
    let message = confirmation == "quit" ? "Unsaved edits: s save & quit / d discard / Esc stay"
      : confirmation == "reload" ? "Reload and discard unsaved edits? y yes / n no" : status
    put(2, rows - 1, message, width: columns - 3, style: confirmation == nil ? "" : "\u{1b}[7m")
    put(2, rows, "Tab focus | Enter select | Left/Right adjust | e color | s save | q quit", width: columns - 3,
      style: "\u{1b}[2m")
    Terminal.write(output)
  }

  mutating func run() throws {
    try Terminal.run {
      var previous = (columns: 0, rows: 0)
      var redraw = true
      while stopSignal == 0 {
        let size = Terminal.size
        if redraw || size != previous { draw(columns: size.columns, rows: size.rows); previous = size }
        redraw = false
        if let key = Terminal.readKey() {
          if !handle(key) { break }
          redraw = true
        }
      }
    }
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
          Tab/Up/Down focus; Enter opens selectors; Left/Right changes values.
          RGB sliders: arrows +/-1, Shift+arrows +/-16, Home/End 0/255.
          e enters a color: none, an ANSI name, #rrggbb, or rgb:rgb.
          s/Ctrl-S saves all edited themes; r resets a field; R reloads; q quits.
          Ctrl-C exits without saving. Requires a terminal of at least 78 x 24.
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
