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
}
