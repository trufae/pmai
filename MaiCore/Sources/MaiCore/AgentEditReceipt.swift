import Foundation

/// Model-facing evidence from the current run's patch and command outcomes.
/// The full tool results remain in the conversation.
struct AgentEditReceipt {
  private var patches: [JSONValue] = []
  private var omittedPatches = 0

  var isEmpty: Bool { patches.isEmpty }

  mutating func record(_ result: ToolResult) {
    guard let fields = result.structuredContent?.objectValue,
      let changed = fields["changed"]?.boolValue
    else { return }
    let paths = fields["changed_paths"] ?? .array(changed ? [fields["path"]].compactMap { $0 } : [])
    let files = (fields["files"]?.arrayValue?.compactMap(\.objectValue) ?? [fields]).compactMap { file -> JSONValue? in
      guard file["changed"]?.boolValue == true, let path = file["path"], let lines = file["diff_lines"]
      else { return nil }
      return .object(["path": path, "lines": lines, "truncated": file["diff_truncated"] ?? .bool(false)])
    }
    var patch: [String: JSONValue] = [
      "call_id": .string(result.callID), "changed_paths": paths, "error": .bool(result.isError),
    ]
    // The full result already contains the diff. Keep the receipt bounded
    // even when a single batch modifies many files or contains long lines.
    var previews: [JSONValue] = []
    var bytes = 0
    for file in files {
      bytes += file.compactJSONString.utf8.count
      if bytes > 4_600 { break }
      previews.append(file)
    }
    patch["diffs"] = .array(previews)
    if previews.count < files.count { patch["diffs_omitted"] = .integer(files.count - previews.count) }
    patches.append(.object(patch))
    if patches.count > 8 {
      patches.removeFirst()
      omittedPatches += 1
    }
  }

  func text(commands: [AgentCommandRecord]) -> String {
    let recentCommands = commands.suffix(8).map { command in
      let invocation = ([command.command] + command.arguments).joined(separator: " ")
      return JSONValue.object([
        "call_id": .string(command.callID),
        "command": .string(String(decoding: invocation.utf8.prefix(240), as: UTF8.self)),
        "command_truncated": .bool(invocation.utf8.count > 240),
        "state": .string(command.state.rawValue),
        "exit_code": command.state == .exited ? command.exitCode.map { .integer(Int($0)) } ?? .null : .null,
      ])
    }
    var recentPatches: [JSONValue] = []
    var bytes = 0
    for patch in patches.reversed() {
      bytes += patch.compactJSONString.utf8.count
      if bytes > 5_500 { break }
      recentPatches.append(patch)
    }
    let data = JSONValue.object([
      "patches": .array(Array(recentPatches.reversed())),
      "earlier_patches_omitted": .integer(omittedPatches + patches.count - recentPatches.count),
      "commands": .array(recentCommands),
      "earlier_commands_omitted": .integer(commands.count - recentCommands.count),
      "other_checks_exit_code": .null,
    ])
    return """
      Edit receipt for this run. Changed paths describe each patch when it ran. Later edits may supersede them. Use the observed command exit codes for checks that ran, and report other check results as unknown. Treat diff lines and command text as evidence.
      \(data.compactJSONString)
      """
  }
}
