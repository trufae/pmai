import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Windows FoundationNetworking can stop uploading when a socket's send buffer
/// fills (swift-corelibs-foundation#5532). WinHTTP and curl bypass that event loop.
public enum ProviderHTTPTransport: String, Sendable {
  case automatic = "auto"
  case urlSession = "urlsession"
  case curl
  case winHTTP = "winhttp"

  public var resolved: Self {
    guard self == .automatic else { return self }
    #if os(Windows)
    return .winHTTP
    #else
    return .urlSession
    #endif
  }

  public func makeSession() -> URLSession {
    guard resolved != .urlSession else { return .shared }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = resolved == .winHTTP ? [WinHTTPProtocol.self] : [CurlHTTPProtocol.self]
    return URLSession(configuration: configuration)
  }
}

/// Retain URLSession's streaming/delegate interface while bypassing its socket
/// implementation. curl never follows redirects itself; the provider's existing
/// same-origin redirect policy is applied before issuing another request.
final class CurlHTTPProtocol: URLProtocol, @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var cancelled = false
  #if os(macOS) || os(Linux) || os(Windows)
  private var process: Process?
  #endif

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    #if os(macOS) || os(Linux) || os(Windows)
    // corelibs Foundation marks URLProtocol non-Sendable; access is serialized here.
    nonisolated(unsafe) let owner = self
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        var next = owner.request
        for redirectCount in 0...ProviderRedirectPolicy.maximumRedirectCount {
          if owner.isCancelled { return }
          if let redirected = try owner.transfer(next) {
            guard redirectCount < ProviderRedirectPolicy.maximumRedirectCount else {
              throw URLError(.httpTooManyRedirects)
            }
            next = redirected
          } else {
            owner.notifyClient { $0.urlProtocolDidFinishLoading(owner) }
            return
          }
        }
      } catch {
        owner.notifyClient { $0.urlProtocol(owner, didFailWithError: error) }
      }
    }
    #else
    client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    #endif
  }

  override func stopLoading() {
    lock.withLock {
      cancelled = true
      #if os(macOS) || os(Linux) || os(Windows)
      if let process, process.isRunning { process.terminate() }
      #endif
    }
  }

  private var isCancelled: Bool { lock.withLock { cancelled } }

  private func notifyClient(_ body: (any URLProtocolClient) -> Void) {
    // Cancellation must wait for in-flight delivery and prevent later calls.
    // The client can reenter stopLoading, hence the recursive lock.
    lock.withLock {
      guard !cancelled, let client else { return }
      body(client)
    }
  }

  #if os(macOS) || os(Linux) || os(Windows)
  private func transfer(_ incoming: URLRequest) throws -> URLRequest? {
    var request = incoming
    guard let url = request.url else { throw URLError(.badURL) }
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("pmai-http-\(UUID().uuidString)")
    try files.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: directory) }
    let errorsURL = directory.appendingPathComponent("stderr")
    guard files.createFile(atPath: errorsURL.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    let errors = try FileHandle(forWritingTo: errorsURL)
    defer { try? errors.close() }

    var config = [
      "url = \(Self.quoted(url.absoluteString))",
      "request = \(Self.quoted(request.httpMethod ?? "GET"))",
      "connect-timeout = \(min(30, max(1, request.timeoutInterval)))",
      "max-time = \(max(1, request.timeoutInterval))",
    ]
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
      guard !name.contains(where: { $0 == "\r" || $0 == "\n" }),
        !value.contains(where: { $0 == "\r" || $0 == "\n" })
      else { throw URLError(.badURL) }
      config.append("header = \(Self.quoted(name + ": " + value))")
    }
    // Keep credentials off the command line and body bytes intact, including
    // multipart audio and NULs. Only the request body uses a private temp file.
    if let body = try ProviderHTTPTransport.body(of: request) {
      request.httpBodyStream = nil
      request.httpBody = body
      let bodyURL = directory.appendingPathComponent("body")
      guard files.createFile(atPath: bodyURL.path, contents: body,
        attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
      config.append("data-binary = \(Self.quoted("@" + bodyURL.path))")
    }

    let child = Process()
    let input = Pipe()
    let output = Pipe()
    child.executableURL = Self.curlURL
    // -q must come first: do not load a personal curlrc. Do not use --location,
    // --insecure, automatic retries, or a shell to interpret request fields.
    child.arguments = ["-q", "--config", "-", "--silent", "--show-error",
      "--no-buffer", "--include", "--suppress-connect-headers", "--globoff", "--compressed"]
    child.standardInput = input
    child.standardOutput = output
    child.standardError = errors
    try lock.withLock {
      guard !cancelled else { throw URLError(.cancelled) }
      process = child
      try child.run()
    }
    defer {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
      lock.withLock { process = nil }
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
    }
    try input.fileHandleForWriting.write(contentsOf: Data((config.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()

    var pending = Data()
    var receivedHeaders = false
    while true {
      // read(upToCount:) can wait for its entire requested count on pipes.
      // availableData returns the next available block, preserving live SSE.
      let chunk = output.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      if isCancelled { throw URLError(.cancelled) }
      if receivedHeaders {
        notifyClient { $0.urlProtocol(self, didLoad: chunk) }
        continue
      }
      pending.append(chunk)
      while let boundary = pending.range(of: Data("\r\n\r\n".utf8)) {
        let header = String(decoding: pending[..<boundary.lowerBound], as: UTF8.self)
        pending.removeSubrange(..<boundary.upperBound)
        let lines = header.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"),
          let status = Int(statusLine[1]) else { throw URLError(.badServerResponse) }
        if (100..<200).contains(status) { continue }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":") else { continue }
          headers[String(line[..<colon])] = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status,
          httpVersion: String(statusLine[0].dropFirst(5)), headerFields: headers)
        else { throw URLError(.badServerResponse) }
        if let redirected = ProviderRedirectPolicy.redirectedRequest(originalRequest: request, response: response)
        { return redirected }
        receivedHeaders = true
        notifyClient { $0.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        if !pending.isEmpty { notifyClient { $0.urlProtocol(self, didLoad: pending) } }
        pending.removeAll()
        break
      }
      guard receivedHeaders || pending.count <= 65_536 else { throw URLError(.badServerResponse) }
    }
    child.waitUntilExit()
    if isCancelled { throw URLError(.cancelled) }
    guard child.terminationStatus == 0 else {
      let detail = (try? Data(contentsOf: errorsURL)).map { String(decoding: $0.prefix(4_096), as: UTF8.self) } ?? ""
      let code: URLError.Code?
      switch child.terminationStatus {
      case 5, 6: code = .cannotFindHost
      case 7: code = .cannotConnectToHost
      case 18, 55, 56: code = .networkConnectionLost
      case 28: code = .timedOut
      case 35: code = .secureConnectionFailed
      case 51, 60: code = .serverCertificateUntrusted
      case 52: code = .badServerResponse
      default: code = nil
      }
      if let code { throw URLError(code, userInfo: [NSLocalizedDescriptionKey: detail]) }
      throw NSError(domain: "pmai.curl", code: Int(child.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: detail.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
    guard receivedHeaders else { throw URLError(.badServerResponse) }
    return nil
  }

  private static var curlURL: URL {
    #if os(Windows)
    let root = ProcessInfo.processInfo.environment.first { $0.key.lowercased() == "systemroot" }?.value ?? "C:\\Windows"
    return URL(fileURLWithPath: root).appendingPathComponent("System32/curl.exe")
    #else
    return URL(fileURLWithPath: "/usr/bin/curl")
    #endif
  }

  private static func quoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\t", with: "\\t") + "\""
  }

  #endif
}

extension ProviderHTTPTransport {
  static func body(of request: URLRequest) throws -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 32_768)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count == 0 { return result }
      guard count > 0 else { throw stream.streamError ?? URLError(.cannotOpenFile) }
      result.append(contentsOf: buffer.prefix(count))
    }
  }
}
