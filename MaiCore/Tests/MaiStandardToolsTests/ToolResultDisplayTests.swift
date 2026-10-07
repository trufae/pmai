import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

@Test("Tool result display loads legacy counts and persists relevant mode")
func toolResultDisplayConfiguration() throws {
  let cases: [(String, ToolResultDisplay)] = [
    ("{}", .all),
    (#"{"toolResultLines":-1}"#, .all),
    (#"{"toolResultLines":-20}"#, .all),
    (#"{"toolResultLines":0}"#, .lines(0)),
    (#"{"toolResultLines":7}"#, .lines(7)),
    (#"{"toolResultLines":"all"}"#, .all),
    (#"{"toolResultLines":"relevant"}"#, .relevant),
  ]
  for (json, expected) in cases {
    let ui = try JSONDecoder().decode(ConfiguredTerminalUI.self, from: Data(json.utf8))
    #expect(ui.toolResultLines == expected)
    let saved = try JSONEncoder().encode(ui)
    #expect(try JSONDecoder().decode(ConfiguredTerminalUI.self, from: saved) == ui)
    let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    if expected == .relevant {
      #expect(object["toolResultLines"] as? String == "relevant")
    } else {
      #expect(object["toolResultLines"] is Int)
    }
  }
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(
      ConfiguredTerminalUI.self, from: Data(#"{"toolResultLines":"unknown"}"#.utf8))
  }
  #expect(ToolResultDisplay(setting: "RELEVANT") == .relevant)
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
    configuration: MaiFileWorkspaceConfiguration(rootURL: URL(fileURLWithPath: "/tmp")))
  let edits: Set<MaiFileWorkspaceTool.Operation> = [
    .setFunction, .replaceRange, .patch, .write, .rename, .delete,
  ]
  for tool in tools {
    #expect(tool.definition.annotations.resultImportance ==
      (edits.contains(tool.operation) ? .important : .normal))
  }
}
