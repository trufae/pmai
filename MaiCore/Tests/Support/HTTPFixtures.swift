import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import MaiCore

func objectSchema(required: [String]) -> JSONValue {
  .object([
    "type": .string("object"),
    "properties": .object(
      Dictionary(uniqueKeysWithValues: required.map { ($0, .object(["type": .string("string")])) })),
    "required": .array(required.map(JSONValue.string)),
  ])
}

func stubSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubURLProtocol.self]
  return URLSession(configuration: configuration)
}

func jsonObject(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func requestBodyData(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var result = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { throw stream.streamError ?? TestError.missingResponse }
    if count == 0 { break }
    result.append(contentsOf: buffer.prefix(count))
  }
  return result
}

func httpResponse(
  _ request: URLRequest,
  status: Int = 200,
  contentType: String,
  body: String,
  headers: [String: String] = [:]
) throws -> (HTTPURLResponse, Data) {
  var allHeaders = headers
  allHeaders["Content-Type"] = contentType
  let url = try #require(request.url)
  let response = try #require(
    HTTPURLResponse(
      url: url,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: allHeaders))
  return (response, Data(body.utf8))
}

func rpc(id: Int?, result: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\(id ?? 0),\"result\":\(result)}"
}

actor ScriptedProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  private var responses: [ProviderResponse]
  /// Errors thrown instead of a response, by zero-based request index.
  private var failures: [Int: any Error]
  private(set) var requests: [ProviderRequest] = []

  init(
    responses: [ProviderResponse],
    capabilities: ProviderCapabilities = [.streaming, .nativeToolCalling, .imageInput],
    failures: [Int: any Error] = [:],
    defaultModel: String? = nil
  ) {
    descriptor = ProviderDescriptor(
      id: "scripted",
      displayName: "Scripted",
      capabilities: capabilities,
      defaultModel: defaultModel)
    self.responses = responses
    self.failures = failures
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    if let failure = failures.removeValue(forKey: requests.count - 1) { throw failure }
    guard !responses.isEmpty else { throw TestError.missingResponse }
    let response = responses.removeFirst()
    if !response.message.reasoning.isEmpty {
      await emit(.reasoningDelta(response.message.reasoning))
    }
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }
}

final class URLRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequest: URLRequest?
  private var storedBody: Data?
  var request: URLRequest? { lock.withLock { storedRequest } }
  var body: Data? { lock.withLock { storedBody } }
  func record(_ request: URLRequest, body: Data) {
    lock.withLock {
      storedRequest = request
      storedBody = body
    }
  }
}

final class MethodRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedMethods: [String] = []
  var methods: [String] { lock.withLock { storedMethods } }
  func record(_ method: String) { lock.withLock { storedMethods.append(method) } }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

  static func install(forHost host: String, _ handler: @escaping Handler) {
    lock.withLock { handlers[host] = handler }
  }

  static func reset(host: String) { lock.withLock { handlers[host] = nil } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let host = try #require(request.url?.host)
      let handler = try Self.lock.withLock { try #require(Self.handlers[host]) }
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

enum TestError: Error { case missingResponse }
