import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MaiCore

final class URLSessionStreamingTests: XCTestCase {
  func testProviderRedirectPolicyIsAvailableThroughTheTaskDelegateProtocol() async {
    let url = URL(string: "https://provider.test/v1/chat/completions")!
    var request = URLRequest(url: url)
    request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
    let delegate: any URLSessionTaskDelegate = ProviderRedirectDelegate(originalRequest: request)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let rejected = expectation(description: "Cross-origin redirect rejected")
    let task = session.dataTask(with: request)
    let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
    let proposed = URLRequest(url: URL(string: "https://another.test/collect")!)
    let completion: @Sendable (URLRequest?) -> Void = { redirect in
      XCTAssertNil(redirect)
      rejected.fulfill()
    }
    #if canImport(FoundationNetworking)
    delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
      newRequest: proposed, completionHandler: completion)
    #else
    delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response,
      newRequest: proposed, completionHandler: completion)
    #endif
    await fulfillment(of: [rejected], timeout: 10)
  }

  // A provider keeps its response open until the consumer sees the first line.
  // Buffering the entire response would hang here instead of showing a reply.
  func testReceivesLinesBeforeTheResponseFinishes() async throws {
    let fixture = StreamingFixture()
    let session = fixture.session()
    defer { session.invalidateAndCancel(); fixture.remove() }
    let (bytes, response) = try await URLSessionAsyncBytes.open(
      for: URLRequest(url: fixture.url), session: session)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    var lines = bytes.lines.makeAsyncIterator()
    let first = try await lines.next()
    XCTAssertEqual(first, "data: héllo")
    fixture.finish()
    let empty = try await lines.next()
    let last = try await lines.next()
    let end = try await lines.next()
    XCTAssertEqual(empty, "")
    XCTAssertEqual(last, "done")
    XCTAssertNil(end)
  }

  func testCancellationStopsAnOpenResponse() async throws {
    let fixture = StreamingFixture()
    let session = fixture.session()
    defer { session.invalidateAndCancel(); fixture.remove() }
    let (bytes, _) = try await URLSessionAsyncBytes.open(
      for: URLRequest(url: fixture.url), session: session)
    var lines = bytes.lines.makeAsyncIterator()
    _ = try await lines.next()
    bytes.task.cancel()
    await fulfillment(of: [fixture.stopped], timeout: 10)
    do {
      while let _ = try await lines.next() {}
      XCTFail("A cancelled HTTP stream must fail")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .cancelled)
    }
  }

  func testWinHTTPCancellationSuppressesAQueuedFailure() async {
    let reading = expectation(description: "Preparing request body")
    let drained = expectation(description: "Protocol and client released")
    let body = PausedRequestBody(reading: reading)
    defer { body.release.signal() }
    let events = ProtocolEvents(drained: drained)
    var request = URLRequest(url: URL(string: "https://provider.test/")!)
    request.httpBodyStream = body
    var connection: WinHTTPProtocol? = WinHTTPProtocol(
      request: request, cachedResponse: nil, client: CancellationClient(events: events))
    connection?.startLoading()
    await fulfillment(of: [reading], timeout: 10)
    connection?.stopLoading()
    connection = nil
    body.release.signal()
    // Client destruction proves queued work finished; no settling sleep or
    // inverted expectation is needed to establish that delivery has stopped.
    await fulfillment(of: [drained], timeout: 10)
    XCTAssertEqual(events.callbacks, 0, "Late callbacks can crash FoundationNetworking's task registry")
  }
}

// Fail preparation after cancellation, before calling any native API. This
// reproduces late delivery on every platform without a live HTTP provider.
private final class PausedRequestBody: InputStream, @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  let reading: XCTestExpectation
  init(reading: XCTestExpectation) {
    self.reading = reading
    super.init(data: Data())
  }
  override func open() {}
  override func close() {}
  override var streamError: Error? { URLError(.networkConnectionLost) }
  override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
    reading.fulfill()
    _ = release.wait(timeout: .now() + 30)
    return -1
  }
}

private final class ProtocolEvents: @unchecked Sendable {
  let drained: XCTestExpectation
  private let lock = NSLock()
  private var count = 0
  init(drained: XCTestExpectation) { self.drained = drained }
  var callbacks: Int { lock.withLock { count } }
  func record() { lock.withLock { count += 1 } }
}

private final class CancellationClient: NSObject, URLProtocolClient, @unchecked Sendable {
  let events: ProtocolEvents
  init(events: ProtocolEvents) { self.events = events }
  deinit { events.drained.fulfill() }
  func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { events.record() }
  func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { events.record() }
  func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) { events.record() }
  func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { events.record() }
  func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { events.record() }
  func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) { events.record() }
  func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { events.record() }
  func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { events.record() }
}

private final class StreamingFixture: @unchecked Sendable {
  let url = URL(string: "https://stream.test/\(UUID().uuidString)")!
  let stopped = XCTestExpectation(description: "HTTP stream stopped")
  private let lock = NSLock()
  private var connection: StreamingURLProtocol?

  func session() -> URLSession {
    StreamingURLProtocol.register(self)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingURLProtocol.self]
    configuration.timeoutIntervalForRequest = 10
    return URLSession(configuration: configuration)
  }

  func start(_ connection: StreamingURLProtocol) {
    lock.withLock { self.connection = connection }
    connection.client?.urlProtocol(connection, didReceive:
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!,
      cacheStoragePolicy: .notAllowed)
    // Split a multibyte code point across delegate deliveries.
    let prefix = Data("data: héllo\r\n".utf8)
    connection.client?.urlProtocol(connection, didLoad: prefix.prefix(8))
    connection.client?.urlProtocol(connection, didLoad: prefix.dropFirst(8))
  }

  func finish() {
    guard let connection = lock.withLock({ connection }) else { return }
    connection.client?.urlProtocol(connection, didLoad: Data("\r\ndone".utf8))
    connection.client?.urlProtocolDidFinishLoading(connection)
  }

  func remove() { StreamingURLProtocol.remove(url) }
}

private final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var fixtures: [URL: StreamingFixture] = [:]
  static func register(_ fixture: StreamingFixture) {
    lock.withLock { fixtures[fixture.url] = fixture }
  }
  static func remove(_ url: URL) { _ = lock.withLock { fixtures.removeValue(forKey: url) } }
  private var fixture: StreamingFixture? {
    Self.lock.withLock { request.url.flatMap { Self.fixtures[$0] } }
  }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stream.test" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let fixture else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    fixture.start(self)
  }
  override func stopLoading() { fixture?.stopped.fulfill() }
}
