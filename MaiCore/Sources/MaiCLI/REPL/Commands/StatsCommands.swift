import Foundation
import MaiCore

extension MaiCLI {
  /// `/stats`: the usage ledger the runtime fills after every model call,
  /// printed as one colored bar per provider:model for the combined ranking,
  /// speed, time in use, and efficiency. `/stats METRIC` shows one ranking; `/stats show TARGET`
  /// every fact recorded about a model or a provider.
  static func handleStatsCommand(
    _ argument: String,
    store: ModelUsageStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let target = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
    func printReport(_ metrics: [ModelUsageReport.Metric]) async {
      let report = ModelUsageReport(await store.ledger)
      let colors = await terminal.paintsOutput
      // Headings in the cyan of `✓ took`, label and bar in the provider's
      // palette color, the number bold, the rest dim.
      let lines = report.lines(width: TerminalLineEditor.terminalColumns(), metrics: metrics) {
        text, style in
        guard colors else { return text }
        let code: String
        switch style {
        case .heading: code = "1;36"
        case .headline: code = "36"
        case .label(let color), .bar(let color):
          guard let colorCode = TerminalLineEditor.foregroundColorCode(color.hex) else {
            return text
          }
          code = colorCode
        case .value: code = "1"
        case .detail, .note: code = "2"
        }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
      }
      await terminal.line(lines.joined(separator: "\n"))
      if let error = await store.lastPersistenceError {
        await terminal.line(
          "warning: statistics could not be saved: \(error)", to: .standardError)
      }
    }
    if let metric = ModelUsageReport.Metric.named(action) {
      await printReport([metric])
      return
    }
    switch action {
    case "", "list":
      await printReport(ModelUsageReport.Metric.displayCases)
    case "show":
      guard !target.isEmpty else {
        await printReport(ModelUsageReport.Metric.displayCases)
        return
      }
      let rows = await store.ledger.totals(matching: target)
      guard !rows.isEmpty else {
        await terminal.line(noStatisticsMessage(for: target))
        return
      }
      await terminal.line(
        rows.map { row in
          ([row.title] + row.detailLines.map { "  " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n"))
    case "reset", "clear":
      await store.reset()
      await terminal.line("Usage statistics reset.")
    case "del":
      guard !target.isEmpty else {
        await terminal.line("Usage: /stats del PROVIDER[:MODEL]")
        return
      }
      switch await store.remove(matching: target) {
      case 0: await terminal.line(noStatisticsMessage(for: target))
      case 1: await terminal.line("Removed the statistics of '\(target)'.")
      case let count:
        await terminal.line(
          "Removed the statistics of \(count) models of provider '\(target)'.")
      }
    case "path":
      await terminal.line(
        await store.location?.path ?? "Statistics are kept in memory for this session only.")
    case "help":
      await terminal.line(statsHelp)
    default:
      await terminal.line("Unknown /stats action '\(action)'.\n" + statsHelp)
    }
  }

  private static func noStatisticsMessage(for target: String) -> String {
    "No statistics for '\(target)'. /stats lists the provider:model pairs."
  }
}
