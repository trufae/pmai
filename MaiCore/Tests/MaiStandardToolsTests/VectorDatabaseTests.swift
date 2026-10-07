import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

struct VectorDatabaseTests {
  private struct TestEmbeddingProvider: MaiVectorEmbeddingProvider {
    let identifier = "test-model"
    var fails = false
    func embeddings(for texts: [String]) async throws -> [[Float]] {
      if fails { throw MaiVectorDatabaseError.invalidIndex("embedding service unavailable") }
      return texts.map { _ in [1, 0] }
    }
  }

  @Test("Host embedding providers enable semantic-only matches and fail without changing the index")
  func embeddingProviderIntegration() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("guide.md")
    try Data("Canine training advice".utf8).write(to: file)
    let configuration = MaiFileWorkspaceConfiguration(rootURL: directory)
    let tool = MaiVectorDatabaseTool(
      configuration: configuration, embeddingProvider: TestEmbeddingProvider())
    let indexed = try await call(tool, ["action": .string("index")])
    #expect(!indexed.isError)
    let semantic = try await call(tool, ["query": .string("puppy")])
    #expect(semantic.text.contains("Canine training advice"))
    let local = MaiVectorDatabaseTool(configuration: configuration)
    #expect(try await call(local, ["query": .string("canine")]).isError)
    let snapshot = directory.appendingPathComponent(MaiVectorDatabaseStore.relativePath)
    let before = try Data(contentsOf: snapshot)
    try Data("Updated canine advice".utf8).write(to: file)
    let failing = MaiVectorDatabaseTool(
      configuration: configuration, embeddingProvider: TestEmbeddingProvider(fails: true))
    #expect(try await call(failing, ["action": .string("index")]).isError)
    #expect(try Data(contentsOf: snapshot) == before)
    #expect(try await call(failing, ["query": .string("puppy")]).isError)
    #expect(!(try await call(local, ["action": .string("clear")])).isError)
  }

  private func chunk(_ text: String, source: String) -> MaiVectorChunk {
    MaiVectorChunk(source: source, startLine: 1, endLine: 1, text: text)
  }

  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mai-vdb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func call(_ tool: MaiVectorDatabaseTool, _ arguments: [String: JSONValue]) async throws
    -> ToolOutput
  {
    try await tool.call(
      arguments: .object(arguments),
      context: ToolExecutionContext(
        run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
        modelTurn: 0))
  }

  @Test(
    "Retrieval finds the relevant passage with one, a few, and many vectors",
    arguments: [1, 3, 1000])
  func smallAndLargeCorpora(count: Int) throws {
    var database = MaiVectorDatabase()
    var chunks = [chunk("The author of radare2 is pancake.", source: "project.md")]
    chunks += (1..<count).map {
      chunk("Banana fruit garden harvest \($0)", source: "fruit/\($0).txt")
    }
    try database.replace(with: chunks)
    let matches = try database.query("Who is the author of radare2?", limit: 5)
    #expect(matches.count == 1)
    #expect(matches.first?.chunk.source == "project.md")
    #expect((matches.first?.score ?? 0) > 0)
    #expect(try database.query("unrelatedxyz").isEmpty)
    #expect(try database.query("the and of").isEmpty)
    #expect(try database.query("radare2", limit: 0).isEmpty)
  }

  @Test("Queries never mutate statistics, and insertion order does not change ranking")
  func stableStatistics() throws {
    let chunks = [
      chunk("socket socket network", source: "socket.md"),
      chunk("network socket server listen", source: "server.md"),
      chunk("socket fruit", source: "other.md"),
    ]
    var forward = MaiVectorDatabase()
    var reverse = MaiVectorDatabase()
    for item in chunks { try forward.replace(with: [item]) }
    for item in chunks.reversed() { try reverse.replace(with: [item]) }
    let expected = try forward.query("socket server")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(forward)
    for _ in 0..<10 {
      _ = try forward.query("network newterm")
      #expect(try forward.query("socket server") == expected)
    }
    #expect(try encoder.encode(forward) == before)
    #expect(try reverse.query("socket server") == expected)
    var fresh = MaiVectorDatabase()
    let added = chunk("server server server configuration", source: "config.md")
    try forward.replace(with: [added])
    try fresh.replace(with: chunks + [added])
    #expect(try forward.query("socket server") == fresh.query("socket server"))
  }

  @Test("Identifiers retain exact matches and split camel case, acronyms and underscores")
  func codeAndUnicode() throws {
    var database = MaiVectorDatabase()
    try database.replace(with: [
      chunk("func HTTPTokenCache_readValue() { return token }", source: "Cache.swift"),
      chunk("Documentación de conexión: café 東京", source: "guide.md"),
    ])
    #expect(try database.query("HTTPTokenCache_readValue").first?.chunk.source == "Cache.swift")
    #expect(try database.query("http token cache read value").first?.chunk.source == "Cache.swift")
    #expect(try database.query("CONEXION cafe 東京").first?.chunk.source == "guide.md")
    #expect(try database.query("cache", sourcePrefix: "guide.md").isEmpty)
    #expect(!MaiVectorDatabase.contains(source: "docs-old/a.md", in: "docs"))
  }

  @Test("Chunking bounds long Unicode lines and preserves line references and coverage")
  func chunkBounds() {
    let longLine = String(repeating: "東京🙂 ", count: 2000)
    let chunks = MaiVectorChunker.chunks(
      text: longLine, source: "long.md", maximumCharacters: 100, overlapLines: 0)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.text.count <= 100 && $0.startLine == 1 && $0.endLine == 1 })
    #expect(chunks.map(\.text).joined() == longLine)
    let lines = (1...100).map { "line\($0) " + String(repeating: "x", count: 30) }
    let passages = MaiVectorChunker.chunks(
      text: lines.joined(separator: "\n"), source: "source.c", maximumCharacters: 100,
      overlapLines: 999)
    #expect(passages.allSatisfy { $0.text.count <= 100 })
    #expect(passages.last?.endLine == 100)
    for line in 1...100 {
      #expect(passages.contains { $0.startLine <= line && $0.endLine >= line })
    }
  }

  @Test("Dense search validates vector spaces and never silently falls back")
  func denseVectors() throws {
    var database = MaiVectorDatabase()
    let positive = MaiVectorChunk(
      source: "positive.md", startLine: 1, endLine: 1, text: "Happy dog", embedding: [1, 0])
    let negative = MaiVectorChunk(
      source: "negative.md", startLine: 1, endLine: 1, text: "Sad cat", embedding: [-1, 0])
    try database.replace(with: [positive, negative], embeddingSpace: "test-model")
    #expect(
      try database.query("unseenword", embedding: [4, 0]).map(\.chunk.source) == ["positive.md"])
    #expect(throws: MaiVectorDatabaseError.self) { try database.query("dog") }
    #expect(throws: MaiVectorDatabaseError.self) { try database.query("dog", embedding: [1]) }
    #expect(throws: MaiVectorDatabaseError.self) { try database.query("dog", embedding: [0, 0]) }
    var invalid = positive
    invalid.embedding = [.nan, 0]
    #expect(throws: MaiVectorDatabaseError.self) {
      try database.replace(with: [invalid], embeddingSpace: "test-model")
    }
    #expect(database.chunks.count == 2)
    #expect(throws: MaiVectorDatabaseError.self) {
      try database.replace(with: [positive], embeddingSpace: "different-model")
    }
    let decoded = try JSONDecoder().decode(
      MaiVectorDatabase.self, from: JSONEncoder().encode(database))
    #expect(
      try decoded.query("dog", embedding: [1, 0]) == database.query("dog", embedding: [1, 0]))
  }

  @Test(
    "Snapshots survive restarts, reload external writes, and serialize concurrent source updates")
  func persistence() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("vdb.json")
    let store = MaiVectorDatabaseStore()
    #expect(try await store.database(at: url).chunks.isEmpty)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        let item = chunk("network \(index)", source: "\(index).md")
        group.addTask { _ = try await store.replace(at: url, with: [item]) }
      }
      try await group.waitForAll()
    }
    #expect(try await store.database(at: url).sourceCount == 8)
    let restarted = MaiVectorDatabaseStore()
    #expect(try await restarted.database(at: url).sourceCount == 8)
    _ = try await restarted.replace(at: url, with: [chunk("other", source: "new.md")])
    #expect(try await store.database(at: url).sourceCount == 9)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        let item = chunk("parallel \(index)", source: "parallel/\(index).md")
        group.addTask {
          _ = try await MaiVectorDatabaseStore().replace(at: url, with: [item])
        }
      }
      try await group.waitForAll()
    }
    #expect(try await store.database(at: url).sourceCount == 17)
  }

  @Test(
    "The shared tool indexes documents and code, refreshes changes and deletions, and preserves sources"
  )
  func indexingLifecycle() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let docs = directory.appendingPathComponent("docs")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try Data("# Authentication\nUse refreshToken to renew credentials.\n".utf8).write(
      to: docs.appendingPathComponent("guide.md"))
    try Data("func refreshToken() { return credentials }\n".utf8).write(
      to: directory.appendingPathComponent("Auth.swift"))
    try Data("{\"database\":\"sqlite storage\"}".utf8).write(
      to: docs.appendingPathComponent("config.json"))
    let tool = MaiVectorDatabaseTool(
      configuration: MaiFileWorkspaceConfiguration(rootURL: directory))
    let first = try await call(tool, ["action": .string("index")])
    #expect(!first.isError)
    #expect(first.structuredContent?.objectValue?["indexed"]?.intValue == 3)
    let query = try await call(tool, ["query": .string("refresh token credentials")])
    let results = query.structuredContent?.objectValue?["results"]?.arrayValue ?? []
    #expect(results.count == 2)
    #expect(results.allSatisfy { $0.objectValue?["start_line"]?.intValue == 1 })
    let json = try await call(tool, ["query": .string("sqlite"), "path": .string("docs")])
    #expect(json.text.contains("docs/config.json"))
    let again = try await call(tool, ["action": .string("index")])
    #expect(again.structuredContent?.objectValue?["unchanged"]?.intValue == 3)
    try Data("New instructions for banana cultivation.\n".utf8).write(
      to: docs.appendingPathComponent("guide.md"))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("Auth.swift"))
    let refresh = try await call(tool, ["action": .string("index")])
    #expect(refresh.structuredContent?.objectValue?["removed"]?.intValue == 1)
    #expect(
      try await call(tool, ["query": .string("refreshToken")]).text == "No matching passages.")
    try Data().write(to: docs.appendingPathComponent("guide.md"))
    let emptied = try await call(
      tool, ["action": .string("index"), "path": .string("docs/guide.md")])
    #expect(!emptied.isError)
    #expect(try await call(tool, ["query": .string("banana")]).text == "No matching passages.")
    let remove = try await call(tool, ["action": .string("remove"), "path": .string("docs")])
    #expect(remove.structuredContent?.objectValue?["sources"]?.intValue == 0)
    #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent("guide.md").path))
  }

  @Test(
    "Indexing skips generated folders and rejects escaped paths, hidden roots, and index symlinks")
  func confinement() async throws {
    let directory = try root()
    let external = try root()
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.removeItem(at: external)
    }
    try Data("private external data".utf8).write(to: external.appendingPathComponent("secret.md"))
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("escape.md"),
      withDestinationURL: external.appendingPathComponent("secret.md"))
    for name in ["node_modules", ".git", "Models"] {
      let folder = directory.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("generated secret content".utf8).write(
        to: folder.appendingPathComponent("hidden.md"))
    }
    try Data("public documentation".utf8).write(to: directory.appendingPathComponent("readme"))
    let tool = MaiVectorDatabaseTool(
      configuration: MaiFileWorkspaceConfiguration(
        rootURL: directory, hiddenRootEntryNames: ["Models"]))
    #expect(
      try await call(tool, ["action": .string("index")]).structuredContent?.objectValue?["sources"]?
        .intValue == 1)
    #expect(
      try await call(tool, ["action": .string("index"), "path": .string("escape.md")]).isError)
    #expect(try await call(tool, ["action": .string("index"), "path": .string("../")]).isError)
    #expect(try await call(tool, ["action": .string("index"), "path": .string("Models")]).isError)
    #expect(try await call(tool, ["action": .string("index"), "path": .string(".pmai")]).isError)
    #expect(try await call(tool, ["query": .string("secret")]).text == "No matching passages.")
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".pmai"))
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent(".pmai"), withDestinationURL: external)
    #expect(try await call(tool, ["action": .string("clear")]).isError)
    #expect(
      !FileManager.default.fileExists(atPath: external.appendingPathComponent("vdb.json").path))
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".pmai"))
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".pmai"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent(MaiVectorDatabaseStore.relativePath),
      withDestinationURL: directory.appendingPathComponent("readme"))
    #expect(try await call(tool, ["action": .string("clear")]).isError)
    #expect(
      try String(contentsOf: directory.appendingPathComponent("readme"), encoding: .utf8)
        == "public documentation")
  }

  @Test(
    "Read-only workspaces can query, corrupted indexes are explicit, and clearing recovers them")
  func errorsAndBudget() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("guide.md")
    try Data(("café " + String(repeating: "🙂", count: 400)).utf8).write(to: source)
    let tool = MaiVectorDatabaseTool(
      configuration: MaiFileWorkspaceConfiguration(rootURL: directory))
    #expect(!(try await call(tool, ["action": .string("index")])).isError)
    let readOnly = MaiVectorDatabaseTool(
      configuration: MaiFileWorkspaceConfiguration(rootURL: directory, writeEnabled: false))
    for action in ["index", "remove", "clear"] {
      #expect(
        try await call(readOnly, ["action": .string(action), "path": .string("guide.md")]).isError)
    }
    let query = try await call(readOnly, ["query": .string("cafe"), "max_bytes": .integer(256)])
    let result = try #require(
      query.structuredContent?.objectValue?["results"]?.arrayValue?.first?.objectValue)
    #expect((result["text"]?.stringValue?.utf8.count ?? 999) <= 256)
    #expect(result["truncated"]?.boolValue == true)
    #expect(!query.text.contains("�"))
    let snapshot = directory.appendingPathComponent(MaiVectorDatabaseStore.relativePath)
    try Data("broken".utf8).write(to: snapshot)
    #expect(try await call(tool, ["action": .string("status")]).isError)
    #expect(!(try await call(tool, ["action": .string("clear")])).isError)
    #expect(try await call(tool, ["query": .string("cafe")]).text.contains("index is empty"))
  }

  @Test("Workspace scope follows the calling session and the standard factory exposes vdb")
  func hostIntegration() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("unique documentation".utf8).write(to: directory.appendingPathComponent("doc.md"))
    let tool = MaiVectorDatabaseTool(
      configuration: MaiFileWorkspaceConfiguration(
        rootURL: directory, followsProcessWorkingDirectory: true))
    let scope = AgentExecutionScope(sessionID: "test", workingDirectory: directory)
    try await AgentExecutionScope.$current.withValue(scope) { () async throws -> Void in
      #expect(!(try await call(tool, ["action": .string("index")])).isError)
      #expect(try await call(tool, ["query": .string("unique")]).text.contains("doc.md"))
    }
    let factory = MaiStandardToolFactory()
    let context = PluginFactoryContext(id: "standard", environment: [:])
    #expect(try await factory.makeTools(context: context).contains { $0.definition.name == "vdb" })
    #expect(
      try await factory.toolGroups(context: context).first { $0.id == "vdb" }?.toolNames == ["vdb"])
  }
}
