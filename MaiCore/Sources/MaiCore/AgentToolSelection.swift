import Foundation

/// The same selector grammar is used for native tools, skills, and MCP tools.
public enum AgentToolSelection: Equatable, Sendable {
  case tool(String)
  case group(ToolGroupDefinition)

  public static func group(named selector: String, in groups: [ToolGroupDefinition])
    -> ToolGroupDefinition?
  {
    if selector.lowercased() == "mcp" {
      return ToolGroupDefinition(
        id: "mcp", displayName: "All MCP servers",
        toolNames: Set(groups.filter { $0.sourceID == "mcp" }.flatMap(\.toolNames)))
    }
    let qualified = groups.filter { $0.catalogID.caseInsensitiveCompare(selector) == .orderedSame }
    if qualified.count == 1 { return qualified[0] }
    let matches = groups.filter {
      $0.sourceID != "mcp" && $0.id.caseInsensitiveCompare(selector) == .orderedSame
    }
    return matches.count == 1 ? matches[0] : nil
  }

  public static func resolve(_ selector: String, groups: [ToolGroupDefinition], names: Set<String>)
    -> AgentToolSelection?
  {
    if selector.hasPrefix("group:") {
      return group(named: String(selector.dropFirst(6)), in: groups).map(Self.group)
    }
    if !selector.hasPrefix("tool:"), let group = group(named: selector, in: groups) {
      return .group(group)
    }
    let name = selector.hasPrefix("tool:") ? String(selector.dropFirst(5)) : selector
    let matches = names.filter { $0.caseInsensitiveCompare(name) == .orderedSame }
    if matches.count == 1 { return .tool(matches.first!) }
    // github/pr, skills/review, and mcp/SERVER/analyze are convenient aliases;
    // exact qualified names still work when a source uses a custom prefix.
    if let slash = name.lastIndex(of: "/"),
      let group = group(named: String(name[..<slash]), in: groups)
    {
      let member = String(name[name.index(after: slash)...])
      let matches = group.toolNames.filter {
        $0.caseInsensitiveCompare(member) == .orderedSame
          || $0.caseInsensitiveCompare(group.id + "_" + member) == .orderedSame
          || $0.components(separatedBy: "::").last?.caseInsensitiveCompare(member) == .orderedSame
      }
      if matches.count == 1 { return .tool(matches.first!) }
    }
    return nil
  }
}
