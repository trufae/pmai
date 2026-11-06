import Foundation
import MaiCore

/// The command and live pane share a width-aware snapshot. Clip plain cells
/// before styling so wide characters and theme annotations never shift columns.
enum TerminalJobs {
  static func render(
    _ processes: [AgentProcessInfo], width: Int, at now: Date = Date(),
    includeArchived: Bool = false,
    paint: (String, TerminalThemeStyle, Bool) -> String = { text, _, _ in text }
  ) -> String {
    let tree = AgentProcessTree(processes.filter { includeArchived || !$0.isArchived })
    guard !tree.isEmpty else { return "No jobs recorded." }
    let width = max(1, width)
    func compact(_ text: String) -> String {
      text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
        .map(String.init).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    func clip(_ text: String, _ size: Int) -> String {
      let safe = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        .map(String.init).joined()
      return TerminalToolBlock.truncatedCall(safe, width: max(0, size))
    }
    func cell(_ text: String, _ size: Int, right: Bool = false) -> String {
      let value = clip(text, size)
      let padding = String(repeating: " ", count: max(0, size - TerminalLineEditor.displayWidth(of: value)))
      return right ? padding + value : value + padding
    }
    func role(_ state: AgentProcessState) -> TerminalThemeStyle {
      switch state {
      case .starting, .running: .infoForeground
      case .completed: .successForeground
      case .failed, .blocked: .errorForeground
      case .queued, .paused, .waitingForApproval, .waitingForInput, .cancelled, .interrupted:
        .warningForeground
      }
    }
    var ordered: [AgentProcessInfo] = []
    let prefixes = tree.lines { process in
      ordered.append(process)
      return ""
    }
    let names = zip(prefixes, ordered).map { prefix, process in
      prefix + process.pid.description + " " + compact(process.displayName)
        + (process.externalSessionID == nil ? "" : " (ACP)")
    }
    let active = ordered.filter { !$0.state.isTerminal && !$0.state.isWaiting && $0.state != .queued }.count
    let waiting = ordered.filter { $0.state.isWaiting || $0.state == .queued }.count
    let finished = ordered.filter { $0.state.isTerminal }.count
    var lines = [paint(clip("Jobs: \(active) active · \(waiting) waiting · \(finished) finished", width), .infoForeground, true)]
    let table = width >= 76
    let longestName = names.map { TerminalLineEditor.displayWidth(of: $0) }.max() ?? 0
    let nameWidth = min(40, max(16, width / 4), max(16, longestName))
    // Six two-space gutters separate the fixed columns from the detail column.
    let detailWidth = width - nameWidth - 8 - 6 - 5 - 5 - 9 - 12
    if table {
      let header = [
        cell("JOB", nameWidth), cell("STATE", 8), cell("TIME", 6, right: true),
        cell("TURNS", 5, right: true), cell("TOOLS", 5, right: true),
        cell("TOKENS", 9, right: true), "TASK / ACTIVITY",
      ].joined(separator: "  ")
      lines.append(paint(clip(header, width), .infoForeground, true))
    }
    for (name, process) in zip(names, ordered) {
      let elapsed = ModelUsageFormat.duration(process.elapsedSeconds(at: now))
      let tokens = (process.usage?.isEstimated == true ? "~" : "")
        + ModelUsageFormat.count(process.usage?.totalTokens ?? 0)
      var details: [String] = []
      if process.queuedMessages > 0 { details.append("\(process.queuedMessages) queued") }
      if process.pauseRequested && process.state != .paused { details.append("pausing") }
      // Human attention comes first so a long title cannot hide a blocked job.
      let attention = process.attention?.summary ?? process.failure
      if let attention, !attention.isEmpty { details.insert(attention, at: 0) }
      if !process.task.isEmpty && compact(process.task) != compact(process.displayName) {
        details.append(process.task)
      }
      if attention == nil && !process.activity.isEmpty && process.activity != process.task {
        details.append(process.activity)
      }
      if process.displayName != process.agentID { details.append(process.agentID) }
      if let model = process.model {
        details.append(model + (process.reasoningEffort.map { " [\($0)]" } ?? ""))
      }
      let detail = details.map(compact).joined(separator: " · ")
      if table {
        let cells = [
          paint(cell(name, nameWidth), .foreground, true),
          paint(cell(process.state.shortLabel, 8), role(process.state), true),
          cell(elapsed, 6, right: true), cell(String(process.modelTurns), 5, right: true),
          cell(String(process.toolCalls), 5, right: true),
          paint(cell(tokens, 9, right: true), .infoForeground, false),
          paint(clip(detail, detailWidth), attention == nil ? .foreground : role(process.state), false),
        ]
        lines.append(cells.joined(separator: "  "))
      } else {
        let badge = "[\(process.state.shortLabel)] \(elapsed)"
        let available = width - TerminalLineEditor.displayWidth(of: badge) - 2
        lines.append(paint(clip(name, available), .foreground, true) + (available > 0 ? "  " : "")
          + paint(clip(badge, available > 0 ? width - max(0, available) - 2 : width), role(process.state), true))
        let usage = "\(process.modelTurns) turns · \(process.toolCalls) tools · \(tokens) tok"
        lines.append(paint(clip("  " + usage + (detail.isEmpty ? "" : " · " + detail), width), .foreground, false))
      }
    }
    lines.append(paint(clip(MaiCLI.jobTreeTotal(tree), width), .infoForeground, true))
    return lines.joined(separator: "\n")
  }
}

extension TerminalWriter {
  func renderJobs(
    _ processes: [AgentProcessInfo], width: Int? = nil, includeArchived: Bool = false
  ) -> String {
    TerminalJobs.render(processes, width: width ?? outputColumns, includeArchived: includeArchived) {
      paint($0, role: $1, bold: $2)
    }
  }
}
