import Foundation
import MaiCore

extension MaiCLI {
  enum GoalCommand {
    case status, resume, clear, start(AgentGoal)

    init(_ argument: String) throws {
      let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      switch text.lowercased() {
      case "", "status": self = .status
      case "resume": self = .resume
      case "clear": self = .clear
      default:
        var objective = text
        var iterations = 8
        if text.hasPrefix("--iterations") {
          let parts = text.split(maxSplits: 2, whereSeparator: \Character.isWhitespace)
          guard parts.count == 3, parts[0] == "--iterations", let count = Int(parts[1]),
            (1...100).contains(count) else {
            throw AgentToolError.invalidArguments(tool: "/goal", reason: "Use /goal --iterations N TASK, with N from 1 to 100.")
          }
          iterations = count
          objective = String(parts[2])
        } else if text.hasPrefix("--") {
          throw AgentToolError.invalidArguments(tool: "/goal", reason: "Unknown option. Use /help goal.")
        }
        self = .start(AgentGoal(objective: objective, maxIterations: iterations))
      }
    }
  }

  static let goalHelp = """
    /goal TASK                    Plan, delegate, review and iterate toward TASK
    /goal --iterations N TASK     Allow N reviews this run (default 8, range 1–100)
    /goal [status]               Show this chat's goal and latest review
    /goal resume                Resume the saved goal with a fresh allowance
    /goal clear                 Remove the saved goal after stopping its work

    The current agent coordinates; available agents and tools follow its existing
    permissions. Enable the agents group to allow focused workers. The coordinator
    reviews evidence and records continue, complete or blocked through goal_review.
    /set effort adjusts planning and verification depth, including worker prompts.
    Named workers keep their own model and effort; derived workers inherit yours.
    Review limits are independent of effort. Normal turn, tool, time and token limits
    still apply; an unlimited turn setting is capped at 64 for a goal run.
    /stop or Ctrl+C stops work; /goal resume continues it. Goals are saved with chats.
    Requires a chat provider with tools enabled; managed tool-loop providers are
    unsupported. The $goal research prompt remains separate.
    """
}
