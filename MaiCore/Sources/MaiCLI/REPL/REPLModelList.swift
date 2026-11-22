import Foundation
import MaiCore
import MaiMarkdown

struct REPLModelListOptions {
  var provider: ProviderID
  var filter = ModelCatalogFilter()
  static let usage = """
    /models [PROVIDER] [SEARCH] [--tools] [--vision] [--reasoning] [--decision] [--voice] [--context 128K] [--sort name|input|output]
    Lists model features, context sizes and published USD input/output prices per million tokens.
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
      } else if word == "--sort" {
        index += 1
        guard index < words.count, let sort = ["name": ModelCatalogSort.name,
          "input": .inputPrice, "output": .outputPrice][words[index]] else {
          throw Invalid(message: "Use --sort name, input or output.")
        }
        filter.sort = sort
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

extension MaiCLI {
  static func modelCatalogTable(_ models: [ModelDescriptor], selected: String?) -> MarkdownTable {
    func price(_ value: Double?) -> String {
      value.map { String(format: "%.6g", $0) } ?? ""
    }
    let columns: [(title: String, alignment: MarkdownTableAlignment, value: (ModelDescriptor) -> String)] = [
      ("Model", .leading, { model in
        let name = model.displayName == model.id ? model.id : "\(model.id) (\(model.displayName))"
        let label = markdownTableCell(name)
        return model.id == selected ? "**\\* \(label)**" : label
      }),
      ("Owner", .leading, { markdownTableCell($0.ownedBy ?? "") }),
      ("Features", .leading, { $0.features.map(\.title).joined(separator: ", ") }),
      ("Context", .trailing, { $0.contextLabel ?? "" }),
      ("Input $/1M", .trailing, { price($0.pricing?.inputPerMillion) }),
      ("Output $/1M", .trailing, { price($0.pricing?.outputPerMillion) }),
      ("Cache $/1M", .trailing, { price($0.pricing?.cachedInputPerMillion) }),
      ("$/request", .trailing, { price($0.pricing?.request) }),
      ("Pricing", .leading, { model in
        guard let pricing = model.pricing else { return "" }
        return [pricing.hasTiers ? "base rate; tiers vary" : nil, pricing.configured ? "configured" : nil]
          .compactMap { $0 }.joined(separator: "; ")
      }),
    ]
    let visible = columns.filter { column in models.contains { !column.value($0).isEmpty } }
    return MarkdownTable(
      headers: visible.map(\.title), alignments: visible.map(\.alignment),
      rows: models.map { model in visible.map { $0.value(model) } })
  }
}
