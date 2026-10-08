import UIKit

extension AppStore {
  /// The single in-app browser page, created on the first tool call and kept
  /// until the user confirms closing the browser. Minimizing keeps the page alive.
  func ensureBrowserSession() -> BrowserSession {
    if let browserSession {
      return browserSession
    }
    let session = BrowserSession(viewportSize: Self.browserViewportSize())
    browserSession = session
    closedBrowserURL = nil
    return session
  }

  func closeBrowserSession() {
    guard let session = browserSession else { return }
    closedBrowserURL =
      session.webView.url ?? session.lastNavigationURL ?? URL(string: "about:blank")
    session.tearDown()
    browserSession = nil
  }

  func reopenBrowserSession() {
    if let session = browserSession {
      session.presentation = .pictureInPicture
      return
    }
    let url = closedBrowserURL
    let session = ensureBrowserSession()
    if let url {
      Task { await session.load(url) }
    }
  }

  /// A phone-sized page regardless of how small the card is drawn. The height
  /// leaves room for the expanded view's bars so it shows the page 1:1.
  private static func browserViewportSize() -> CGSize {
    let screen =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?.screen.bounds.size ?? CGSize(width: 390, height: 844)
    return CGSize(width: screen.width, height: max(500, screen.height - 150))
  }
}
