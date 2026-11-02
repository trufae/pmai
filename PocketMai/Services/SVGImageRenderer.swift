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
            content="default-src 'none'; img-src data:; connect-src data:; style-src 'unsafe-inline'">
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
        // Canvas rendering waits for decoding and does not depend on a visible
        // window, display scale, or a pending WebKit screen update.
        let result = try await webView.callAsyncJavaScript(
          """
          const image = document.images[0];
          await image.decode();
          const source = await (await fetch(image.src)).text();
          const root = new DOMParser().parseFromString(source, 'image/svg+xml').documentElement;
          if (root.localName !== 'svg') throw new Error('Invalid SVG');
          const viewBox = root.viewBox.baseVal;
          const length = value => value.baseVal.unitType !== 2 && value.baseVal.value > 0
            ? value.baseVal.value : 0;
          let width = length(root.width);
          let height = length(root.height);
          if (viewBox.width > 0 && viewBox.height > 0) {
            if (!width) width = height ? height * viewBox.width / viewBox.height : viewBox.width;
            if (!height) height = width * viewBox.height / viewBox.width;
          }
          width ||= image.naturalWidth;
          height ||= image.naturalHeight;
          const longestSide = maxDimension ?? Math.max(width, height);
          if (![width, height, longestSide].every(value => Number.isFinite(value) && value > 0)
              || longestSide > 8192) throw new Error('Invalid SVG dimensions');
          const scale = longestSide / Math.max(width, height);
          const canvas = document.createElement('canvas');
          canvas.width = Math.max(1, Math.round(width * scale));
          canvas.height = Math.max(1, Math.round(height * scale));
          if (canvas.width * canvas.height > 16777216) throw new Error('SVG is too large');
          canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
          return canvas.toDataURL('image/png').split(',')[1];
          """,
          arguments: ["maxDimension": maxDimension.map { $0 as Any } ?? NSNull()],
          in: nil, contentWorld: .defaultClient)
        guard continuation != nil else { return }
        guard let encoded = result as? String,
          let png = Data(base64Encoded: encoded), let image = UIImage(data: png)
        else {
          throw URLError(.cannotDecodeContentData)
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
