import Foundation
import XCTest
@testable import MaiDocuments

final class WebXDCStoreTests: XCTestCase {
  // New apps must appear first, even after an older app is edited.
  func testListsNewestAddedAppsFirst() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WebXDCStore(rootURL: root)
    var older = try store.createApp(name: "Older", description: "")
    var newest = try store.createApp(name: "Newest", description: "")
    var middle = try store.createApp(name: "Middle", description: "")
    older.createdAt = Date(timeIntervalSince1970: 1_000)
    newest.createdAt = Date(timeIntervalSince1970: 3_000)
    middle.createdAt = Date(timeIntervalSince1970: 2_000)
    for app in [older, newest, middle] { try store.save(app) }
    try store.writeFile(older, path: "index.html", data: Data("Updated".utf8))
    XCTAssertEqual(store.listApps().map(\.id), [newest.id, middle.id, older.id])
  }

  // Importing the same app again must retain its ID, saved updates and browser storage.
  func testImportSurvivesSourceRemovalAndPreservesExistingAppData() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WebXDCStore(rootURL: root.appendingPathComponent("apps"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = root.appendingPathComponent("game.xdc")
    let entries = [(path: "index.html", data: Data("Hello".utf8)),
      (path: "manifest.toml", data: Data("name = \"Game\"".utf8))]
    try ZipArchiveWriter.write(entries: entries, to: archive)
    let first = try store.importXDC(from: archive, fallbackName: "game")
    let saved = store.appURL(first.app.id).appendingPathComponent("updates.json")
    try Data("saved move".utf8).write(to: saved)
    try ZipArchiveWriter.write(entries: entries.reversed(), to: archive)
    let again = try store.importXDC(from: archive, fallbackName: "renamed")
    try FileManager.default.removeItem(at: archive)
    XCTAssertTrue(again.alreadyImported)
    XCTAssertEqual(again.app.id, first.app.id)
    XCTAssertEqual(store.listApps().map(\.name), ["Game"])
    XCTAssertEqual(try store.readFile(again.app, path: "index.html"), Data("Hello".utf8))
    XCTAssertEqual(try Data(contentsOf: saved), Data("saved move".utf8))
  }

  func testInvalidArchiveDoesNotInstallAndPathsCannotEscapeApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WebXDCStore(rootURL: root)
    try store.ensureRoot()
    let archive = root.appendingPathComponent("invalid.xdc")
    try ZipArchiveWriter.write(entries: [("manifest.toml", Data())], to: archive)
    XCTAssertThrowsError(try store.importXDC(from: archive, fallbackName: "Invalid"))
    XCTAssertTrue(store.listApps().isEmpty)
    for path in ["../outside", "/etc/passwd", "a/../../outside", "a\\outside"] {
      XCTAssertThrowsError(try store.validatedRelativePath(path))
    }
  }
}
