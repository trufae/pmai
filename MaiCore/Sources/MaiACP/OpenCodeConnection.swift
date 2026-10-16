import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum RemoteAgentBackend: String, Codable, Sendable {
  case acp
  case openCode
}

/// OpenCode's HTTP API and ACP use different credentials and transports.
public struct OpenCodeConnection: Sendable {
  public var name: String
  public var url: URL
  public var token: String
  public var cwd: String

  public init(name: String = "OpenCode", url: URL, token: String, cwd: String = "") throws {
    try OpenCodeHTTP.validate(url)
    guard !name.isEmpty, name.count <= 200, !token.isEmpty, token.count <= 4096,
      !token.contains(where: \.isWhitespace), cwd.isEmpty || cwd.hasPrefix("/")
    else { throw JSONRPCError.invalidParams("Invalid OpenCode connection") }
    self.name = name
    self.url = url
    self.token = token
    self.cwd = cwd
  }
}

/// `opencode pair` prints /auth/connect/:code links, but its QR contains {code, urls}.
/// Reference: anomalyco/opencode, packages/app/src/servers/connect/pairing.ts.
public struct OpenCodePairingLink: Sendable, Equatable {
  public let urls: [URL]
  public let code: String

  public static func parse(_ text: String) throws -> Self {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let invalid = JSONRPCError.invalidParams(
      "Scan or paste a pmai connection or an OpenCode pairing link from `opencode pair --remote`.")
    guard text.utf8.count <= 16384 else { throw invalid }
    let code: String
    var urls: [URL] = []
    if text.hasPrefix("{") {
      struct Payload: Decodable {
        let code: String
        let urls: [String]
      }
      guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8)),
        !payload.urls.isEmpty, payload.urls.count <= 16
      else { throw invalid }
      code = payload.code
      for address in payload.urls {
        guard let url = URL(string: address) else { throw invalid }
        try OpenCodeHTTP.validate(url)
        if !urls.contains(url) { urls.append(url) }
      }
    } else {
      guard var components = URLComponents(string: text), let url = components.url else {
        throw invalid
      }
      try OpenCodeHTTP.validate(url)
      let prefix = "/auth/connect/"
      guard components.percentEncodedPath.hasPrefix(prefix) else { throw invalid }
      code = String(components.percentEncodedPath.dropFirst(prefix.count))
      components.path = ""
      guard let base = components.url else { throw invalid }
      urls = [base]
    }
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard !code.isEmpty, code.utf8.count <= 4096,
      code.unicodeScalars.allSatisfy(allowed.contains)
    else { throw invalid }
    return Self(urls: urls, code: code)
  }

  public func redeem(configuration: URLSessionConfiguration = .ephemeral) async throws
    -> OpenCodeConnection
  {
    var expired = false
    // Preserve OpenCode's preferred address (the tunnel for --remote). Sequential
    // attempts also avoid racing a single-use code against our own requests.
    for url in urls {
      try Task.checkCancellation()
      let http = OpenCodeHTTP(url: url, token: nil, configuration: configuration)
      defer { http.close() }
      do {
        let result = try await http.request(["auth", "connect", code], timeout: 5)
        guard let token = result.objectValue?["token"]?.stringValue else {
          throw JSONRPCError.invalidParams("OpenCode returned an invalid pairing response")
        }
        return try OpenCodeConnection(url: url, token: token)
      } catch OpenCodeHTTP.Failure.unauthorized {
        expired = true
      } catch {
        if Task.isCancelled { throw CancellationError() }
      }
    }
    throw JSONRPCError.invalidParams(
      expired
        ? "This OpenCode pairing link expired or was already used. Run `opencode pair --remote` again and scan the new QR."
        : "Could not reach the OpenCode server. Check its connection and try the pairing link again."
    )
  }
}

/// No shared cookies, automatic credentials, or redirects to another server.
final class OpenCodeHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  enum Failure: Error { case unauthorized }
  let url: URL
  private let token: String?
  private var session: URLSession!

  init(url: URL, token: String?, configuration: URLSessionConfiguration = .ephemeral) {
    self.url = url
    self.token = token
    super.init()
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  static func validate(_ url: URL) throws {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil
    else {
      throw JSONRPCError.invalidParams(
        "Use an HTTP or HTTPS OpenCode URL without embedded credentials, query parameters, or fragments."
      )
    }
  }

  func request(
    _ path: [String], method: String = "GET", body: JSONValue? = nil,
    query: [URLQueryItem] = [], timeout: TimeInterval = 30
  ) async throws -> JSONValue {
    var url = url
    for component in path {
      // IDs from the server must remain a single path component.
      guard !component.isEmpty, component != ".", component != "..",
        !component.contains("/"), !component.contains("\\")
      else { throw JSONRPCError.invalidParams("Invalid OpenCode resource identifier") }
      url.appendPathComponent(component)
    }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.queryItems = query }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token {
      request.setValue(
        "Basic " + Data("opencode:\(token)".utf8).base64EncodedString(),
        forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if response.statusCode == 401 {
      if token == nil { throw Failure.unauthorized }
      throw JSONRPCError.invalidParams(
        "OpenCode authentication expired or was revoked. Pair this host again with a new QR.")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw JSONRPCError.internalError("OpenCode request failed (HTTP \(response.statusCode)).")
    }
    if data.isEmpty { return .null }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  func close() { session.invalidateAndCancel() }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
