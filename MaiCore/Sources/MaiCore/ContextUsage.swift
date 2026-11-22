import Foundation

/// Occupancy of one model context, never cumulative spending across calls.
public struct ContextUsage: Codable, Equatable, Sendable {
  public var usedTokens: Int
  public var windowTokens: Int?
  public var isEstimated: Bool
  public var isPartial: Bool

  public init(
    usedTokens: Int, windowTokens: Int? = nil, isEstimated: Bool = true, isPartial: Bool = false
  ) {
    self.usedTokens = max(0, usedTokens)
    self.windowTokens = Self.effectiveWindow(windowTokens)
    self.isEstimated = isEstimated
    self.isPartial = isPartial
  }

  /// A user cap can lower a known window, but cannot enlarge it.
  public static func effectiveWindow(_ limits: Int?...) -> Int? {
    limits.compactMap { $0 }.filter { $0 > 0 }.min()
  }

  public var label: String {
    let used =
      (isEstimated ? "~" : "") + ModelUsageFormat.count(usedTokens) + (isPartial ? "+" : "")
    guard let windowTokens, windowTokens > 0 else { return "ctx \(used)" }
    if isPartial { return "ctx \(used)/\(ModelUsageFormat.count(windowTokens))" }
    let percent = String(format: "%.0f", Double(usedTokens) / Double(windowTokens) * 100)
    return "ctx \(used)/\(ModelUsageFormat.count(windowTokens)) (\(percent)%)"
  }

  /// A short title label; detailed estimate markers remain in `label`.
  public var compactLabel: String {
    let used = ModelUsageFormat.count(usedTokens).replacingOccurrences(of: ".0", with: "")
    guard let windowTokens, windowTokens > 0 else { return "ctx \(used)" }
    let window = ModelUsageFormat.count(windowTokens).replacingOccurrences(of: ".0", with: "")
    return "ctx \(used)/\(window)"
  }

  /// ACP usage_update describes occupancy, not billable input/output usage.
  public init?(acpUpdate: JSONValue) {
    guard let fields = acpUpdate.objectValue,
      fields["sessionUpdate"]?.stringValue == "usage_update",
      let used = fields["used"]?.intValue, used >= 0,
      let size = fields["size"]?.intValue, size >= 0
    else { return nil }
    let estimated =
      fields["_meta"]?.objectValue?["pmai"]?.objectValue?["estimated"]?.boolValue ?? false
    self.init(usedTokens: used, windowTokens: size, isEstimated: estimated)
  }
}
