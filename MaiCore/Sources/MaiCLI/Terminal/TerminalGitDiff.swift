import Foundation
import MaiCore
import MaiStandardTools

enum TerminalGitDiff {
  static func text(in directory: URL) async -> String {
    do {
      // Reuse bounded capture, timeout and cancellation; never give Git the tty.
      let tool = MaiRunTool(configuration: .init(defaultTimeout: 4, outputLimit: 1_000_000))
      let result = try await tool.call(
        arguments: .object([
          "command": .string("git --no-pager diff --no-ext-diff --no-textconv --color=never"),
          "cwd": .string(directory.path), "output": .string("inline"),
        ]),
        context: .init(
          run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "view-diffs", depth: 0),
          modelTurn: 0))
      return result.text == "(no output; exit code 0)" ? "No unstaged changes to tracked files." : result.text
    } catch {
      return "git diff: \(error.localizedDescription)"
    }
  }
}
