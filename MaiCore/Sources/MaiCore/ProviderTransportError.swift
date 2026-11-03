import Foundation

/// A connection failure with where it happened, so the debug log shows the
/// host, whether a response had started, and how long the call ran.
public struct ProviderTransportError: LocalizedError, Sendable {
  public let host: String
  /// HTTP status of the response, or nil when the connection failed first.
  public let statusCode: Int?
  public let elapsed: TimeInterval
  public let code: Int
  public let message: String

  public init(
    host: String, statusCode: Int?, elapsed: TimeInterval, code: Int, message: String
  ) {
    self.host = host
    self.statusCode = statusCode
    self.elapsed = elapsed
    self.code = code
    self.message = message
  }

  public var errorDescription: String? {
    let phase = statusCode.map { "after HTTP \($0) response began" } ?? "before any response"
    return "\(message) (\(host), \(phase), \(String(format: "%.1f", elapsed))s)"
  }

  /// A connection cut off before any response, again at the same elapsed
  /// time, is a fixed cutoff between client and server (a proxy, firewall or
  /// server timeout); resending the same request only fails the same way.
  /// Fast failures such as a refused connection may clear and stay retried.
  public func repeats(_ previous: ProviderTransportError) -> Bool {
    guard statusCode == nil, previous.statusCode == nil, code == previous.code,
      host == previous.host, elapsed >= 1, previous.elapsed >= 1
    else { return false }
    return abs(elapsed - previous.elapsed) <= max(1, elapsed * 0.1)
  }
}
