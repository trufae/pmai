import Foundation
import XCTest
@testable import ThemeEditor

final class ThemeEditorTests: XCTestCase {
  // Saving the wrong literal, losing comments, or emitting arguments out of
  // order would damage the user's source file or break the next pmai build.
  private let source = """
    enum TerminalTheme {
      static let builtins: [String: ConfiguredTerminalUI] = [
        "default": .init(),
        // "fake": .init(foreground: "red"),
        "ansi": .init(
          backgroundLine: "", foreground: "red", /* foreground: "red" */ background: "",
          bold: true),
        "rgb": .init(
          foreground: "rgb:abc", // keep this comment
          background: "#123456"),
      ]
      static var colors: [(String, WritableKeyPath<ConfiguredTerminalUI, String>)] {
        [("bgline", \\.backgroundLine), ("fgcolor", \\.foreground), ("bgcolor", \\.background)]
      }
      static var flags: [(String, WritableKeyPath<ConfiguredTerminalUI, Bool>)] {
        [("bold", \\.bold)]
      }
    }
    """
  private let configuration = """
    public struct ConfiguredTerminalUI {
      public init(
        backgroundLine: String = "rgb:024",
        foreground: String = "",
        background: String = "",
        bold: Bool = false
      ) {}
    }
    """

  private func fixture(source: String? = nil, _ body: (inout ThemeDocument) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("TerminalTheme.swift")
    let configURL = directory.appendingPathComponent("Configuration.swift")
    try (source ?? self.source).write(to: sourceURL, atomically: true, encoding: .utf8)
    try configuration.write(to: configURL, atomically: true, encoding: .utf8)
    var document = try ThemeDocument(sourceURL: sourceURL, configurationURL: configURL)
    try body(&document)
  }

  func testSaveChangesOnlyRequestedLiteralsAcrossThemes() throws {
    try fixture { document in
      XCTAssertEqual(document.themes.map(\.name), ["default", "ansi", "rgb"])
      try document.save()
      XCTAssertEqual(try String(contentsOf: document.sourceURL, encoding: .utf8), source)
      document.values["ansi"]!["foreground"] = "blue"
      document.values["rgb"]!["background"] = ""
      document.values["ansi"]!["bold"] = "false"
      try document.save()
      let expected = source
        .replacingOccurrences(of: "foreground: \"red\", /*", with: "foreground: \"blue\", /*")
        .replacingOccurrences(of: "background: \"#123456\"", with: "background: \"\"")
        .replacingOccurrences(of: "bold: true", with: "bold: false")
      XCTAssertEqual(try String(contentsOf: document.sourceURL, encoding: .utf8), expected)
      let reopened = try ThemeDocument(sourceURL: document.sourceURL, configurationURL: document.configurationURL)
      XCTAssertEqual(reopened.values, document.values)
      XCTAssertFalse(document.dirty)
    }
  }

  func testMissingOverridesUseInitializerOrderAndIndentation() throws {
    let indented = source.replacingOccurrences(of: "    ", with: "\t")
      .replacingOccurrences(of: "\n", with: "\r\n")
    try fixture(source: indented) { document in
      XCTAssertEqual(document.values["default"]?["backgroundLine"], "rgb:024")
      document.values["default"]!["foreground"] = "bright-white"
      document.values["default"]!["backgroundLine"] = ""
      document.values["rgb"]!["backgroundLine"] = "#010203"
      document.values["rgb"]!["bold"] = "true"
      try document.save()
      let saved = try String(contentsOf: document.sourceURL, encoding: .utf8)
      XCTAssertTrue(saved.contains("\"default\": .init(\r\n\t  backgroundLine: \"\",\r\n\t  foreground: \"bright-white\")"), saved)
      XCTAssertTrue(saved.contains("\t  backgroundLine: \"#010203\",\r\n\t  foreground: \"rgb:abc\", // keep this comment"), saved)
      XCTAssertTrue(saved.contains("background: \"#123456\",\r\n\t  bold: true)"), saved)
      let reopened = try ThemeDocument(sourceURL: document.sourceURL, configurationURL: document.configurationURL)
      XCTAssertEqual(reopened.values, document.values)
    }
  }

  func testSaveRefusesExternalChangesAndRetainsDraft() throws {
    try fixture { document in
      document.values["ansi"]!["foreground"] = "green"
      let external = source + "\n// edited elsewhere\n"
      try external.write(to: document.sourceURL, atomically: true, encoding: .utf8)
      XCTAssertThrowsError(try document.save())
      XCTAssertEqual(try String(contentsOf: document.sourceURL, encoding: .utf8), external)
      XCTAssertEqual(document.values["ansi"]?["foreground"], "green")
      XCTAssertTrue(document.dirty)
      try source.write(to: document.sourceURL, atomically: true, encoding: .utf8)
      try (configuration + "\n// new defaults\n").write(to: document.configurationURL, atomically: true, encoding: .utf8)
      XCTAssertThrowsError(try document.save())
      XCTAssertEqual(try String(contentsOf: document.sourceURL, encoding: .utf8), source)
    }
  }

  func testAppendingOverrideKeepsTrailingCommentWithOriginalField() throws {
    let commented = source.replacingOccurrences(of: "background: \"#123456\")",
      with: "background: \"#123456\" // background note\n    )")
    try fixture(source: commented) { document in
      document.values["rgb"]!["bold"] = "true"
      try document.save()
      let saved = try String(contentsOf: document.sourceURL, encoding: .utf8)
      XCTAssertEqual(saved, commented.replacingOccurrences(
        of: "background: \"#123456\" // background note\n    )",
        with: "background: \"#123456\", // background note\n      bold: true\n    )"))
    }
  }

  func testInvalidInputCannotWriteSwiftCode() throws {
    try fixture { document in
      document.values["ansi"]!["foreground"] = "\"); fatalError(\"oops\")"
      XCTAssertThrowsError(try document.save())
      XCTAssertEqual(try String(contentsOf: document.sourceURL, encoding: .utf8), source)
    }
  }

  // Group navigation must not edit a sibling component or lose another theme's
  // draft; undo must return to the actual edited theme and field.
  func testGroupedEditingPreservesComponentsAndThemeDrafts() throws {
    try fixture { document in
      var ui = ThemeEditorUI(document: document)
      func press(_ keys: [Key]) {
        for key in keys { XCTAssertTrue(ui.handle(key)) }
      }
      press([.character("j"), .character("b"), .character("e")])
      press("blue".map(Key.character) + [.enter, .tab, .character("f"), .character("n")])
      XCTAssertEqual(ui.document.values["default"]?["background"], "blue")
      XCTAssertEqual(ui.document.values["default"]?["foreground"], "")
      XCTAssertEqual(ui.document.values["ansi"]?["foreground"], "")
      XCTAssertEqual(ui.document.values["ansi"]?["background"], "")

      press([.backTab, .character("b"), .character("y"), .character("v"), .character("p")])
      XCTAssertEqual(ui.value, "false", "Pasting a color must not corrupt a Boolean")
      press([.enter, .character("u"), .character("u")])
      XCTAssertEqual(ui.theme, "ansi")
      XCTAssertEqual(ui.field.name, "foreground")
      XCTAssertEqual(ui.value, "red")
      press([.character("U"), .character("U")])
      XCTAssertEqual(ui.theme, "default")
      XCTAssertEqual(ui.field.name, "bold")
      XCTAssertEqual(ui.value, "true")
      XCTAssertTrue(ui.save())
      let reopened = try ThemeDocument(sourceURL: document.sourceURL, configurationURL: document.configurationURL)
      XCTAssertEqual(reopened.values, ui.document.values)
    }
  }

  // A resize must keep the selected value editable and must not wrap drawing
  // outside the terminal, including while entering a color or confirming quit.
  func testEditingSurvivesSmallTerminalLayouts() throws {
    try fixture { document in
      var ui = ThemeEditorUI(document: document)
      XCTAssertTrue(ui.handle(.character("j")))
      XCTAssertTrue(ui.handle(.character("f")))
      for (columns, rows) in [(84, 22), (60, 18), (40, 12), (20, 8), (10, 4), (1, 1), (84, 22)] {
        for key in [Key.character("e")] + "blue".map(Key.character) {
          XCTAssertTrue(ui.handle(key))
        }
        let editing = try visibleScreen(ui.frame(columns: columns, rows: rows, now: 0), columns: columns, rows: rows)
        if columns >= 20 { XCTAssertTrue(editing.contains("Color: blue_"), editing) }
        XCTAssertTrue(ui.handle(.enter))
        let edited = try visibleScreen(ui.frame(columns: columns, rows: rows, now: 0), columns: columns, rows: rows)
        if columns >= 20 {
          XCTAssertTrue(edited.contains("fgcolor = blue"), edited)
          XCTAssertTrue(edited.contains("pmai"), edited)
          XCTAssertTrue(edited.contains("Update"), edited)
        }
        XCTAssertTrue(ui.handle(.character("?")))
        _ = try visibleScreen(ui.frame(columns: columns, rows: rows, now: 0), columns: columns, rows: rows)
        XCTAssertTrue(ui.handle(.end))
        let help = try visibleScreen(ui.frame(columns: columns, rows: rows, now: 0), columns: columns, rows: rows)
        if columns >= 40 { XCTAssertTrue(help.contains("Ctrl-C: exit without saving"), help) }
        XCTAssertTrue(ui.handle(.escape))
        XCTAssertTrue(ui.handle(.character("q")))
        let confirmation = try visibleScreen(ui.frame(columns: columns, rows: rows, now: 0), columns: columns, rows: rows)
        if columns >= 20 {
          let joined = confirmation.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
          XCTAssertTrue(joined.contains("d discard"), confirmation)
          XCTAssertTrue(joined.contains("Esc stay"), confirmation)
        }
        XCTAssertTrue(ui.handle(.escape))
      }
      XCTAssertTrue(ui.save())
      let reopened = try ThemeDocument(sourceURL: document.sourceURL, configurationURL: document.configurationURL)
      XCTAssertEqual(reopened.values["default"]?["foreground"], "blue")
    }
  }

  func testPreviewReflowsWithinNarrowTerminals() {
    for width in [1, 4, 5, 12, 38] {
      for background in ["", "blue"] {
        let preview = ThemePreview(palette: ["bubbleBackground": background], width: width)
        for line in preview.lines {
          let text = line.spans.map(\.text).joined()
          XCTAssertLessThanOrEqual(text.count, width, text)
        }
      }
    }
  }

  private func visibleScreen(_ frame: String, columns: Int, rows: Int) throws -> String {
    var screen = Array(repeating: Array(repeating: Character(" "), count: columns), count: rows)
    var x = 0, y = 0
    var offset = frame.startIndex
    let escapes = try NSRegularExpression(pattern: "\u{1b}\\[([0-9;]*)([HKm])")
    func write(_ text: Substring) {
      for character in text {
        guard (0..<rows).contains(y), (0..<columns).contains(x) else {
          XCTFail("Drawing outside \(columns)x\(rows) at \(x + 1),\(y + 1)")
          return
        }
        screen[y][x] = character
        x += 1
      }
    }
    for match in escapes.matches(in: frame, range: NSRange(frame.startIndex..., in: frame)) {
      let range = Range(match.range, in: frame)!
      write(frame[offset..<range.lowerBound])
      let command = frame[Range(match.range(at: 2), in: frame)!]
      if command == "H" {
        let position = frame[Range(match.range(at: 1), in: frame)!].split(separator: ";").compactMap { Int($0) }
        y = position[0] - 1; x = position[1] - 1
        XCTAssertTrue((0..<rows).contains(y) && (0..<columns).contains(x), "Cursor outside terminal")
      } else if command == "K", (0..<rows).contains(y) {
        screen[y] = Array(repeating: " ", count: columns)
      }
      offset = range.upperBound
    }
    write(frame[offset...])
    return screen.map { String($0) }.joined(separator: "\n")
  }
}
