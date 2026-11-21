import Foundation

public enum UsageWarnings {
  public static let defaultThreshold = 80

  public static func messages(
    context: ContextUsage? = nil, quota: MaiProviderStatus? = nil,
    threshold: Int = defaultThreshold, now: Date = Date()
  ) -> [String] {
    guard (1...100).contains(threshold) else { return [] }
    var warnings: [String] = []
    if let context, !context.isPartial, let window = context.windowTokens, window > 0 {
      let used = Double(context.usedTokens) / Double(window) * 100
      if used >= Double(threshold) {
        warnings.append(
          "Context \(context.isEstimated ? "~" : "")\(String(format: "%.0f", used))% full")
      }
    }
    for (name, limit) in quota?.limits.sorted(by: { $0.key < $1.key }) ?? [] {
      guard limit.resetsAt.map({ $0 > now }) ?? true else { continue }
      let used = 100 - limit.remainingPercent
      if used.isFinite, used >= Double(threshold) {
        warnings.append("\(name) quota \(String(format: "%.0f", min(100, used)))% used")
      }
    }
    for balance in quota?.balances ?? [] {
      if case .credits(let remaining, let allowance, let resetsAt) = balance,
        allowance.isFinite, allowance > 0, remaining.isFinite,
        resetsAt.map({ $0 > now }) ?? true
      {
        let used = (1 - remaining / allowance) * 100
        if used >= Double(threshold) {
          warnings.append("Credits \(String(format: "%.0f", min(100, used)))% used")
        }
      }
    }
    return warnings
  }
}
