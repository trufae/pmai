import Foundation
import Testing

@testable import MaiCore

@Test("Tool timing survives text storage without changing tool output or visible prose")
func toolRunTimingRoundTrip() throws {
  let timing = ToolRunTiming(
    startedAt: Date(timeIntervalSince1970: 100), finishedAt: Date(timeIntervalSince1970: 112))
  let block = AgentTooling.makeRunBlock(
    toolName: "read", argumentsJSON: "{}", result: "contents", timing: timing)
  let rendered = MessageContentFilter.render("Before\n\(block)\nAfter")
  let section = try #require(rendered.hiddenSections.first)
  #expect(section.toolTiming == timing)
  #expect(section.content == "read tool ({}):\ncontents")
  #expect(rendered.visibleText == "Before\n\nAfter")
  let removed = MessageContentFilter.removingHiddenSection(
    tag: section.tag, content: section.content, occurrence: 0, from: block)
  #expect(removed?.trimmingCharacters(in: .whitespacesAndNewlines) == "")
  let legacy = AgentTooling.makeRunBlock(toolName: "read", argumentsJSON: "{}", result: "contents")
  #expect(MessageContentFilter.render(legacy).hiddenSections.first?.toolTiming == nil)
}

@Test("Group elapsed time uses wall-clock bounds rather than summing parallel calls")
func toolGroupElapsedTime() {
  func timing(_ start: Double, _ end: Double?) -> ToolRunTiming {
    ToolRunTiming(
      startedAt: Date(timeIntervalSince1970: start),
      finishedAt: end.map { Date(timeIntervalSince1970: $0) })
  }
  #expect(ToolRunTiming.summary([timing(100, 110), timing(102, 108)]) == "2 tool calls · 10s")
  #expect(ToolRunTiming.summary([timing(100, 110), timing(115, 120)]) == "2 tool calls · 20s")
  #expect(ToolRunTiming.summary(
    [timing(100, 110), timing(102, nil)], now: Date(timeIntervalSince1970: 125))
    == "2 tool calls · 25s · running")
  #expect(ToolRunTiming.summary([nil, timing(100, 110)]) == "2 tool calls · time unavailable")
  for attributes in [
    "", " data-start=\"nan\"", " data-start=\"inf\"", " data-start=\"-1\"",
    " data-start=\"1e99\"", " data-start=\"20\" data-end=\"nan\"", " data-start=\"20\" data-end=\"10\"",
  ] {
    #expect(ToolRunTiming(openingTag: Substring("<tool_run\(attributes)>")) == nil)
  }
}

@Test("Tool grouping config is opt-in and persists")
func toolGroupingConfiguration() throws {
  #expect(try JSONDecoder().decode(ConfiguredTerminalUI.self, from: Data("{}".utf8)).toolGroups == false)
  var ui = ConfiguredTerminalUI()
  ui.toolGroups = true
  #expect(try JSONDecoder().decode(
    ConfiguredTerminalUI.self, from: JSONEncoder().encode(ui)).toolGroups)
}
