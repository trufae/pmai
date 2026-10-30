import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming compatibility for FoundationNetworking, which lacks `bytes(for:)`.
/// Keep the implementation available on Darwin so its lifecycle can be tested
/// without a Linux or Android device.
public struct URLSessionAsyncBytes: AsyncSequence, Sendable {
  public typealias Element = UInt8
  private let chunks: AsyncThrowingStream<Data, Error>
  private let lifetime: StreamLifetime

  public struct AsyncIterator: AsyncIteratorProtocol {
    private var chunks: AsyncThrowingStream<Data, Error>.Iterator
    private var chunk = Data()
    private var index = 0
    private let lifetime: StreamLifetime

    fileprivate init(_ bytes: URLSessionAsyncBytes) {
      chunks = bytes.chunks.makeAsyncIterator()
      lifetime = bytes.lifetime
    }

    public mutating func next() async throws -> UInt8? {
      try Task.checkCancellation()
      while index == chunk.count {
        guard let next = try await chunks.next() else {
          try Task.checkCancellation()
          return nil
        }
        chunk = next
        index = 0
      }
      defer { index += 1 }
      return chunk[chunk.startIndex + index]
    }
  }

  public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(self) }
  public var task: URLSessionTask { lifetime.task }
  public var lines: Lines { Lines(bytes: self) }

  public struct Lines: AsyncSequence, Sendable {
    public typealias Element = String
    fileprivate let bytes: URLSessionAsyncBytes

    public struct AsyncIterator: AsyncIteratorProtocol {
      fileprivate var bytes: URLSessionAsyncBytes.AsyncIterator

      public mutating func next() async throws -> String? {
        var line = Data()
        while let byte = try await bytes.next() {
          if byte == 10 {
            if line.last == 13 { line.removeLast() }
            return String(decoding: line, as: UTF8.self)
          }
          line.append(byte)
        }
        return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
      }
    }

    public func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(bytes: bytes.makeAsyncIterator())
    }
  }

  static func open(
    for request: URLRequest, session: URLSession, delegate: (any URLSessionTaskDelegate)? = nil
  ) async throws -> (Self, URLResponse) {
    let body = AsyncThrowingStream<Data, Error>.makeStream()
    let headers = AsyncThrowingStream<URLResponse, Error>.makeStream()
    let proxy = StreamingDelegate(
      body: body.continuation, headers: headers.continuation,
      forward: delegate ?? session.delegate as? any URLSessionTaskDelegate,
      sessionForward: session.delegate)
    let streaming = URLSession(configuration: session.configuration, delegate: proxy, delegateQueue: nil)
    let task = streaming.dataTask(with: request)
    let lifetime = StreamLifetime(session: streaming, task: task)
    body.continuation.onTermination = { @Sendable [weak task] _ in task?.cancel() }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      task.resume()
      var iterator = headers.stream.makeAsyncIterator()
      guard let response = try await iterator.next() else { throw URLError(.badServerResponse) }
      try Task.checkCancellation()
      return (Self(chunks: body.stream, lifetime: lifetime), response)
    } onCancel: {
      task.cancel()
    }
  }
}

private final class StreamLifetime: @unchecked Sendable {
  let session: URLSession
  let task: URLSessionTask

  deinit { session.invalidateAndCancel() }

  init(session: URLSession, task: URLSessionTask) {
    self.session = session
    self.task = task
  }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let body: AsyncThrowingStream<Data, Error>.Continuation
  let headers: AsyncThrowingStream<URLResponse, Error>.Continuation
  let forward: (any URLSessionTaskDelegate)?
  let sessionForward: (any URLSessionDelegate)?

  init(
    body: AsyncThrowingStream<Data, Error>.Continuation,
    headers: AsyncThrowingStream<URLResponse, Error>.Continuation,
    forward: (any URLSessionTaskDelegate)?, sessionForward: (any URLSessionDelegate)?
  ) {
    self.body = body
    self.headers = headers
    self.forward = forward
    self.sessionForward = sessionForward
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    headers.yield(response)
    headers.finish()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    body.yield(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    headers.finish(throwing: error ?? URLError(.badServerResponse))
    body.finish(throwing: error)
    session.finishTasksAndInvalidate()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let forward else { completionHandler(request); return }
    #if canImport(FoundationNetworking)
    forward.urlSession(session, task: task, willPerformHTTPRedirection: response,
      newRequest: request, completionHandler: completionHandler)
    #else
    if let redirect = forward.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) {
      redirect(session, task, response, request, completionHandler)
    } else { completionHandler(request) }
    #endif
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard let sessionForward else { completionHandler(.performDefaultHandling, nil); return }
    #if canImport(FoundationNetworking)
    sessionForward.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    #else
    if let authenticate = sessionForward.urlSession(_:didReceive:completionHandler:) {
      authenticate(session, challenge, completionHandler)
    } else { completionHandler(.performDefaultHandling, nil) }
    #endif
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard let forward else { completionHandler(.performDefaultHandling, nil); return }
    #if canImport(FoundationNetworking)
    forward.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    #else
    if let authenticate = forward.urlSession(_:task:didReceive:completionHandler:) {
      authenticate(session, task, challenge, completionHandler)
    } else { completionHandler(.performDefaultHandling, nil) }
    #endif
  }
}

#if canImport(FoundationNetworking)
public extension URLSession {
  typealias AsyncBytes = URLSessionAsyncBytes

  func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
    try await AsyncBytes.open(for: request, session: self)
  }

  func bytes(
    for request: URLRequest, delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (AsyncBytes, URLResponse) {
    try await AsyncBytes.open(for: request, session: self, delegate: delegate)
  }
}
#endif
