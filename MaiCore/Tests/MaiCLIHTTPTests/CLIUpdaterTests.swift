import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import Testing

@testable import MaiCLI

private final class ReleaseURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let requestURL = request.url!
    let tag = requestURL.pathComponents[1]
    let releaseURL = requestURL.deletingLastPathComponent()
      .appendingPathComponent("tag").appendingPathComponent(tag)
    let response = HTTPURLResponse(
      url: tag == "unexpected-redirect" ? URL(string: "https://other.test/tag/v99.0.0")! : releaseURL,
      statusCode: tag == "missing" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Suite struct CLIUpdaterTests {
  private func check(_ tag: String, current: String) async throws -> (version: String, url: URL)? {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReleaseURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    return try await CLIUpdater.availableUpdate(currentVersion: current,
      releases: URL(string: "https://release.test/\(tag)/releases")!, session: session)
  }

  @Test("Update notices offer only newer numeric releases and link to that release", arguments: [
    ("1.9.0", "v1.10.0", true),
    ("v1.14.4", "1.14.5", true),
    ("1.14.4", "v1.14.4", false),
    ("1.14.5", "v1.14.4", false),
    ("1.14", "v1.14.0", false),
    ("1.14.4", "nightly", false),
    ("1.14.4", "v1..15", false),
    ("1.14.4", "v1.15.0-beta", false),
  ])
  func updateOffer(current: String, tag: String, expected: Bool) async throws {
    let update = try await check(tag, current: current)
    #expect((update != nil) == expected)
    if expected {
      #expect(update?.version == (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag))
      #expect(update?.url.absoluteString == "https://release.test/\(tag)/releases/tag/\(tag)")
    }
  }

  @Test("Failed or unrelated release responses cannot produce update notices", arguments: [
    "missing", "unexpected-redirect",
  ])
  func failedCheck(tag: String) async {
    await #expect(throws: (any Error).self) {
      _ = try await check(tag, current: "1.14.4")
    }
  }
}
