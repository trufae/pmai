import Foundation
import MaiDocuments
import XCTest

@testable import PocketMai

@MainActor
final class WebXDCImportTests: XCTestCase {
  private func archive(name: String? = nil, content: String = "Hello") -> Data {
    var entries: [(path: String, data: Data)] = [
      ("index.html", Data("<html><script src='webxdc.js'></script>\(content)</html>".utf8))
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

      let app = try XCTUnwrap(store.pendingWebXDCImports.last?.app)
      XCTAssertEqual(app.name, "Shared game")
      XCTAssertNil(store.activeWebXDCSession)
      XCTAssertTrue(store.showingWebXDCApps)
      XCTAssertFalse(try XCTUnwrap(store.pendingWebXDCImports.first).alreadyImported)
      XCTAssertTrue(WebXDCLibrary.listApps().contains { $0.id == app.id })
      XCTAssertEqual(WebXDCLibrary.app(id: app.id)?.name, "Shared game")
      XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.path))
      XCTAssertTrue(try WebXDCLibrary.readFile(app, path: "index.html").count > 0)
      XCTAssertFalse(store.hasQueuedSharedItems)
      XCTAssertEqual(store.sharedImportRequestID, 0)
      XCTAssertTrue(store.pendingConversationImportFiles.isEmpty)
      XCTAssertNil(store.errorMessage)
      store.drainSharedInbox()
      XCTAssertEqual(store.pendingWebXDCImports.first?.app.id, app.id)
      XCTAssertFalse(SharedInbox.hasPendingItems)
    }
  }

  func testMixedSharesRegisterAllAppsAndPreserveComposerItems() throws {
    try withStore { store in
      let first = try XCTUnwrap(
        SharedInbox.storeFile(
          data: archive(content: "First"), filename: "First game.XDC", kind: .document))
      let second = try XCTUnwrap(
        SharedInbox.storeFile(
          data: archive(content: "Second"), filename: "Second game.xdc", kind: .document))
      let text = SharedInboxItem(kind: .text, filename: "Shared text", text: "Hello")
      let document = try XCTUnwrap(
        SharedInbox.storeFile(
          data: Data("Notes".utf8), filename: "notes.txt", kind: .document))
      defer { SharedInbox.discard(document) }
      store.importSharedItems([first, text, second, document])

      let app = try XCTUnwrap(store.pendingWebXDCImports.last?.app)
      XCTAssertEqual(app.name, "Second game")
      XCTAssertEqual(store.pendingWebXDCImports.map(\.app.name), ["First game", "Second game"])
      XCTAssertNil(store.activeWebXDCSession)
      XCTAssertTrue(store.showingWebXDCApps)
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
        XCTAssertTrue(store.pendingWebXDCImports.isEmpty)
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

      let app = try XCTUnwrap(store.pendingWebXDCImports.last?.app)
      XCTAssertEqual(app.name, "Opened game")
      XCTAssertNotNil(WebXDCLibrary.app(id: app.id))
      XCTAssertTrue(store.pendingConversationImportFiles.isEmpty)
      XCTAssertFalse(store.hasQueuedSharedItems)
      XCTAssertNil(store.errorMessage)
    }
  }

  private func importArchive(_ data: Data, name: String = "game") throws -> WebXDCImportResult {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).xdc")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    return try WebXDCLibrary.importXDC(from: url, fallbackName: name)
  }

  func testIdenticalFilesReuseAppDespiteArchiveOrderAndKeepPermissionsAndData() throws {
    try withStore { _ in
      let name = UUID().uuidString
      let data = archive(name: name)
      let first = try importArchive(data)
      var grants = WebXDCPermissions()
      grants.inference = true
      try grants.save(first.app.id)
      let stateURL = WebXDCLibrary.appURL(first.app.id).appendingPathComponent("updates.json")
      try Data("saved state".utf8).write(to: stateURL)
      let entries = try ZipArchiveReader.entries(in: data).reversed().map {
        (path: $0.path, data: $0.data)
      }
      let duplicate = try importArchive(ZipArchiveWriter.archive(entries: entries))

      XCTAssertTrue(duplicate.alreadyImported)
      XCTAssertEqual(duplicate.app.id, first.app.id)
      XCTAssertEqual(WebXDCPermissions.load(first.app.id), grants)
      XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), "saved state")
      XCTAssertEqual(WebXDCLibrary.listApps().filter { $0.name == name }.count, 1)
    }
  }

  func testNameConflictsGetNumberedAndDuplicateFindsSuffixedApp() throws {
    try withStore { _ in
      let name = UUID().uuidString
      let first = try importArchive(archive(name: name, content: "one"))
      let secondData = archive(name: name, content: "two")
      let second = try importArchive(secondData)
      let third = try importArchive(archive(name: name.lowercased(), content: "three"))
      let duplicate = try importArchive(secondData)

      XCTAssertEqual(first.app.name, name)
      XCTAssertEqual(second.app.name, "\(name) (2)")
      XCTAssertEqual(third.app.name, "\(name.lowercased()) (3)")
      XCTAssertFalse(second.alreadyImported)
      XCTAssertTrue(duplicate.alreadyImported)
      XCTAssertEqual(duplicate.app.id, second.app.id)
    }
  }

  func testHiddenFilesParticipateInDuplicateDetection() throws {
    try withStore { _ in
      let data = ZipArchiveWriter.archive(entries: [
        ("index.html", Data(UUID().uuidString.utf8)),
        (".assets/code.js", Data("hello".utf8)),
      ])
      let first = try importArchive(data)
      XCTAssertEqual(try importArchive(data).app.id, first.app.id)
      XCTAssertTrue(WebXDCLibrary.listFiles(first.app).contains(".assets/code.js"))
    }
  }

  func testRejectedFileLeavesNoInstalledApp() throws {
    try withStore { _ in
      let before = Set(WebXDCLibrary.listApps().map(\.id))
      let data = ZipArchiveWriter.archive(entries: [
        ("index.html", Data("ok".utf8)),
        ("oversized.bin", Data(repeating: 0, count: WebXDCLibrary.maxFileBytes + 1)),
      ])
      XCTAssertThrowsError(try importArchive(data))
      XCTAssertEqual(Set(WebXDCLibrary.listApps().map(\.id)), before)
    }
  }

}
