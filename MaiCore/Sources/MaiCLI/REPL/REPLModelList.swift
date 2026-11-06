import Foundation
import MaiCore

struct REPLModelListOptions {
  var provider: ProviderID
  var filter = ModelCatalogFilter()
  static let usage = """
    /models [PROVIDER] [SEARCH] [--tools] [--vision] [--reasoning] [--decision] [--voice] [--context 128K]
    Lists models alphabetically with provider-reported features and context sizes.
    Filters combine; unknown capabilities do not match. Every listing refreshes the catalog.
    Examples: /models ollama --tools llama   /models --voice   /models --context 128K
    """

  init(_ argument: String, current: ProviderID, providers: Set<ProviderID>) throws {
    provider = current
    var words = argument.split(whereSeparator: \.isWhitespace).map(String.init)
    if let first = words.first, providers.contains(ProviderID(first)) {
      provider = ProviderID(words.removeFirst())
    }
    var search: [String] = []
    var index = 0
    while index < words.count {
      let word = words[index]
      if word == "--context" {
        index += 1
        guard index < words.count, let size = Self.contextSize(words[index]) else {
          throw Invalid(message: "Use --context with a positive token count, such as 32K or 128K.")
        }
        filter.minimumContextWindow = size
      } else if word == "--refresh" {
        // Explicit for discoverability; /models always performs a fresh listing.
      } else if word.hasPrefix("--"), let feature = ModelFeature(rawValue: String(word.dropFirst(2))) {
        filter.features.insert(feature)
      } else if word.hasPrefix("-") {
        throw Invalid(message: "Unknown model filter '\(word)'.\n\(Self.usage)")
      } else {
        search.append(word)
      }
      index += 1
    }
    filter.search = search.joined(separator: " ")
  }

  private static func contextSize(_ value: String) -> Int? {
    let value = value.lowercased()
    let multiplier = value.hasSuffix("m") ? 1_048_576 : (value.hasSuffix("k") ? 1024 : 1)
    let digits = multiplier == 1 ? value : String(value.dropLast())
    guard let count = Int(digits), count > 0 else { return nil }
    let (size, overflow) = count.multipliedReportingOverflow(by: multiplier)
    return overflow ? nil : size
  }

  struct Invalid: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
}

extension TerminalWriter {
  func modelCatalogRow(_ model: ModelDescriptor, selected: Bool) -> String {
    let colors: [ModelFeature: String] = [
      .tools: "blue", .vision: "magenta", .reasoning: "yellow", .decision: "magenta", .voice: "cyan",
    ]
    var badges = model.features.map { paint("[\($0.title)]", color: colors[$0]) }
    if let context = model.contextLabel { badges.append(paint("[\(context)]", color: "green")) }
    if badges.isEmpty { badges.append(paint("[Features unknown]", role: .infoForeground)) }
    let name = model.displayName == model.id ? model.id : "\(model.id) (\(model.displayName))"
    let owner = model.ownedBy.map { " — \($0)" } ?? ""
    return "\(selected ? "*" : " ") \(paint(name + owner, bold: selected))  \(badges.joined(separator: " "))"
  }
}
