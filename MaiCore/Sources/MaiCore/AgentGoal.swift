import Foundation

/// A chat's objective and its latest coordinator review. Execution remains in
/// the normal runtime, so goals share approvals, cancellation and run limits.
public struct AgentGoal: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case active, complete, blocked, paused
  }

  public var objective: String
  public var status: Status = .active
  /// Reviews allowed per invocation, independent of reasoning effort.
  public var maxIterations: Int
  public var iterations: Int = 0
  public var summary: String = ""
  public var evidence: String = ""
  public var nextStep: String = ""

  public init(objective: String, maxIterations: Int = 8) {
    self.objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    self.maxIterations = max(1, min(100, maxIterations))
  }

  public var isActive: Bool { status == .active }

  public var report: String {
    var lines = ["Goal: \(status.rawValue) · \(iterations) reviews", objective]
    if !summary.isEmpty { lines.append(summary) }
    if !evidence.isEmpty { lines.append("Evidence: \(evidence)") }
    if !nextStep.isEmpty { lines.append("Next: \(nextStep)") }
    return lines.joined(separator: "\n")
  }
}

public enum AgentGoalPrompt {
  public static func coordinator(_ goal: AgentGoal, effort: String?) -> String {
    """
    You own this goal: \(goal.objective)
    Define concrete acceptance criteria from the user's request, inspect what is relevant, then execute a short plan. Delegate self-contained work with agent_start when it helps; give each worker the necessary context, a precise task, constraints, and expected evidence. Run independent tasks together. Assign separate files to concurrent writers. Handle small tasks yourself. Keep ownership of integration and final verification.
    After each meaningful batch, collect the worker results, inspect the relevant artifacts and verify them against the acceptance criteria. A worker's success claim is evidence to check, not proof. Revise the plan and fix gaps. Do not spawn agents merely to fill slots or repeat work that produced no new evidence.
    Call goal_review by itself after reviewing a batch, and before your final answer. Use continue with the specific next step when work remains; complete only when the acceptance criteria are met and verified; blocked only when a concrete missing input, permission or external dependency prevents further useful work. State what would unblock it. Tool failures alone do not establish a blocker. Do not use a final prose reply to abandon unfinished work.
    \(depthGuidance(effort, reviewing: true))
    Keep progress and handoffs concise. Report results, evidence, gaps and next actions; do not expose private deliberation. Honor new user steering and all existing permissions and limits.
    Reviews so far: \(goal.iterations). Latest review: \(goal.summary)
    Evidence: \(goal.evidence)
    Next step: \(goal.nextStep)
    """
  }

  public static func worker(effort: String?) -> String {
    """
    This brief contributes to a goal owned by your parent. Complete only the assigned task. Respect its scope and file ownership; leave integration and overall completion to the parent. Prefer direct tool use over further delegation.
    \(depthGuidance(effort, reviewing: false))
    Return a concise result, changed files or source locations, verification performed and its outcome, and any unresolved gap or blocker. Never claim a check passed unless you ran it or have its output. Follow the requested output format without preamble or progress narration.
    """
  }

  private static func depthGuidance(_ value: String?, reviewing: Bool) -> String {
    switch value.flatMap(ReasoningEffort.init(name:)) ?? .automatic {
    case .disabled, .minimal, .low:
      return reviewing
        ? "Use a short plan and the smallest useful task split. Check the direct acceptance criteria and decisive evidence; expand investigation only for ambiguity or costly mistakes."
        : "Take the direct path. Inspect only what the task needs and run the smallest meaningful verification."
    case .automatic, .medium:
      return reviewing
        ? "Keep planning proportionate. Check assumptions, integration and the main failure cases before accepting results."
        : "Check the main assumptions and relevant failure cases. Verify the observable result."
    case .high, .xhigh, .max:
      return reviewing
        ? "Examine risky assumptions, dependencies and failure cases. Seek independent verification for consequential or uncertain results, then resolve discrepancies. Stop reviewing once the criteria are supported by evidence."
        : "Investigate relevant edge cases and competing explanations. Verify consequential assumptions with tools and report remaining uncertainty. Keep the final output concise."
    }
  }
}
