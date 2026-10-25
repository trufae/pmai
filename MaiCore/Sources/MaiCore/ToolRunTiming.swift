import Foundation

/// Wall-clock bounds, so overlapping calls are counted once in group summaries.
public struct ToolRunTiming: Equatable, Sendable {
  public var startedAt: Date
  public var finishedAt: Date?

  public init(startedAt: Date = Date(), finishedAt: Date? = nil) {
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  public var attributes: String {
    let end = finishedAt.map { " data-end=\"\($0.timeIntervalSince1970)\"" } ?? ""
    return " data-start=\"\(startedAt.timeIntervalSince1970)\"" + end
  }

  public init?(openingTag: Substring) {
    func date(_ name: String) -> Date? {
      guard let range = openingTag.range(of: " \(name)=\""),
        let end = openingTag[range.upperBound...].firstIndex(of: "\""),
        let value = Double(openingTag[range.upperBound..<end]), value.isFinite, value >= 0,
        value < 253_402_300_800
      else { return nil }
      return Date(timeIntervalSince1970: value)
    }
    guard let start = date("data-start") else { return nil }
    let end = date("data-end")
    if openingTag.contains(" data-end="), end == nil { return nil }
    guard end == nil || end! >= start else { return nil }
    self.init(startedAt: start, finishedAt: end)
  }

  public static func summary(_ timings: [ToolRunTiming?], now: Date = Date()) -> String {
    let label = "\(timings.count) tool calls"
    let known = timings.compactMap { $0 }
    guard known.count == timings.count, let start = known.map(\.startedAt).min(),
      let end = known.map({ $0.finishedAt ?? now }).max()
    else { return label + " · time unavailable" }
    let running = known.contains { $0.finishedAt == nil }
    return label + " · " + ModelUsageFormat.duration(max(0, end.timeIntervalSince(start)))
      + (running ? " · running" : "")
  }
}
