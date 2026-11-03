import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CMaiWinHTTP

/// Adapt the native async Windows HTTP API to the provider's URLSession streams.
/// State and native API calls are confined to queue. Native callbacks only copy
/// data and enqueue work, so even synchronous completions cannot recurse.
final class WinHTTPProtocol: URLProtocol, @unchecked Sendable {
  private let queue = DispatchQueue(label: "pmai.winhttp")
  private var native: OpaquePointer?
  private var generation = 0
  private var currentRequest: URLRequest?
  private var redirects = 0
  private var deadline: DispatchSourceTimer?
  private var finished = false

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    queue.async { [self] in
      guard !self.finished else { return }
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now() + max(0.001, self.request.timeoutInterval))
      timer.setEventHandler { [weak self] in self?.finish(error: URLError(.timedOut)) }
      self.deadline = timer
      timer.resume()
      self.start(self.request)
    }
  }

  override func stopLoading() {
    queue.async { self.finish(notify: false) }
  }

  private func start(_ incoming: URLRequest) {
    guard !finished else { return }
    do {
      var request = incoming
      guard let url = request.url, let host = url.host, !host.isEmpty,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
        let port = UInt16(exactly: url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)), port > 0
      else { throw URLError(.badURL) }
      var path = components.percentEncodedPath
      if path.isEmpty { path = "/" }
      if let query = components.percentEncodedQuery { path += "?" + query }
      let method = request.httpMethod ?? "GET"
      var headers = ""
      for (name, value) in request.allHTTPHeaderFields ?? [:] {
        guard !name.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }),
          !value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
        else { throw URLError(.badURL) }
        headers += name + ": " + value + "\r\n"
      }
      guard !method.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw URLError(.badURL) }
      let body = try ProviderHTTPTransport.body(of: request) ?? Data()
      guard let count = UInt32(exactly: body.count) else { throw URLError(.dataLengthExceedsMaximum) }
      request.httpBodyStream = nil
      request.httpBody = body
      currentRequest = request
      generation += 1
      let context = Unmanaged.passRetained(CallbackContext(owner: self, generation: generation))
      var error: UInt32 = 0
      let timeout = Int32(min(Double(Int32.max), max(1, request.timeoutInterval * 1000)))
      native = mai_winhttp_create(host, port, url.scheme?.lowercased() == "https" ? 1 : 0,
        method, path, headers, timeout, Self.callback, context.toOpaque(), &error)
      guard let native else {
        context.release() // Failed setup never installs a live callback.
        throw Self.transportError(error)
      }
      let sendError = body.withUnsafeBytes { mai_winhttp_send(native, $0.baseAddress, count) }
      if sendError != 0 { throw Self.transportError(sendError) }
    } catch { finish(error: error) }
  }

  private final class CallbackContext: @unchecked Sendable {
    let owner: WinHTTPProtocol
    let generation: Int
    init(owner: WinHTTPProtocol, generation: Int) {
      self.owner = owner
      self.generation = generation
    }
  }

  private static let callback: MaiWinHTTPCallback = { context, event, bytes, count, error in
    guard let context else { return }
    let reference = Unmanaged<CallbackContext>.fromOpaque(context)
    if event == MAI_WINHTTP_CLOSED {
      // The native request has released all I/O buffers and will never call us
      // again. Until this notification, cancellation must retain its context.
      reference.release()
      return
    }
    let value = reference.takeUnretainedValue()
    let data = event == MAI_WINHTTP_READ && count > 0
      ? bytes.map { Data(bytes: $0, count: Int(count)) } : nil
    value.owner.queue.async {
      value.owner.receive(event, data: data, count: count, error: error, generation: value.generation)
    }
  }

  private func receive(_ event: Int32, data: Data?, count: UInt32, error: UInt32, generation: Int) {
    guard !finished, generation == self.generation, let native else { return }
    do {
      let result: UInt32
      switch event {
      case Int32(MAI_WINHTTP_SENT): result = mai_winhttp_receive(native)
      case Int32(MAI_WINHTTP_HEADERS):
        try receivedHeaders(native)
        return
      case Int32(MAI_WINHTTP_AVAILABLE):
        // Query before reading: a large direct ReadData can wait to fill its
        // buffer and hold back SSE output. A zero-byte availability result is
        // confirmed by ReadData's EOF completion.
        result = mai_winhttp_read(native, min(32_768, max(1, count)))
      case Int32(MAI_WINHTTP_READ):
        if count == 0 { finish(); return }
        if let data { client?.urlProtocol(self, didLoad: data) }
        result = mai_winhttp_query_available(native)
      case Int32(MAI_WINHTTP_ERROR): throw Self.transportError(error)
      default: return
      }
      if result != 0 { throw Self.transportError(result) }
    } catch { finish(error: error) }
  }

  private func receivedHeaders(_ native: OpaquePointer) throws {
    var error: UInt32 = 0
    guard let raw = mai_winhttp_headers(native, &error) else { throw Self.transportError(error) }
    defer { mai_winhttp_free(raw) }
    let lines = String(cString: raw).components(separatedBy: "\r\n")
    let statusLine = lines[0].split(separator: " ", maxSplits: 2)
    guard let request = currentRequest, let url = request.url,
      statusLine.count >= 2, let status = Int(statusLine[1])
    else { throw URLError(.badServerResponse) }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[String(line[..<colon])] = String(line[line.index(after: colon)...])
        .trimmingCharacters(in: .whitespaces)
    }
    guard let response = HTTPURLResponse(url: url, statusCode: status,
      httpVersion: String(statusLine[0].dropFirst(5)), headerFields: headers)
    else { throw URLError(.badServerResponse) }
    if let redirected = ProviderRedirectPolicy.redirectedRequest(originalRequest: request, response: response) {
      guard redirects < ProviderRedirectPolicy.maximumRedirectCount else { throw URLError(.httpTooManyRedirects) }
      redirects += 1
      closeNative()
      start(redirected)
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let result = mai_winhttp_query_available(native)
    if result != 0 { throw Self.transportError(result) }
  }

  private func closeNative() {
    if let native {
      self.native = nil
      mai_winhttp_close(native)
    }
  }

  private func finish(error: Error? = nil, notify: Bool = true) {
    guard !finished else { return }
    finished = true
    deadline?.cancel()
    deadline = nil
    closeNative()
    currentRequest = nil
    if notify {
      if let error { client?.urlProtocol(self, didFailWithError: error) }
      else { client?.urlProtocolDidFinishLoading(self) }
    }
  }

  private static func transportError(_ error: UInt32) -> URLError {
    let code: URLError.Code
    switch error {
    case 50: code = .unsupportedURL
    case 12002: code = .timedOut
    case 12005, 12006: code = .badURL
    case 12007: code = .cannotFindHost
    case 12017: code = .cancelled
    case 12029: code = .cannotConnectToHost
    case 12030: code = .networkConnectionLost
    case 12037: code = .serverCertificateHasBadDate
    case 12038: code = .serverCertificateUntrusted
    case 12045: code = .serverCertificateHasUnknownRoot
    case 12169, 12170, 12175, 12179: code = .serverCertificateUntrusted
    case 12157: code = .secureConnectionFailed
    default: code = .badServerResponse
    }
    return URLError(code, userInfo: [NSLocalizedDescriptionKey:
      error == 50 ? "WinHTTP is only available on Windows." : "WinHTTP request failed (Windows error \(error))."])
  }
}
