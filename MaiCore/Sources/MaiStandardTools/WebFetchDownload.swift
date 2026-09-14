import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession's Linux bytes(for:) shim buffers the whole response. Use delegate
/// chunks on every platform so both declared and chunked bodies have a real cap.
final class WebFetchDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let limit: Int
  private let lock = NSLock()
  // Only cancellation crosses the serial URLSession delegate queue.
  private var task: URLSessionDataTask?
  private var cancelled = false
  private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
  private var data = Data()
  private var response: HTTPURLResponse?
  private var failure: Error?

  init(limit: Int) { self.limit = limit }

  func fetch(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        lock.withLock {
          self.task = task
          if cancelled { task.cancel() }
        }
        task.resume()
        session.finishTasksAndInvalidate()
      }
    } onCancel: {
      self.lock.withLock {
        self.cancelled = true
        self.task?.cancel()
      }
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    guard let http = response as? HTTPURLResponse else {
      failure = URLError(.badServerResponse)
      completionHandler(.cancel)
      return
    }
    self.response = http
    if !(200..<300).contains(http.statusCode) {
      // The caller needs the status, not a potentially enormous error page.
      completionHandler(.cancel)
    } else if response.expectedContentLength > Int64(limit) {
      failure = tooLarge
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil else { return }
    guard data.count <= limit - self.data.count else {
      failure = tooLarge
      dataTask.cancel()
      return
    }
    self.data.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let continuation else { return }
    self.continuation = nil
    let cancelled = lock.withLock { self.task = nil; return self.cancelled }
    if cancelled {
      continuation.resume(throwing: CancellationError())
    } else if let response, !(200..<300).contains(response.statusCode) {
      continuation.resume(returning: (Data(), response))
    } else if let error = failure ?? error {
      continuation.resume(throwing: error)
    } else if let response {
      continuation.resume(returning: (data, response))
    } else {
      continuation.resume(throwing: URLError(.badServerResponse))
    }
  }

  private var tooLarge: NSError {
    NSError(domain: "WebFetch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fetched content exceeds the \(limit)-byte download limit; use a smaller resource or a server-side range/query."])
  }
}
