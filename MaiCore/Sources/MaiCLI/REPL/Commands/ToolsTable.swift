import Foundation
import MaiCore
import MaiMarkdown

extension MaiCLI {
  static func toolGroupsTable(
    _ groups: [ToolGroupDefinition], modes: [String: AgentToolMode], usage: AgentToolUsage
  ) -> MarkdownTable {
    MarkdownTable(
      headers: ["Group", "Status", "Direct", "Proxy", "Hidden", "Disabled", "Calls", "Description"],
      alignments: [.leading, .leading] + Array(repeating: .trailing, count: 5) + [.leading],
      rows: groups.map { group in
        let summary = AgentToolModeSummary(names: group.toolNames, modes: modes)
        let status = summary.enabled == 0 ? "○ disabled"
          : summary.disabled > 0 ? "◐ mixed"
          : summary.hidden == summary.total ? "◐ hidden" : "● enabled"
        return [
          "**\(toolTableText(group.sourceID == "mcp" ? group.catalogID : group.id))**",
          status, String(summary.direct), String(summary.proxy), String(summary.hidden),
          String(summary.disabled), String(usage.count(for: group)), toolTableText(group.displayName),
        ]
      })
  }

  static func toolDetailsTable(
    _ group: ToolGroupDefinition, modes: [String: AgentToolMode], usage: AgentToolUsage
  ) -> MarkdownTable {
    MarkdownTable(
      headers: ["Tool", "Mode", "Calls"], alignments: [.leading, .leading, .trailing],
      rows: group.toolNames.sorted().map { name in
        ["\(ToolIcon.emoji(for: name)) **\(toolTableText(name))**",
         modes[name, default: .disabled].rawValue, String(usage.counts[name, default: 0])]
      })
  }

  /// Catalog labels are literal text, even when plugins use Markdown characters.
  private static func toolTableText(_ text: String) -> String {
    text.map { character in
      if character.isNewline { return " " }
      if "\\`*_[]<>&|".contains(character), let ascii = character.asciiValue {
        return "&#\(ascii);"
      }
      return String(character)
    }.joined()
  }
}
