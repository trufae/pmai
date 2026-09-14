import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import MaiCore
@testable import MaiStandardTools

private let fetchContext = ToolExecutionContext(
  run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0), modelTurn: 1)

@Test("Web fetch pages reconstruct large UTF-8 sources without refetching or dropping braces")
func webFetchPagesPreserveLargeSource() async throws {
  let body = String(repeating: "  if enabled {\n    print(\"a🦊é\")\n  }\n}\n}\n\n", count: 800)
  let fixture = FetchFixture(body: body)
  defer { fixture.remove() }
  let tool = MaiWebFetchTool(service: fixture.service())
  var result = try await tool.call(arguments: .object(["url": .string(fixture.url)]), context: fetchContext)
  let id = try #require(result.structuredContent?.objectValue?["source_id"])
  #expect(result.structuredContent?.objectValue?["truncated"] == .bool(true))
  var reconstructed = fetchedBody(result)
  var offset = try #require(result.structuredContent?.objectValue?["nextOffset"]?.intValue)
  while offset < body.utf8.count {
    result = try await tool.call(arguments: .object([
      "source_id": id, "offset": .integer(offset), "max_bytes": .integer(1001),
    ]), context: fetchContext)
    #expect(!result.isError)
    let next = try #require(result.structuredContent?.objectValue?["nextOffset"]?.intValue)
    try #require(next > offset)
    offset = next
    reconstructed += fetchedBody(result)
  }
  #expect(reconstructed == body)
  #expect(!reconstructed.contains("�"))
  #expect(fixture.requests == 1)
  #expect(result.structuredContent?.objectValue?["truncated"] == .bool(false))
  let end = try await tool.call(arguments: .object(["source_id": id, "offset": .integer(offset)]), context: fetchContext)
  #expect(fetchedBody(end).isEmpty)
  #expect(!end.isError)
}

@Test("Web fetch searches beyond the old cap and supports metadata-only and larger pages")
func webFetchSearchesFullSnapshot() async throws {
  let body = String(repeating: "irrelevant data\n", count: 140_000) + "target-NEEDLE-42\n"
  let fixture = FetchFixture(body: body)
  defer { fixture.remove() }
  let tool = MaiWebFetchTool(service: fixture.service())
  let metadata = try await tool.call(arguments: .object([
    "url": .string(fixture.url), "max_bytes": .integer(0),
  ]), context: fetchContext)
  try #require(!metadata.isError)
  let id = try #require(metadata.structuredContent?.objectValue?["source_id"])
  #expect(fetchedBody(metadata).isEmpty)
  #expect(metadata.text.count < 1000)
  let found = try await tool.call(arguments: .object([
    "source_id": id, "query": .string("needle"), "max_bytes": .integer(100),
  ]), context: fetchContext)
  #expect(fetchedBody(found).contains("target-NEEDLE-42"))
  #expect(found.structuredContent?.objectValue?["matchOffset"]?.intValue ?? 0 > 2_000_000)
  let missing = try await tool.call(arguments: .object([
    "source_id": id, "query": .string("not present"),
  ]), context: fetchContext)
  #expect(!missing.isError)
  #expect(fetchedBody(missing).isEmpty)
  #expect(missing.text.contains("No matches"))
  let larger = try await tool.call(arguments: .object([
    "source_id": id, "max_bytes": .integer(256_000),
  ]), context: fetchContext)
  #expect(fetchedBody(larger).utf8.count == 256_000)
  #expect(fixture.requests == 1)
}

@Test("Web fetch rejects invalid pages and credentials before making a request")
func webFetchValidatesPages() async throws {
  let service = MaiWebFetchService()
  let invalid: [[String: JSONValue]] = [
    ["url": .string("file:///tmp/test")],
    ["url": .string("https://user:password@example.test")],
    ["url": .string("https://example.test"), "offset": .integer(-1)],
    ["url": .string("https://example.test"), "max_bytes": .integer(Int.max)],
    ["url": .string("https://example.test"), "source_id": .string("missing")],
    ["source_id": .string("missing")],
  ]
  for args in invalid {
    #expect(try await service.fetch(arguments: args).isError)
  }
}

@Test("Web fetch bounds unknown-length bodies as well as declared lengths", arguments: [false, true])
func webFetchEnforcesDownloadLimit(declared: Bool) async throws {
  let fixture = FetchFixture(body: String(repeating: "x", count: 4096), declaredLength: declared)
  defer { fixture.remove() }
  let result = try await fixture.service(downloadLimit: 1000).fetch(arguments: ["url": .string(fixture.url)])
  #expect(result.isError)
  #expect(result.text.contains("1000-byte download limit"))
}

@Test("Web fetch retains HTTP and binary errors", arguments: [404, 200])
func webFetchRejectsHTTPAndBinary(status: Int) async throws {
  let fixture = FetchFixture(body: "not text\0", status: status)
  defer { fixture.remove() }
  let result = try await fixture.service().fetch(arguments: ["url": .string(fixture.url)])
  #expect(result.isError)
  #expect(result.text.contains(status == 404 ? "HTTP 404" : "not readable text"))
}

@Test("Web fetch evicts complete snapshots by bytes and count", arguments: [false, true])
func webFetchCacheIsBounded(byCount: Bool) async throws {
  let fixture = FetchFixture(body: String(repeating: "x", count: 100))
  defer { fixture.remove() }
  let service = fixture.service(cacheBytes: byCount ? 1000 : 100, cacheEntries: byCount ? 1 : 16)
  let first = try await service.fetch(arguments: ["url": .string(fixture.url)])
  let id = try #require(first.structuredContent?.objectValue?["source_id"])
  _ = try await service.fetch(arguments: ["url": .string(fixture.url)])
  let expired = try await service.fetch(arguments: ["source_id": id])
  #expect(expired.isError)
  #expect(expired.text.contains("fetch the original URL again"))
}

@Test("Cancelling a web fetch stops its URLSession task")
func webFetchCancellation() async throws {
  let fixture = FetchFixture(body: "partial", hangs: true)
  defer { fixture.remove() }
  let service = fixture.service()
  let task = Task { try await service.fetch(arguments: ["url": .string(fixture.url)]) }
  for _ in 0..<200 where fixture.requests == 0 { try await Task.sleep(for: .milliseconds(5)) }
  try #require(fixture.requests == 1)
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  for _ in 0..<200 where !fixture.stopped { try await Task.sleep(for: .milliseconds(5)) }
  #expect(fixture.stopped)
  let alreadyCancelled = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await service.fetch(arguments: ["url": .string(fixture.url)])
  }
  await #expect(throws: CancellationError.self) { try await alreadyCancelled.value }
  #expect(fixture.requests == 1)
}

private func fetchedBody(_ output: ToolOutput) -> String {
  output.content.compactMap { part in
    if case .resource(let resource) = part { return resource.text }
    return nil
  }.joined()
}

/// Each test owns a host and its counters; Swift Testing can run them concurrently.
private final class FetchFixture: @unchecked Sendable {
  let url = "https://\(UUID().uuidString.lowercased()).example.test/source.swift"
  let body: Data
  let status: Int
  let declaredLength: Bool
  let hangs: Bool
  private let lock = NSLock()
  private var count = 0
  private var didStop = false
  var requests: Int { lock.withLock { count } }
  var stopped: Bool { lock.withLock { didStop } }

  init(body: String, status: Int = 200, declaredLength: Bool = false, hangs: Bool = false) {
    self.body = Data(body.utf8)
    self.status = status
    self.declaredLength = declaredLength
    self.hangs = hangs
    FetchProtocol.lock.withLock { FetchProtocol.fixtures[url] = self }
  }

  func remove() { _ = FetchProtocol.lock.withLock { FetchProtocol.fixtures.removeValue(forKey: url) } }
  func noteRequest() { lock.withLock { count += 1 } }
  func noteStop() { lock.withLock { didStop = true } }
  func service(downloadLimit: Int = 16_000_000, cacheBytes: Int = 32_000_000, cacheEntries: Int = 16) -> MaiWebFetchService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FetchProtocol.self]
    return MaiWebFetchService(configuration: configuration, maximumDownloadedBytes: downloadLimit, maximumCacheBytes: cacheBytes, maximumCacheEntries: cacheEntries)
  }
}

private final class FetchProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  nonisolated(unsafe) static var fixtures: [String: FetchFixture] = [:]
  private var fixture: FetchFixture? { Self.lock.withLock { Self.fixtures[request.url!.absoluteString] } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
    fixture.noteRequest()
    var headers = ["Content-Type": "text/plain; charset=utf-8"]
    if fixture.declaredLength { headers["Content-Length"] = String(fixture.body.count) }
    let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for offset in stride(from: 0, to: fixture.body.count, by: 512) {
      if fixture.stopped { return }
      client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<min(offset + 512, fixture.body.count)))
    }
    if !fixture.hangs { client?.urlProtocolDidFinishLoading(self) }
  }
  override func stopLoading() { fixture?.noteStop() }
}
