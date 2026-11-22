import Foundation
import MaiCore

extension MaiCLI {
  /// `/usage`: what is left to spend, from both sources — the provider's or
  /// agent's own limits and the local ledger's tokens. `-verbose` opens the
  /// ledger for the provider, `-models` breaks it down per model.
  static func handleUsageCommand(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    process: AgentPID?,
    configuration: MaiConfiguration?,
    services: REPLServices,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \.isWhitespace).map(String.init)
    var flags = Set<String>()
    var target: String?
    for field in fields where field.hasPrefix("-") {
      flags.insert(String(field.drop { $0 == "-" }).lowercased())
    }
    for field in fields where !field.hasPrefix("-") && field != "refresh" {
      target = target ?? field
    }
    if flags.contains("help") {
      await terminal.line(usageHelp)
      return
    }
    if let unknown = flags.subtracting(["verbose", "models", "refresh"]).sorted().first {
      await terminal.line(
        "Unknown /usage flag '-\(unknown)'. Usage: /usage [-verbose] [-models] [refresh] [PROVIDER].",
        to: .standardError)
      return
    }
    let id = target ?? session.profile.provider.rawValue
    let provider = configuration?.providers.first { $0.id == id }
    if target != nil, provider == nil {
      await terminal.line(
        "Unknown provider '\(id)'. /providers lists them.", to: .standardError)
      return
    }
    if id == session.profile.provider.rawValue {
      await currentContextReport(session: session, runtime: runtime, process: process, services: services,
        warningThreshold: configuration?.ui.usageWarningPercent ?? UsageWarnings.defaultThreshold, terminal: terminal)
    }
    if flags.contains("verbose") || flags.contains("models") {
      await terminal.line(
        await providerUsageReport(
          provider: provider, models: flags.contains("models"), services: services))
      return
    }
    await terminal.line(
      await providerStatusReport(
        provider: provider, session: session, services: services,
        refresh: flags.contains("refresh") || fields.contains("refresh"),
        warningThreshold: configuration?.ui.usageWarningPercent ?? UsageWarnings.defaultThreshold))
  }

  static func currentContextReport(session: REPLSession, runtime: AgentRuntime, process: AgentPID?,
    services: REPLServices, warningThreshold: Int, terminal: TerminalWriter) async {
    var size = session.historyContextSize
    if let process, let info = await runtime.supervisor.info(process), !info.state.isTerminal {
      size = info.contextSize
    }
    let profile = session.profile
    let window = await runtime.contextWindow(provider: profile.provider, model: profile.model, options: profile.options)
    let label = promptContextStatus(session, contextSize: size, contextWindow: window)
    await terminal.line("\(profile.provider)::\(profile.model): \(label)")
    let measured = size ?? AgentContextSize(messages: session.history.messages)
    var context = measured.usage ?? ContextUsage(usedTokens: measured.estimatedTokens, isPartial: true)
    if context.windowTokens == nil { context.windowTokens = window }
    let model = services.modelCatalog.model(profile.model, provider: profile.provider)
    if let price = model?.pricing?.label { await terminal.line("Price: " + price) }
    for warning in UsageWarnings.messages(context: context, threshold: warningThreshold) {
      await terminal.line("⚠ " + warning)
    }
  }

  /// `/usage`: the limits and their resets, then what this machine spent
  /// through that provider. One line each, so the shortest answer keeps the
  /// facts a person needs to decide whether to keep going.
  static func providerStatusReport(
    provider: ConfiguredProvider?, session: REPLSession, services: REPLServices, refresh: Bool,
    now: Date = Date(), warningThreshold: Int = UsageWarnings.defaultThreshold
  ) async -> String {
    guard let provider else {
      return "No provider selected. Pick one with /model first."
    }
    let usageLine = await providerUsageLine(provider: provider, services: services)
    var limits: String
    do {
      let status = try await services.providerStatus.status(
        for: provider, model: session.profile.model, refresh: refresh, now: now)
      guard let status else { return usageLine }
      limits = status.summary(now: now, providerLabel: provider.id)
      for warning in UsageWarnings.messages(quota: status, threshold: warningThreshold, now: now) {
        limits += "\n⚠ " + warning
      }
    } catch {
      limits = "\(provider.id): \(error.localizedDescription)"
    }
    return [limits, usageLine].joined(separator: "\n")
  }

  /// The ledger line: what this machine sent and received through the
  /// provider, how many calls it took, and how big the last one was.
  static func providerUsageLine(
    provider: ConfiguredProvider, services: REPLServices
  ) async -> String {
    let rows = await services.usageStats.totals().filter { $0.providerLabel == provider.id }
    guard !rows.isEmpty else { return "local: no usage recorded yet" }
    let sums = ModelUsageSums(rows)
    let estimated = sums.estimatedCallCount > 0 ? "~" : ""
    var parts = ["\(estimated)\(ModelUsageFormat.count(sums.totalTokens)) tokens"]
    if sums.callCount > 0 { parts.append("\(ModelUsageFormat.exact(sums.callCount)) req") }
    if let last = rows.max(by: { $0.lastUsedAt < $1.lastUsedAt }) {
      parts.append("last \(ModelUsageFormat.tokens(last.totalTokens))")
    }
    return "local: " + parts.joined(separator: " · ")
  }

  /// `/usage -verbose` and `/usage -models`: the durable ledger one provider
  /// collected — whole, or per model. `/stats` ranks the same rows.
  static func providerUsageReport(
    provider: ConfiguredProvider?, models: Bool, services: REPLServices
  ) async -> String {
    let rows = await services.usageStats.totals()
    let selected = provider.map { id in rows.filter { $0.providerLabel == id.id } } ?? rows
    let label = provider?.id
    guard !selected.isEmpty else {
      return label.map { "No model usage recorded for \($0)." } ?? "No model usage recorded yet."
    }
    let sorted = selected.sorted { $0.totalTokens > $1.totalTokens }
    guard models else {
      return "\(label.map { "\($0) usage" } ?? "Usage") (all time)\n"
        + ModelUsageSums(sorted).summaryParts.joined(separator: " · ")
    }
    let lines = sorted.prefix(12).map { row in
      let tokens = ModelUsageFormat.tokens(row.totalTokens, estimated: row.estimatedCallCount > 0)
      let speed = row.averageTokensPerSecond.map(ModelUsageFormat.speed) ?? "—"
      return "- \(row.title): \(tokens) · \(row.callCount) req · \(speed)"
    }
    return (["\(label.map { "\($0) usage by model" } ?? "Usage by model") (all time)"] + lines)
      .joined(separator: "\n")
  }
}
