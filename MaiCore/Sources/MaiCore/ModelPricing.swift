import Foundation

/// Catalog list prices in USD; not an invoice or an account's negotiated rate.
public struct ModelPricing: Codable, Equatable, Sendable {
  public var inputPerMillion: Double?
  public var outputPerMillion: Double?
  public var cachedInputPerMillion: Double?
  public var request: Double?
  public var hasTiers: Bool
  public var configured: Bool

  /// OpenRouter-compatible catalogs publish USD per token (strings or numbers).
  /// Negative/dynamic prices and malformed fields remain unknown, never free.
  public init?(catalog value: JSONValue, configured: Bool = false) {
    guard let fields = value.objectValue,
      fields["currency"]?.stringValue.map({ $0.uppercased() == "USD" }) ?? true else { return nil }
    func price(_ key: String, scale: Double = 1_000_000) -> Double? {
      let value: Double?
      switch fields[key] {
      case .string(let text): value = Double(text)
      case .integer(let number): value = Double(number)
      case .number(let number): value = number
      default: value = nil
      }
      guard let value, value.isFinite, value >= 0, (value * scale).isFinite else { return nil }
      return value * scale
    }
    inputPerMillion = price("prompt")
    outputPerMillion = price("completion")
    cachedInputPerMillion = price("input_cache_read")
    request = price("request", scale: 1)
    hasTiers = !(fields["overrides"]?.arrayValue?.isEmpty ?? true)
    self.configured = configured
    guard inputPerMillion != nil || outputPerMillion != nil || cachedInputPerMillion != nil || request != nil else { return nil }
  }

  public var label: String {
    func money(_ value: Double?) -> String { value.map { "$" + String(format: "%.6g", $0) } ?? "?" }
    var text = "in \(money(inputPerMillion)) · out \(money(outputPerMillion)) /1M tok"
    if let cachedInputPerMillion { text += " · cache \(money(cachedInputPerMillion))/1M" }
    if let request, request != 0 { text += " · \(money(request))/req" }
    if hasTiers { text += " · base rate; tiers vary" }
    if configured { text += " · configured" }
    return text
  }
}
