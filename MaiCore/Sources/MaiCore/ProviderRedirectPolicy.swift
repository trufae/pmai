import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ProviderRedirectPolicy {
  static let maximumRedirectCount = 5

  static func redirectedRequest(
    originalRequest: URLRequest,
    response: HTTPURLResponse,
    proposedRequest: URLRequest
  ) -> URLRequest? {
    guard sameOrigin(originalRequest.url, proposedRequest.url) else { return nil }

    var redirectedRequest = proposedRequest
    redirectedRequest.setValue(
      originalRequest.value(forHTTPHeaderField: "Authorization"),
      forHTTPHeaderField: "Authorization")

    if response.statusCode == 307 || response.statusCode == 308 {
      redirectedRequest.httpMethod = originalRequest.httpMethod ?? "GET"
      redirectedRequest.httpBody = originalRequest.httpBody
      redirectedRequest.setValue(
        originalRequest.value(forHTTPHeaderField: "Content-Type"),
        forHTTPHeaderField: "Content-Type")
    }

    return redirectedRequest
  }

  private static func sameOrigin(_ firstURL: URL?, _ secondURL: URL?) -> Bool {
    guard let firstURL, let secondURL,
      let firstOrigin = Origin(url: firstURL),
      let secondOrigin = Origin(url: secondURL)
    else {
      return false
    }
    return firstOrigin == secondOrigin
  }

  private struct Origin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
      guard let scheme = url.scheme?.lowercased(),
        let host = url.host?.lowercased(),
        !host.isEmpty
      else {
        return nil
      }

      let defaultPort: Int
      switch scheme {
      case "http": defaultPort = 80
      case "https": defaultPort = 443
      default: return nil
      }

      self.scheme = scheme
      self.host = host
      self.port = url.port ?? defaultPort
    }
  }
}

public final class ProviderRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let originalRequest: URLRequest
  private let redirectCounter = ProviderRedirectCounter()

  public init(originalRequest: URLRequest) {
    self.originalRequest = originalRequest
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard
      let redirectedRequest = ProviderRedirectPolicy.redirectedRequest(
        originalRequest: originalRequest,
        response: response,
        proposedRequest: request)
    else {
      completionHandler(nil)
      return
    }
    Task {
      completionHandler(await redirectCounter.claimSlot() ? redirectedRequest : nil)
    }
  }
}

private actor ProviderRedirectCounter {
  private var count = 0

  func claimSlot() -> Bool {
    guard count < ProviderRedirectPolicy.maximumRedirectCount else { return false }
    count += 1
    return true
  }
}
