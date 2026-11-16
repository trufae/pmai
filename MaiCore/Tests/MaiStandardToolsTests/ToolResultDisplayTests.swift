import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

@Test("Tool result display loads legacy counts and persists relevant mode")
func toolResultDisplayConfiguration() throws {
  let cases: [(String, ToolResultDisplay)] = [
    ("{}", .lines(0)),
    (#"{"tools":-1}"#, .all),
    (#"{"tools":"all"}"#, .all),
    (#"{"tools":0}"#, .lines(0)),
    (#"{"tools":"relevant"}"#, .relevant),
    (#"{"tools":"icons"}"#, .icons),
    (#"{"tools":7,"toolResultLines":0}"#, .lines(7)),
    (#"{"toolResultLines":-1}"#, .all),
    (#"{"toolResultLines":-20}"#, .all),
    (#"{"toolResultLines":0}"#, .lines(0)),
    (#"{"toolResultLines":7}"#, .lines(7)),
    (#"{"toolResultLines":"all"}"#, .all),
    (#"{"toolResultLines":"relevant"}"#, .relevant),
    (#"{"toolResultLines":"unknown"}"#, .lines(0)),
  ]
  for (json, expected) in cases {
    let ui = try JSONDecoder().decode(ConfiguredTerminalUI.self, from: Data(json.utf8))
    #expect(ui.tools == expected)
    let saved = try JSONEncoder().encode(ui)
    #expect(try JSONDecoder().decode(ConfiguredTerminalUI.self, from: saved) == ui)
    let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    #expect(object["toolResultLines"] == nil)
    if expected == .relevant || expected == .icons {
      #expect(object["tools"] as? String == expected.description)
    } else {
      #expect(object["tools"] is Int)
    }
  }
  #expect(ConfiguredTerminalUI().tools == .lines(0))
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(
      ToolResultDisplay.self, from: Data(#""unknown""#.utf8))
  }
  #expect(ToolResultDisplay(setting: "RELEVANT") == .relevant)
  #expect(ToolResultDisplay(setting: "ICONS") == .icons)
  #expect(ToolResultDisplay(setting: "0") == .lines(0))
  #expect(ToolResultDisplay(setting: "-1") == nil)
  #expect(ToolResultDisplay(setting: "unknown") == nil)
}

@Test("Relevant output expands important results and errors while preserving explicit limits")
func toolResultDisplayRelevance() {
  let body = "--- a/file.c\n+++ b/file.c\n@@ -1 +1 @@\n-old\n+new"
  let normal = ToolResult(callID: "normal", text: body)
  let important = ToolResult(callID: "important", text: body, importance: .important)
  let error = ToolResult(callID: "error", text: body, isError: true)
  let complete = "← --- a/file.c\n  +++ b/file.c\n  @@ -1 +1 @@\n  -old\n  +new"
  #expect(ToolResultPreview.render(normal, display: .relevant).hasSuffix("… 2 more lines"))
  #expect(ToolResultPreview.render(important, display: .relevant) == complete)
  #expect(ToolResultPreview.render(error, display: .relevant) == complete)
  #expect(ToolResultPreview.render(normal, display: .all) == complete)
  #expect(ToolResultPreview.render(important, display: .lines(2)).hasSuffix("… 3 more lines"))
  #expect(ToolResultPreview.render(error, display: .lines(0)) == "← error")
  #expect(ToolResultPreview.render(important, display: .lines(0)) == "← done")
}

@Test("Preview lines are clipped to the terminal width in cells")
func toolResultPreviewClipsToWidth() {
  let long = String(repeating: "x", count: 200)
  let result = ToolResult(callID: "long", text: "\(long)\nshort\n\(long)")
  let shown = ToolResultPreview.render(result, display: .lines(3), maxLineLength: 20)
  let rows = shown.components(separatedBy: "\n")
  #expect(rows.count == 3)
  #expect(rows[1] == "  short")
  for row in rows {
    #expect(ToolResultPreview.cellWidth(of: row) <= 20)
  }
  #expect(rows[0].hasSuffix("…"))
  #expect(rows[2].hasSuffix("…"))
  // Wide characters count as two cells and are never split.
  let wide = ToolResult(callID: "wide", text: String(repeating: "漢", count: 40))
  let clipped = ToolResultPreview.render(wide, display: .lines(1), maxLineLength: 11)
  #expect(ToolResultPreview.cellWidth(of: clipped) <= 11)
  #expect(clipped.hasSuffix("…"))
  #expect(!clipped.contains("\u{FFFD}"))
  // A width large enough to hold everything leaves the text alone.
  #expect(ToolResultPreview.render(result, display: .lines(1), maxLineLength: .max)
    == "← \(long)\n  … 2 more lines")
  // Complete output is never clipped, so a long line stays readable in full.
  #expect(ToolResultPreview.render(result, display: .all, maxLineLength: 20)
    == "← \(long)\n  short\n  \(long)")
  #expect(!ToolResultPreview.clipsToWidth(result, display: .all))
  #expect(ToolResultPreview.clipsToWidth(result, display: .lines(2)))
  #expect(!ToolResultPreview.clipsToWidth(result, display: .icons))
  #expect(ToolResultPreview.clipsToWidth(result, display: .relevant))
  #expect(!ToolResultPreview.clipsToWidth(
    ToolResult(callID: "important", text: long, importance: .important), display: .relevant))
}

@Test("Result importance is optional in older catalogs and transcripts and survives saving")
func toolResultImportancePersistence() throws {
  let annotations = try JSONDecoder().decode(ToolAnnotations.self, from: Data("{}".utf8))
  #expect(annotations.resultImportance == .normal)
  let important = ToolAnnotations(resultImportance: .important)
  #expect(try JSONDecoder().decode(
    ToolAnnotations.self, from: JSONEncoder().encode(important)) == important)

  let legacy = try JSONDecoder().decode(
    ToolResult.self, from: Data(#"{"callID":"old","content":[],"isError":false}"#.utf8))
  #expect(legacy.importance == .normal)
  let result = ToolResult(callID: "edit", text: "diff", importance: .important)
  #expect(try JSONDecoder().decode(
    ToolResult.self, from: JSONEncoder().encode(result)) == result)
}

@Test("File mutation definitions opt into complete relevant output")
func toolResultImportanceForFiles() {
  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: URL(fileURLWithPath: "/tmp")),
    includeLineRangeEdits: true)
  let edits: Set<MaiFileWorkspaceTool.Operation> = [
    .setFunction, .replaceRange, .patch, .mkdir, .write, .rename, .delete, .zip, .unzip,
  ]
  for tool in tools {
    #expect(tool.definition.annotations.resultImportance ==
      (edits.contains(tool.operation) ? .important : .normal))
  }
}
