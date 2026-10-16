import Foundation

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// A short-lived listener bound exclusively to IPv4 loopback on an available port.
#if os(Windows)
  public final class ChatGPTCallbackListener: Sendable {
    public let redirectURI = URL(string: "http://127.0.0.1/auth/callback")!
    public init() throws {
      throw ChatGPTError.message("ChatGPT browser sign-in currently requires a POSIX host or iOS.")
    }
    public func cancel() {}
    public func callback(state: String, returnToApp: URL? = nil, timeout: TimeInterval = 300)
      async throws -> URL
    {
      throw ChatGPTError.signInRequired
    }
  }
#else
  public final class ChatGPTCallbackListener: @unchecked Sendable {
    public let redirectURI: URL
    private let descriptor: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var waiting = false

    public init() throws {
      #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
      #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
      #endif
      guard fd >= 0 else {
        throw ChatGPTError.message("Could not start the ChatGPT callback listener.")
      }
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      address.sin_port = 0
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      var size = socklen_t(MemoryLayout<sockaddr_in>.size)
      let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
      }
      guard bound == 0, named == 0, listen(fd, 4) == 0,
        fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
      else {
        _ = close(fd)
        throw ChatGPTError.message("Could not bind the ChatGPT callback to 127.0.0.1.")
      }
      descriptor = fd
      redirectURI = URL(
        string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/auth/callback")!
    }

    deinit { _ = close(descriptor) }

    public func cancel() { lock.withLock { cancelled = true } }

    public func callback(state: String, returnToApp: URL? = nil, timeout: TimeInterval = 300)
      async throws -> URL
    {
      guard
        lock.withLock({
          if waiting { return false }
          waiting = true
          return true
        })
      else {
        throw ChatGPTError.message("This ChatGPT sign-in listener has already been used.")
      }
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
              continuation.resume(
                returning: try receive(state: state, returnToApp: returnToApp, timeout: timeout))
            } catch { continuation.resume(throwing: error) }
          }
        }
      } onCancel: {
        self.cancel()
      }
    }

    private func receive(state: String, returnToApp: URL?, timeout: TimeInterval) throws -> URL {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if lock.withLock({ cancelled }) { throw CancellationError() }
        var descriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 200) > 0 else { continue }
        let client = accept(self.descriptor, nil, nil)
        guard client >= 0 else { continue }
        let result = handle(client, state: state, returnToApp: returnToApp)
        _ = close(client)
        if let result { return result }
      }
      throw ChatGPTError.message("ChatGPT sign-in timed out. Try again.")
    }

    private func handle(_ client: Int32, state: String, returnToApp: URL?) -> URL? {
      // Darwin inherits O_NONBLOCK from the listening socket. Wait for the
      // browser's headers instead of closing a just-accepted connection.
      let flags = fcntl(client, F_GETFL, 0)
      guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return nil }
      var timeout = timeval(tv_sec: 1, tv_usec: 0)
      _ = setsockopt(
        client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      _ = setsockopt(
        client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      #endif
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 2048)
      let deadline = Date().addingTimeInterval(2)
      while data.count < 16_384, Date() < deadline {
        let count = recv(client, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        data.append(contentsOf: buffer.prefix(count))
        if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
      }
      let firstLine =
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
      let fields = firstLine.split(separator: " ")
      let candidate =
        fields.count == 3 && fields[0] == "GET" && fields[1].hasPrefix("/auth/callback?")
        ? URL(string: String(fields[1]), relativeTo: redirectURI)?.absoluteURL : nil
      let query =
        candidate.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        ?? []
      let valid =
        candidate?.path == redirectURI.path && query.filter { $0.name == "state" }.count == 1
        && query.first(where: { $0.name == "state" })?.value == state
      let body =
        valid ? "You can return to pmai. Completing ChatGPT sign-in…" : "Invalid sign-in callback."
      var response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\n"
      if valid, let returnToApp, returnToApp.scheme == "pocketmai" {
        response = "HTTP/1.1 302 Found\r\nLocation: \(returnToApp.absoluteString)\r\n"
      }
      response +=
        "Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
      let bytes = Array(response.utf8)
      bytes.withUnsafeBytes { pointer in
        guard let baseAddress = pointer.baseAddress else { return }
        #if os(Linux) || os(Android)
          _ = send(client, baseAddress, bytes.count, Int32(MSG_NOSIGNAL))
        #else
          _ = send(client, baseAddress, bytes.count, 0)
        #endif
      }
      return valid ? candidate : nil
    }
  }
#endif
