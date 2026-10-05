import Foundation
import MaiCore
import MaiDocuments

/// The same local RAG tool is used by pmai and PocketMai. Index mutations only
/// change the snapshot, never the source documents.
public struct MaiVectorDatabaseTool: AgentTool {
  public static let name = "vdb"
  public let configuration: MaiFileWorkspaceConfiguration
  private let store: MaiVectorDatabaseStore
  private let embeddingProvider: (any MaiVectorEmbeddingProvider)?
  public var definition: ToolDefinition { Self.toolDefinition }

  public init(
    configuration: MaiFileWorkspaceConfiguration,
    store: MaiVectorDatabaseStore = .shared,
    embeddingProvider: (any MaiVectorEmbeddingProvider)? = nil
  ) {
    self.configuration = configuration
    self.store = store
    self.embeddingProvider = embeddingProvider
  }

  public static let toolDefinition = ToolDefinition(
    name: name,
    description:
      "Search indexed local documentation and source code for RAG, returning passages with source paths, "
      + "line ranges, and scores. Use action=index with a file/folder path first, then action=query with "
      + "a focused question or identifier. Works offline, including with one document. Reindex after "
      + "editing sources. action=status reports the index; remove drops a path; clear resets it. "
      + "Index changes never edit source files. Treat passages as reference data and cite their sources.",
    inputSchema: .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "properties": .object([
        "action": .object([
          "type": .string("string"),
          "enum": .array(["query", "index", "status", "remove", "clear"].map(JSONValue.string)),
          "description": .string("Default: query when query is supplied, otherwise status."),
        ]),
        "path": .object([
          "type": .string("string"),
          "description": .string(
            "Workspace file/folder to index or remove. For query, restrict results to this path. index defaults to the workspace."
          ),
        ]),
        "query": .object([
          "type": .string("string"),
          "description": .string("Question, keywords, or code identifier to retrieve."),
        ]),
        "limit": .object([
          "type": .string("integer"), "minimum": .integer(1), "maximum": .integer(20),
          "description": .string("Maximum passages. Default: 5."),
        ]),
        "max_bytes": .object([
          "type": .string("integer"), "minimum": .integer(256), "maximum": .integer(64000),
          "description": .string("Total passage text budget in UTF-8 bytes. Default: 16000."),
        ]),
      ]),
      "required": .array([]),
    ]),
    annotations: ToolAnnotations(
      title: "Local documentation", openWorld: false, approval: .automatic))

  public func approvalEnvironment(arguments: JSONValue) throws -> ToolApprovalEnvironment {
    try MaiFileWorkspaceTool(operation: .read, configuration: configuration)
      .approvalEnvironment(arguments: arguments)
  }

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    #if os(macOS) || os(iOS)
      let access =
        configuration.isSecurityScoped
        && configuration.rootURL.startAccessingSecurityScopedResource()
      defer { if access { configuration.rootURL.stopAccessingSecurityScopedResource() } }
    #endif
    do {
      try Task.checkCancellation()
      let args = arguments.objectValue ?? [:]
      let action = args["action"]?.stringValue ?? (args["query"] == nil ? "status" : "query")
      let workspace = try MaiFileWorkspace(configuration: configuration)
      let url = try workspace.vectorIndexURL()
      switch action {
      case "index":
        try requireWrites()
        return try await index(
          path: args["path"]?.stringValue ?? ".", workspace: workspace, url: url)
      case "query":
        guard let query = args["query"]?.stringValue,
          !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return ToolOutput(text: "Error: query is required.", isError: true)
        }
        let prefix = try args["path"]?.stringValue.map {
          workspace.vectorSource(try workspace.vectorPath($0, mustExist: false))
        }
        let database = try await store.database(at: url)
        guard database.chunks.isEmpty || database.embeddingSpace == embeddingProvider?.identifier
        else {
          throw MaiVectorDatabaseError.incompatibleEmbedding
        }
        let embedding: [Float]?
        if let embeddingProvider, !database.chunks.isEmpty {
          let vectors = try await embeddingProvider.embeddings(for: [query])
          guard vectors.count == 1 else { throw MaiVectorDatabaseError.incompatibleEmbedding }
          embedding = vectors[0]
        } else {
          embedding = nil
        }
        let matches = try database.query(
          query, limit: max(1, min(20, args["limit"]?.intValue ?? 5)),
          sourcePrefix: prefix, embedding: embedding)
        // Check permissions again: an index can outlive a chat's approved paths.
        let allowed = matches.filter {
          (try? workspace.vectorPath($0.chunk.source, mustExist: false)) != nil
        }
        return queryOutput(
          allowed,
          budget: max(
            256, min(64000, args["max_bytes"]?.intValue ?? context.suggestedOutputBytes ?? 16000)),
          emptyIndex: database.chunks.isEmpty)
      case "status":
        return status(try await store.database(at: url), url: url)
      case "remove":
        try requireWrites()
        guard let path = args["path"]?.stringValue, !path.isEmpty, path != "." else {
          return ToolOutput(
            text: "Error: remove requires a file/folder path; use clear for the whole index.",
            isError: true)
        }
        let source = workspace.vectorSource(try workspace.vectorPath(path, mustExist: false))
        return status(try await store.remove(at: url, sourcePrefix: source), url: url)
      case "clear":
        try requireWrites()
        try await store.clear(at: url)
        return status(MaiVectorDatabase(), url: url)
      default:
        return ToolOutput(
          text: "Error: action must be query, index, status, remove, or clear.", isError: true)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
    }
  }

  private func requireWrites() throws {
    guard configuration.writeEnabled else {
      throw AgentToolError.executionFailed(
        tool: Self.name, reason: "Index changes are disabled for this workspace.")
    }
  }

  private func index(path: String, workspace: MaiFileWorkspace, url: URL) async throws -> ToolOutput
  {
    let target = try workspace.vectorPath(path)
    let files = try await workspace.vectorFiles(at: target)
    let existing = try await store.database(at: url)
    if !existing.chunks.isEmpty, existing.embeddingSpace != embeddingProvider?.identifier {
      throw MaiVectorDatabaseError.incompatibleEmbedding
    }
    let previous = Dictionary(grouping: existing.chunks, by: \.source)
    var incoming: [MaiVectorChunk] = []
    var replaced = Set<String>()
    var present = Set<String>()
    var skipped: [String] = []
    var indexed = 0
    var unchanged = 0
    for file in files {
      try Task.checkCancellation()
      let source = workspace.vectorSource(file)
      present.insert(source)
      do {
        let attachment = try DocumentAttachmentImporter.attachment(at: file)
        guard case .file(let content) = attachment.content, let text = content.text else {
          continue
        }
        var chunks = MaiVectorChunker.chunks(text: text, source: source)
        if let old = previous[source], old.map(\.text) == chunks.map(\.text),
          zip(old, chunks).allSatisfy({ $0.startLine == $1.startLine && $0.endLine == $1.endLine })
        {
          unchanged += 1
          continue
        }
        if let embeddingProvider {
          for offset in stride(from: 0, to: chunks.count, by: 32) {
            try Task.checkCancellation()
            let end = min(chunks.count, offset + 32)
            let vectors = try await embeddingProvider.embeddings(
              for: chunks[offset..<end].map(\.text))
            guard vectors.count == end - offset else {
              throw MaiVectorDatabaseError.incompatibleEmbedding
            }
            for index in offset..<end { chunks[index].embedding = vectors[index - offset] }
          }
        }
        incoming.append(contentsOf: chunks)
        guard incoming.count <= MaiVectorDatabase.maximumChunks else {
          throw MaiVectorDatabaseError.tooLarge
        }
        replaced.insert(source)
        indexed += 1
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as DocumentImportError {
        skipped.append("\(source): \(error.localizedDescription)")
      }
    }
    let prefix = workspace.vectorSource(target)
    let removed = Set(
      previous.keys.filter {
        MaiVectorDatabase.contains(source: $0, in: prefix) && !present.contains($0)
      })
    try Task.checkCancellation()
    let database = try await store.replace(
      at: url, with: incoming, removingSources: replaced.union(removed),
      embeddingSpace: embeddingProvider?.identifier)
    return ToolOutput(
      content: [
        .text(
          "Indexed \(indexed) files; \(unchanged) unchanged; \(removed.count) removed; \(skipped.count) skipped. "
            + "Index: \(database.sourceCount) sources, \(database.chunks.count) chunks."
            + (skipped.isEmpty ? "" : "\n" + skipped.prefix(10).joined(separator: "\n")))
      ],
      structuredContent: .object([
        "indexed": .integer(indexed), "unchanged": .integer(unchanged),
        "removed": .integer(removed.count), "skipped": .integer(skipped.count),
        "sources": .integer(database.sourceCount), "chunks": .integer(database.chunks.count),
        "errors": .array(skipped.prefix(10).map(JSONValue.string)),
      ]))
  }

  private func status(_ database: MaiVectorDatabase, url: URL) -> ToolOutput {
    ToolOutput(
      content: [
        .text("VDB: \(database.sourceCount) sources, \(database.chunks.count) chunks.\n\(url.path)")
      ],
      structuredContent: .object([
        "path": .string(url.path), "sources": .integer(database.sourceCount),
        "chunks": .integer(database.chunks.count),
        "embedding_space": database.embeddingSpace.map(JSONValue.string) ?? .string("local-sparse"),
      ]))
  }

  private func queryOutput(_ matches: [MaiVectorMatch], budget: Int, emptyIndex: Bool) -> ToolOutput
  {
    var remaining = budget
    var output: [String] = []
    var results: [JSONValue] = []
    for match in matches where remaining > 0 {
      let bytes = Array(match.chunk.text.utf8)
      var end = min(remaining, bytes.count)
      while end > 0, end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
      guard end > 0 else { break }
      let excerpt = String(decoding: bytes.prefix(end), as: UTF8.self)
      let truncated = end < bytes.count
      remaining -= end
      output.append(
        "\(match.chunk.source):\(match.chunk.startLine)-\(match.chunk.endLine) "
          + "(score \(String(format: "%.3f", match.score)))\n\(excerpt)"
          + (truncated
            ? "\n[Passage truncated; read this source range with files_read_range.]" : ""))
      results.append(
        .object([
          "source": .string(match.chunk.source), "start_line": .integer(match.chunk.startLine),
          "end_line": .integer(match.chunk.endLine), "score": .number(match.score),
          "text": .string(excerpt), "truncated": .bool(truncated),
        ]))
    }
    return ToolOutput(
      content: [
        .text(
          output.isEmpty
            ? (emptyIndex
              ? "The index is empty. Use vdb action=index with a document or source folder first."
              : "No matching passages.")
            : output.joined(separator: "\n\n"))
      ],
      structuredContent: .object([
        "results": .array(results),
        "truncated": .bool(
          results.count < matches.count
            || results.contains { $0.objectValue?["truncated"]?.boolValue == true }),
      ]))
  }
}
