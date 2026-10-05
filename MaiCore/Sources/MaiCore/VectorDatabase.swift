import Foundation

/// A retrievable passage. Line numbers refer to the indexed text; for converted
/// documents that is the Markdown, rather than a PDF page or Word paragraph.
public struct MaiVectorChunk: Codable, Equatable, Sendable {
  public var source: String
  public var startLine: Int
  public var endLine: Int
  public var text: String
  public var embedding: [Float]?

  public init(source: String, startLine: Int, endLine: Int, text: String, embedding: [Float]? = nil)
  {
    self.source = source
    self.startLine = startLine
    self.endLine = endLine
    self.text = text
    self.embedding = embedding
  }
}

public struct MaiVectorMatch: Codable, Equatable, Sendable {
  public var chunk: MaiVectorChunk
  /// A ranking score, not a probability. Higher is better.
  public var score: Double
}

public enum MaiVectorDatabaseError: LocalizedError, Sendable {
  case invalidIndex(String)
  case incompatibleEmbedding
  case tooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidIndex(let reason): "Invalid vector index: \(reason)"
    case .incompatibleEmbedding:
      "The embedding model or vector dimensions differ from this index. Clear it before changing models."
    case .tooLarge: "The vector index exceeds its limit of 20,000 chunks or 64 MB."
    }
  }
}

/// Hosts can supply a local or remote model. Every indexed passage and query
/// must use the same identifier and dimension; failures never fall back to a
/// different embedding space.
public protocol MaiVectorEmbeddingProvider: Sendable {
  var identifier: String { get }
  func embeddings(for texts: [String]) async throws -> [[Float]]
}

/// Exact sparse TF-IDF cosine search with BM25 length normalization. Sparse
/// coordinates are actual terms, so there are no hash collisions or minimum
/// corpus size. An optional host-supplied dense embedding augments that ranking.
public struct MaiVectorDatabase: Codable, Sendable {
  public static let maximumChunks = 20_000
  public static let maximumIndexBytes = 64 * 1024 * 1024
  public private(set) var chunks: [MaiVectorChunk]
  public private(set) var embeddingSpace: String?
  public var sourceCount: Int { Set(chunks.map(\.source)).count }

  private var frequencies: [[String: Int]] = []
  private var postings: [String: [Int]] = [:]
  private var inverseFrequencies: [String: Double] = [:]
  private var norms: [Double] = []
  private var lengths: [Double] = []
  private var averageLength = 1.0
  private var denseVectors: [[Double]] = []

  public init() {
    chunks = []
  }

  private enum CodingKeys: String, CodingKey { case version, chunks, embeddingSpace }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(Int.self, forKey: .version) == 1 else {
      throw MaiVectorDatabaseError.invalidIndex("unsupported version")
    }
    self.init()
    let space = try container.decodeIfPresent(String.self, forKey: .embeddingSpace)
    try replace(
      with: container.decode([MaiVectorChunk].self, forKey: .chunks),
      removingSources: [], embeddingSpace: space)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(1, forKey: .version)
    try container.encode(chunks, forKey: .chunks)
    try container.encodeIfPresent(embeddingSpace, forKey: .embeddingSpace)
  }

  /// Replaces complete sources in one transaction and rebuilds all statistics.
  /// Queries are pure: insertion order and earlier queries cannot affect them.
  public mutating func replace(
    with incoming: [MaiVectorChunk], removingSources: Set<String> = [],
    embeddingSpace space: String? = nil
  ) throws {
    if !chunks.isEmpty, space != embeddingSpace {
      throw MaiVectorDatabaseError.incompatibleEmbedding
    }
    let replaced = Set(incoming.map(\.source)).union(removingSources)
    let next = (chunks.filter { !replaced.contains($0.source) } + incoming).sorted {
      if $0.source != $1.source { return $0.source < $1.source }
      if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
      if $0.endLine != $1.endLine { return $0.endLine < $1.endLine }
      return $0.text < $1.text
    }
    guard next.count <= Self.maximumChunks,
      next.reduce(0, { $0 + $1.text.utf8.count }) <= Self.maximumIndexBytes
    else { throw MaiVectorDatabaseError.tooLarge }
    var dimension: Int?
    for chunk in next {
      guard !chunk.source.isEmpty, chunk.startLine > 0, chunk.endLine >= chunk.startLine,
        !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw MaiVectorDatabaseError.invalidIndex("empty source/text or invalid line range") }
      if space != nil {
        guard let vector = chunk.embedding, !vector.isEmpty,
          vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }),
          dimension == nil || dimension == vector.count
        else { throw MaiVectorDatabaseError.incompatibleEmbedding }
        dimension = vector.count
      } else if chunk.embedding != nil {
        throw MaiVectorDatabaseError.incompatibleEmbedding
      }
    }
    chunks = next
    embeddingSpace = next.isEmpty ? nil : space
    rebuild()
  }

  public func query(
    _ text: String, limit: Int = 5, sourcePrefix: String? = nil,
    embedding: [Float]? = nil, minimumScore: Double = 0
  ) throws -> [MaiVectorMatch] {
    guard limit > 0, !chunks.isEmpty else { return [] }
    var queryVector: [String: Double] = [:]
    for (term, count) in MaiVectorTokenizer.frequencies(text) {
      if let idf = inverseFrequencies[term] {
        queryVector[term] = (1 + log(Double(count))) * idf
      }
    }
    let queryNorm = sqrt(queryVector.values.reduce(0) { $0 + $1 * $1 })
    var candidates = Set<Int>()
    for term in queryVector.keys { candidates.formUnion(postings[term] ?? []) }
    let denseQuery: [Double]?
    if let embedding {
      guard embeddingSpace != nil, embedding.count == denseVectors.first?.count,
        embedding.allSatisfy(\.isFinite), embedding.contains(where: { $0 != 0 })
      else { throw MaiVectorDatabaseError.incompatibleEmbedding }
      denseQuery = Self.normalized(embedding)
      candidates = Set(chunks.indices)
    } else {
      guard embeddingSpace == nil else { throw MaiVectorDatabaseError.incompatibleEmbedding }
      denseQuery = nil
    }
    var matches: [MaiVectorMatch] = []
    // Sorting terms also makes floating point accumulation deterministic.
    let terms = queryVector.keys.sorted()
    for index in candidates {
      let chunk = chunks[index]
      if let sourcePrefix, !Self.contains(source: chunk.source, in: sourcePrefix) { continue }
      var dot = 0.0
      var bm25 = 0.0
      for term in terms {
        guard let count = frequencies[index][term], let idf = inverseFrequencies[term] else {
          continue
        }
        let tf = Double(count)
        dot += (queryVector[term] ?? 0) * (1 + log(tf)) * idf
        let df = Double(postings[term]?.count ?? 0)
        let rarity = log(1 + (Double(chunks.count) - df + 0.5) / (df + 0.5))
        bm25 += rarity * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * lengths[index] / averageLength))
      }
      let cosine = queryNorm > 0 && norms[index] > 0 ? dot / (queryNorm * norms[index]) : 0
      var score = 0.5 * min(1, cosine) + 0.5 * bm25 / (1 + bm25)
      if let denseQuery {
        let denseCosine = zip(denseQuery, denseVectors[index]).reduce(0) { $0 + $1.0 * $1.1 }
        score = 0.5 * score + 0.5 * max(0, min(1, denseCosine))
      }
      if score > minimumScore { matches.append(MaiVectorMatch(chunk: chunk, score: score)) }
    }
    matches.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.chunk.source != $1.chunk.source { return $0.chunk.source < $1.chunk.source }
      if $0.chunk.startLine != $1.chunk.startLine { return $0.chunk.startLine < $1.chunk.startLine }
      return $0.chunk.endLine < $1.chunk.endLine
    }
    // Overlapping chunks should not fill a RAG result with the same passage.
    var selected: [MaiVectorMatch] = []
    for match in matches {
      if selected.contains(where: {
        guard $0.chunk.source == match.chunk.source else { return false }
        if $0.chunk.text == match.chunk.text { return true }
        let length = min(
          $0.chunk.endLine - $0.chunk.startLine + 1,
          match.chunk.endLine - match.chunk.startLine + 1)
        let overlap =
          min($0.chunk.endLine, match.chunk.endLine)
          - max($0.chunk.startLine, match.chunk.startLine) + 1
        return length > 1 && Double(overlap) / Double(length) > 0.5
      }) {
        continue
      }
      selected.append(match)
      if selected.count == limit { break }
    }
    return selected
  }

  public static func contains(source: String, in prefix: String) -> Bool {
    prefix.isEmpty || prefix == "." || source == prefix || source.hasPrefix(prefix + "/")
  }

  private mutating func rebuild() {
    frequencies = chunks.map { MaiVectorTokenizer.frequencies($0.text + "\n" + $0.source) }
    postings = [:]
    for (index, terms) in frequencies.enumerated() {
      for term in terms.keys { postings[term, default: []].append(index) }
    }
    inverseFrequencies = postings.mapValues {
      1 + log(Double(chunks.count + 1) / Double($0.count + 1))
    }
    lengths = frequencies.map { Double($0.values.reduce(0, +)) }
    averageLength = max(1, lengths.reduce(0, +) / Double(max(1, chunks.count)))
    norms = frequencies.map { terms in
      sqrt(
        terms.keys.sorted().reduce(0) { total, term in
          let weight = (1 + log(Double(terms[term] ?? 1))) * (inverseFrequencies[term] ?? 1)
          return total + weight * weight
        })
    }
    denseVectors = embeddingSpace == nil ? [] : chunks.map { Self.normalized($0.embedding ?? []) }
  }

  private static func normalized(_ vector: [Float]) -> [Double] {
    let values = vector.map(Double.init)
    let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
    return values.map { $0 / norm }
  }
}

/// Bounds context by characters while retaining original line numbers. Long
/// lines are split too, including minified code and prose with no newlines.
public enum MaiVectorChunker {
  public static func chunks(
    text: String, source: String, maximumCharacters: Int = 2400, overlapLines: Int = 3
  ) -> [MaiVectorChunk] {
    let maximum = max(1, maximumCharacters)
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    var pieces: [(text: String, line: Int, count: Int)] = []
    for (index, line) in lines.enumerated() {
      var remaining = (line + (index < lines.count - 1 ? "\n" : ""))[...]
      while !remaining.isEmpty {
        let part = String(remaining.prefix(maximum))
        pieces.append((part, index + 1, part.count))
        remaining = remaining.dropFirst(part.count)
      }
    }
    var result: [MaiVectorChunk] = []
    var start = 0
    while start < pieces.count {
      var end = start
      var count = 0
      while end < pieces.count, count + pieces[end].count <= maximum {
        count += pieces[end].count
        end += 1
      }
      let body = pieces[start..<end].map(\.text).joined()
      if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.append(
          MaiVectorChunk(
            source: source, startLine: pieces[start].line, endLine: pieces[end - 1].line, text: body
          ))
      }
      if end == pieces.count { break }
      start = max(start + 1, end - max(0, min(overlapLines, 20)))
    }
    return result
  }
}

enum MaiVectorTokenizer {
  private static let stopWords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "i", "in",
    "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "what", "when",
    "where", "which", "who", "with", "you",
  ]

  static func frequencies(_ text: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    func add(_ word: String) {
      let normalized = word.folding(
        options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased()
      if !normalized.isEmpty, !stopWords.contains(normalized) {
        counts[normalized, default: 0] += 1
      }
    }
    for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
      guard word.count <= 128 else { continue }
      let original = String(word)
      add(original)
      let characters = Array(word)
      var part = ""
      var parts: [String] = []
      for (index, character) in characters.enumerated() {
        let camelBoundary =
          index > 0 && character.isUppercase
          && (characters[index - 1].isLowercase
            || (index + 1 < characters.count && characters[index - 1].isUppercase
              && characters[index + 1].isLowercase))
        if character == "_" || camelBoundary {
          if !part.isEmpty {
            parts.append(part)
            part = ""
          }
        }
        if character != "_" { part.append(character) }
      }
      if !part.isEmpty { parts.append(part) }
      if parts.count > 1 { for part in parts { add(part) } }
    }
    return counts
  }
}
