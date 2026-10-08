import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import PocketMai

@MainActor
final class BrowserToolTests: XCTestCase {
  func testURLNormalizationAssumesHTTPSAndRejectsOtherSchemes() {
    XCTAssertEqual(
      BrowserSession.url(from: "example.com/path")?.absoluteString, "https://example.com/path")
    XCTAssertEqual(
      BrowserSession.url(from: "  http://example.com ")?.absoluteString, "http://example.com")
    XCTAssertNil(BrowserSession.url(from: ""))
    XCTAssertNil(BrowserSession.url(from: "javascript:alert(1)"))
    XCTAssertNil(BrowserSession.url(from: "file:///etc/passwd"))
    XCTAssertNil(BrowserSession.url(from: "pocketmai://prompt"))
  }

  func testBrowserToolsAreRegisteredWithUniqueNames() {
    let names = BrowserTool.definitions.map(\.name)
    XCTAssertEqual(names, BrowserTool.toolNames)
    XCTAssertEqual(Set(names).count, names.count)
    XCTAssertTrue(BrowserTool.definitions.allSatisfy { $0.annotations.approval == .confirm })
  }

  func testMinimizedBrowserSurvivesConversationDeletionAndReopensSamePage() async throws {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-browser-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: baseURL))
    try await waitUntil { store.hasLoadedPersistedSettings }
    let conversationID = try XCTUnwrap(store.selectedConversationID)
    let session = store.ensureBrowserSession()
    defer { store.closeBrowserSession() }
    await session.load(URL(string: "about:blank")!)
    _ = await session.call("window.browserTestValue = 'page kept'; return true;")
    let webView = session.webView
    session.pipSize = .large
    session.pipOffset = CGSize(width: -30, height: -50)
    session.presentation = .minimized

    store.newConversation()
    store.deleteConversations([conversationID])
    XCTAssertTrue(store.ensureBrowserSession() === session)
    XCTAssertEqual(session.presentation, .minimized)
    store.reopenBrowserSession()
    XCTAssertEqual(session.presentation, .pictureInPicture)
    XCTAssertTrue(session.webView === webView)
    XCTAssertEqual(session.pipSize, .large)
    XCTAssertEqual(session.pipOffset, CGSize(width: -30, height: -50))
    let pageValue = await session.call("return window.browserTestValue;")
    XCTAssertEqual(pageValue, "page kept")
  }

  func testClosedBrowserCanBeReopenedFromAnotherConversation() async throws {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-browser-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: baseURL))
    try await waitUntil { store.hasLoadedPersistedSettings }
    let conversationID = try XCTUnwrap(store.selectedConversationID)
    let session = store.ensureBrowserSession()
    let url = URL(string: "data:text/html,%3Ctitle%3EReopened%3C/title%3Ehello")!
    await session.load(url)
    store.closeBrowserSession()
    XCTAssertNil(store.browserSession)
    XCTAssertEqual(store.closedBrowserURL, url)
    XCTAssertTrue(session.isClosed)
    let closedResult = await session.call("return 'still running';")
    XCTAssertTrue(closedResult.hasPrefix("Error:"))

    store.newConversation()
    store.deleteConversations([conversationID])
    XCTAssertEqual(store.closedBrowserURL, url)
    store.reopenBrowserSession()
    let reopened = try XCTUnwrap(store.browserSession)
    defer { store.closeBrowserSession() }
    XCTAssertFalse(reopened === session)
    XCTAssertNil(store.closedBrowserURL)
    XCTAssertEqual(reopened.presentation, .pictureInPicture)
    try await waitUntil { reopened.title == "Reopened" }
  }

  func testMovingPageBetweenHostsPreservesOwnershipAndViewport() {
    let viewport = CGSize(width: 390, height: 694)
    let session = BrowserSession(viewportSize: viewport)
    defer { session.tearDown() }
    let preview = BrowserHostView(frame: CGRect(x: 0, y: 0, width: 150, height: 267))
    let expanded = BrowserHostView(frame: CGRect(origin: .zero, size: viewport))
    preview.adopt(session.webView, viewportSize: viewport, interactive: false)
    preview.layoutIfNeeded()
    XCTAssertFalse(session.webView.isUserInteractionEnabled)
    XCTAssertEqual(session.webView.bounds.size, viewport)

    session.presentation = .expanded
    expanded.adopt(session.webView, viewportSize: viewport, interactive: true)
    preview.release()
    expanded.layoutIfNeeded()
    XCTAssertTrue(session.webView.superview === expanded)
    XCTAssertTrue(session.webView.isUserInteractionEnabled)

    session.presentation = .pictureInPicture
    preview.adopt(session.webView, viewportSize: viewport, interactive: false)
    expanded.release()
    preview.layoutIfNeeded()
    XCTAssertTrue(session.webView.superview === preview)
    XCTAssertEqual(session.webView.bounds.size, viewport)
    preview.release()
    XCTAssertNil(session.webView.superview)
  }

  func testPresentationReattachesLivePageAfterFullscreenAndToolbarMinimization() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousKeyWindow = scene.keyWindow
    let session = BrowserSession(viewportSize: CGSize(width: 390, height: 694))
    let controller = UIHostingController(
      rootView: BrowserPresentationOverlay(session: session, onClose: {}))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previousKeyWindow?.makeKeyAndVisible()
      session.tearDown()
    }
    try await waitUntil { session.webView.superview is BrowserHostView }
    let previewHost = session.webView.superview

    session.presentation = .expanded
    try await waitUntil {
      controller.presentedViewController != nil
        && session.webView.superview !== previewHost
        && session.webView.isUserInteractionEnabled
    }
    session.presentation = .pictureInPicture
    try await waitUntil {
      controller.presentedViewController == nil && session.webView.superview === previewHost
    }
    XCTAssertFalse(session.webView.isUserInteractionEnabled)

    session.presentation = .minimized
    try await waitUntil { session.webView.superview == nil }
    session.presentation = .pictureInPicture
    try await waitUntil { session.webView.superview is BrowserHostView }
    XCTAssertFalse(session.isClosed)
    XCTAssertEqual(session.webView.bounds.size, session.viewportSize)
  }

  func testPinchSnapsBetweenThreeSizesAndStopsAtLimits() {
    typealias Size = BrowserSession.PiPSize
    XCTAssertEqual(Size.small.resized(for: 1.3), .medium)
    XCTAssertEqual(Size.medium.resized(for: 1.3), .large)
    XCTAssertEqual(Size.large.resized(for: 1.3), .large)
    XCTAssertEqual(Size.large.resized(for: 0.7), .medium)
    XCTAssertEqual(Size.medium.resized(for: 0.7), .small)
    XCTAssertEqual(Size.small.resized(for: 0.7), .small)
    XCTAssertEqual(Size.small.resized(for: 2), .large)
    XCTAssertEqual(Size.large.resized(for: 0.4), .small)
    XCTAssertEqual(Size.medium.resized(for: 1.05), .medium)
    XCTAssertEqual(Size.medium.resized(for: .nan), .medium)
  }

  func testPreviewCannotBeDraggedOutsideChatAfterResizingOrRotation() {
    let available = CGSize(width: 390, height: 600)
    let card = CGSize(width: 150, height: 232)
    XCTAssertEqual(
      BrowserPiPCard.clampedOffset(
        CGSize(width: 100, height: 100),
        cardSize: card, availableSize: available), .zero)
    XCTAssertEqual(
      BrowserPiPCard.clampedOffset(
        CGSize(width: -1000, height: -1000),
        cardSize: card, availableSize: available), CGSize(width: -216, height: -344))
    XCTAssertEqual(
      BrowserPiPCard.clampedOffset(
        CGSize(width: -200, height: -300),
        cardSize: CGSize(width: 280, height: 500), availableSize: available),
      CGSize(width: -86, height: -76))
    XCTAssertEqual(
      BrowserPiPCard.clampedOffset(
        CGSize(width: -200, height: -300),
        cardSize: card, availableSize: CGSize(width: 120, height: 180)), .zero)
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(predicate(), "Browser operation did not finish before the deadline")
  }

  func testOpenConversationDeepLinkRoundTrips() {
    let id = UUID()
    let url = PocketMaiDeepLink.url(for: .openConversation(id: id))
    XCTAssertEqual(url.host, PocketMaiDeepLink.conversationHost)
    XCTAssertEqual(PocketMaiDeepLink.command(from: url), .openConversation(id: id))
    XCTAssertNil(
      PocketMaiDeepLink.command(from: URL(string: "pocketmai://conversation/not-a-uuid")!))
  }
}
