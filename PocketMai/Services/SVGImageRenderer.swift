import UIKit
import WebKit

@MainActor
final class SVGImageRenderer: NSObject, WKNavigationDelegate {
  private let webView: WKWebView
  private var continuation: CheckedContinuation<UIImage, Error>?
  private var timeout: Task<Void, Never>?
  private var maxDimension: Int?

  private override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    webView = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 300, height: 150), configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
  }

  static func render(_ data: Data, maxDimension: Int? = 1024) async throws -> UIImage {
    let renderer = SVGImageRenderer()
    renderer.maxDimension = maxDimension
    return try await renderer.image(from: data)
  }

  private func image(from data: Data) async throws -> UIImage {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        // Loading SVG as an image disables its scripts and external resources.
        webView.loadHTMLString(
          """
          <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
          <meta http-equiv="Content-Security-Policy"
            content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
          <style>html,body{margin:0;width:100%;height:100%;background:transparent}
          img{display:block;width:100%;height:100%;object-fit:contain}</style>
          <img src="data:image/svg+xml;base64,\(data.base64EncodedString())">
          """, baseURL: nil)
        timeout = Task { [weak self] in
          do {
            try await Task.sleep(for: .seconds(15))
            self?.finish(.failure(URLError(.timedOut)))
          } catch {}
        }
      }
    } onCancel: {
      Task { @MainActor in
        self.finish(.failure(CancellationError()))
      }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task {
      do {
        guard let dimensions = try await webView.evaluateJavaScript(
          "[document.images[0].naturalWidth, document.images[0].naturalHeight]") as? [Double],
          dimensions.count == 2,
          dimensions.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
          throw URLError(.cannotDecodeContentData)
        }
        guard continuation != nil else { return }
        let longestSide = maxDimension.map(Double.init) ?? max(dimensions[0], dimensions[1])
        guard longestSide > 0, longestSide <= 8192 else {
          throw URLError(.dataLengthExceedsMaximum)
        }
        let scale = longestSide / max(dimensions[0], dimensions[1])
        let size = CGSize(
          width: max(1, (dimensions[0] * scale).rounded()),
          height: max(1, (dimensions[1] * scale).rounded()))
        guard size.width * size.height <= 16_777_216 else {
          throw URLError(.dataLengthExceedsMaximum)
        }
        webView.frame.size = size
        webView.layoutIfNeeded()
        let configuration = WKSnapshotConfiguration()
        // Offscreen software snapshots include current layout without waiting for a screen update.
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(
          value: Double(size.width / max(1, webView.traitCollection.displayScale)))
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
          snapshot.draw(in: CGRect(origin: .zero, size: size))
        }
        finish(.success(image))
      } catch {
        finish(.failure(error))
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(.failure(error))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    finish(.failure(error))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(.failure(URLError(.cannotDecodeContentData)))
  }

  private func finish(_ result: Result<UIImage, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timeout?.cancel()
    timeout = nil
    webView.navigationDelegate = nil
    webView.stopLoading()
    continuation.resume(with: result)
  }
}
