import Foundation
import MaiDocuments
import XCTest

@testable import PocketMai

@MainActor
final class WebXDCImportTests: XCTestCase {
  private func archive(name: String? = nil) -> Data {
    var entries: [(path: String, data: Data)] = [
      ("index.html", Data("<html><script src='webxdc.js'></script>Hello</html>".utf8))
    ]
    if let name {
      entries.append(("manifest.toml", Data("name = \"\(name)\"\n".utf8)))
    }
    return ZipArchiveWriter.archive(entries: entries)
  }

  private func withStore(_ body: (AppStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: directory))
    let existingIDs = Set(WebXDCLibrary.listApps().map(\.id))
    defer {
      for app in WebXDCLibrary.listApps() where !existingIDs.contains(app.id) {
        try? WebXDCLibrary.deleteApp(id: app.id)
      }
    }
    try body(store)
  }

  func testSharedXDCDocumentInstallsBeforeReachingComposerAndSurvivesInboxCleanup() throws {
    try withStore { store in
      let item = try XCTUnwrap(
        SharedInbox.storeFile(
          data: archive(name: "Shared game"), filename: "game.xdc", kind: .document))
      let inboxURL = try XCTUnwrap(SharedInbox.fileURL(for: item))
      SharedInbox.enqueue([item])
      store.drainSharedInbox()

      let app = try XCTUnwrap(store.pendingWebXDCImport)
      XCTAssertEqual(app.name, "Shared game")
      XCTAssertTrue(WebXDCLibrary.listApps().contains { $0.id == app.id })
      XCTAssertEqual(WebXDCLibrary.app(id: app.id)?.name, "Shared game")
      XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.path))
      XCTAssertTrue(try WebXDCLibrary.readFile(app, path: "index.html").count > 0)
      XCTAssertFalse(store.hasQueuedSharedItems)
      XCTAssertEqual(store.sharedImportRequestID, 0)
      XCTAssertTrue(store.pendingConversationImportFiles.isEmpty)
      XCTAssertNil(store.errorMessage)
      store.drainSharedInbox()
      XCTAssertEqual(store.pendingWebXDCImport?.id, app.id)
      XCTAssertFalse(SharedInbox.hasPendingItems)
    }
  }

  func testMixedSharesRegisterAllAppsAndPreserveComposerItems() throws {
    try withStore { store in
      let first = try XCTUnwrap(
        SharedInbox.storeFile(
          data: archive(), filename: "First game.XDC", kind: .document))
      let second = try XCTUnwrap(
        SharedInbox.storeFile(
          data: archive(), filename: "Second game.xdc", kind: .document))
      let text = SharedInboxItem(kind: .text, filename: "Shared text", text: "Hello")
      let document = try XCTUnwrap(
        SharedInbox.storeFile(
          data: Data("Notes".utf8), filename: "notes.txt", kind: .document))
      defer { SharedInbox.discard(document) }
      store.importSharedItems([first, text, second, document])

      let app = try XCTUnwrap(store.pendingWebXDCImport)
      XCTAssertEqual(app.name, "Second game")
      XCTAssertNotNil(WebXDCLibrary.findApp(matching: "First game"))
      XCTAssertEqual(store.takeQueuedSharedItems(), [text, document])
      XCTAssertEqual(store.sharedImportRequestID, 1)
      XCTAssertNil(store.errorMessage)
    }
  }

  func testInvalidSharedAppReportsErrorWithoutBecomingAnAttachment() throws {
    try withStore { store in
      let before = Set(WebXDCLibrary.listApps().map(\.id))
      for data in [
        Data("not a zip".utf8),
        ZipArchiveWriter.archive(entries: [
          ("manifest.toml", Data("name = \"Missing index\"".utf8))
        ]),
      ] {
        let item = try XCTUnwrap(
          SharedInbox.storeFile(
            data: data, filename: "broken.xdc", kind: .document))
        let url = try XCTUnwrap(SharedInbox.fileURL(for: item))
        store.importSharedItems([item])
        XCTAssertTrue(store.errorMessage?.contains("broken.xdc") == true)
        XCTAssertNil(store.pendingWebXDCImport)
        XCTAssertFalse(store.hasQueuedSharedItems)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(Set(WebXDCLibrary.listApps().map(\.id)), before)
      }
    }
  }

  func testFileOpenInstallsXDCAndKeepsOriginalNameWithoutManifest() throws {
    try withStore { store in
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent("Opened game.XDC")
      try archive().write(to: url)
      store.openImportFile(at: url)

      let app = try XCTUnwrap(store.pendingWebXDCImport)
      XCTAssertEqual(app.name, "Opened game")
      XCTAssertNotNil(WebXDCLibrary.app(id: app.id))
      XCTAssertTrue(store.pendingConversationImportFiles.isEmpty)
      XCTAssertFalse(store.hasQueuedSharedItems)
      XCTAssertNil(store.errorMessage)
    }
  }
}
