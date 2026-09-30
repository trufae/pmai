import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// One JSON-RPC message per WebSocket text message. Credentials are sent only
/// in the upgrade header; redirects are refused so they cannot change hosts.
public final class WebSocketJSONRPCTransport: NSObject, JSONRPCTransport,
  URLSessionTaskDelegate, @unchecked Sendable
{
  private let lock = NSLock()
  private var closed = false
  private var detail = ""
  private var session: URLSession!
  private var socket: URLSessionWebSocketTask!
  private var tasks: [Task<Void, Never>] = []
  // Session replay may arrive as a burst; never discard historical updates
  // while the UI is rendering them. URLSession bounds each message separately.
  private let incoming = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .unbounded)
  private let outgoing = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(256))

  public init(url: URL, bearerToken: String? = nil) throws {
    try ACPRemoteConnection.validate(url: url)
    super.init()
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    if let bearerToken {
      guard !bearerToken.contains(where: { $0.isNewline || $0 == "\r" }) else {
        throw JSONRPCError.invalidParams("Invalid gateway token")
      }
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = 16 * 1024 * 1024
    socket.resume()
    let socket = socket!
    let startedTasks: [Task<Void, Never>] = [
      Task { [weak self, outgoing] in
        do {
          for await text in outgoing.stream { try await socket.send(.string(text)) }
        } catch { self?.fail(error) }
      },
      Task { [weak self, incoming] in
        do {
          while !Task.isCancelled {
            let frame = try await socket.receive()
            guard case .string(let text) = frame,
              let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data)
            else {
              throw JSONRPCError.invalidParams("Expected a JSON-RPC WebSocket text message")
            }
            incoming.continuation.yield(message)
          }
        } catch { self?.fail(error) }
      },
      Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(20)) } catch { return }
          self?.ping()
        }
      },
    ]
    lock.withLock {
      if closed { for task in startedTasks { task.cancel() } } else { tasks = startedTasks }
    }
  }

  public var isRunning: Bool { lock.withLock { !closed } }
  public var recentErrorOutput: String { lock.withLock { detail } }
  public func messages() -> AsyncStream<JSONRPCMessage> { incoming.stream }

  public func send(_ message: JSONRPCMessage) throws {
    guard isRunning else { throw JSONRPCTransportError.closed }
    let text = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    switch outgoing.continuation.yield(text) {
    case .enqueued: return
    default:
      close()
      throw JSONRPCTransportError.closed
    }
  }

  public func close() {
    let pending = lock.withLock { () -> [Task<Void, Never>]? in
      if closed { return nil }
      closed = true
      let pending = tasks
      tasks.removeAll()
      return pending
    }
    guard let pending else { return }
    outgoing.continuation.finish()
    incoming.continuation.finish()
    for task in pending { task.cancel() }
    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()
  }

  private func fail(_ error: Error) {
    lock.withLock { if !closed { detail = error.localizedDescription } }
    close()
  }

  private func ping() {
    let timeout = DispatchWorkItem { [weak self] in
      self?.fail(JSONRPCTransportError.timedOut("WebSocket heartbeat"))
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
    socket.sendPing { [weak self] error in
      timeout.cancel()
      if let error { self?.fail(error) }
    }
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

/// Exported by the gateway for import by the phone. Unlike a Tailcat enrollment
/// invite, this profile contains a reusable gateway credential.
public struct ACPRemoteConnection: Codable, Equatable, Sendable {
  public var version: Int = 1
  public var name: String
  public var url: URL
  public var token: String
  public var cwd: String

  public init(name: String, url: URL, token: String, cwd: String) throws {
    self.name = name
    self.url = url
    self.token = token
    self.cwd = cwd
    try validate()
  }

  public func validate() throws {
    try Self.validate(url: url)
    guard version == 1, !name.isEmpty, name.count <= 200,
      !token.isEmpty, token.count <= 4096, !token.contains(where: { $0.isWhitespace }),
      cwd.hasPrefix("/"), cwd.count <= 4096
    else {
      throw JSONRPCError.invalidParams("Invalid ACP gateway connection profile")
    }
  }

  public static func validate(url: URL) throws {
    guard ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil
    else {
      throw JSONRPCError.invalidParams(
        "Use a ws:// or wss:// gateway URL without credentials or query parameters")
    }
  }

  public func uri() throws -> String {
    try validate()
    return "pmai-acp://connect/"
      + (try JSONEncoder().encode(self)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
  }

  public static func parse(_ uri: String) throws -> Self {
    let prefix = "pmai-acp://connect/"
    guard uri.hasPrefix(prefix), uri.utf8.count <= 16384,
      let data = Data(
        base64Encoded: String(uri.dropFirst(prefix.count))
          .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
    else {
      throw JSONRPCError.invalidParams("Invalid ACP gateway connection QR")
    }
    let result = try JSONDecoder().decode(Self.self, from: data)
    try result.validate()
    return result
  }
}
