import Foundation
import MaiStandardTools
import XCTest

@testable import PocketMai

@MainActor
final class WorkspaceFileBrowserTests: XCTestCase {
  func testLocalBrowsingUploadPreviewAndDownloadPreserveBinaryContents() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("browser-ui-\(UUID())")
    let root = base.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("binary.dat")
    let bytes = Data((0..<WorkspaceFileRequest.chunkSize + 31).map { UInt8($0 % 256) })
    try bytes.write(to: source)
    let browser = WorkspaceFileBrowser(
      location: .local(.custom(rootURL: root, displayName: "Test")))
    defer { browser.close() }
    browser.browse()
    await browser.operation?.value
    XCTAssertNil(browser.error)
    XCTAssertFalse(browser.canGoUp)
    browser.createDirectory("new folder")
    await browser.operation?.value
    let folder = try XCTUnwrap(browser.entries.first)
    XCTAssertTrue(folder.isDirectory)
    browser.open(folder)
    await browser.operation?.value
    XCTAssertTrue(browser.canGoUp)
    browser.upload([source])
    await browser.operation?.value
    XCTAssertNil(browser.error)
    let file = try XCTUnwrap(browser.entries.first)
    XCTAssertEqual(file.name, "binary.dat")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), bytes)
    browser.open(file)
    await browser.operation?.value
    let preview = try XCTUnwrap(browser.preview)
    XCTAssertFalse(preview.isPartial)
    XCTAssertEqual(try Data(contentsOf: preview.url), bytes)
    browser.clearPreview()
    XCTAssertFalse(FileManager.default.fileExists(atPath: preview.url.path))
    browser.save(file)
    await browser.operation?.value
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(browser.download).url), bytes)
    browser.clearDownload()
    try Data([42]).write(to: source)
    browser.upload([source])
    await browser.operation?.value
    XCTAssertNotNil(browser.error)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), bytes)
    browser.upload([source], overwrite: true)
    await browser.operation?.value
    XCTAssertNil(browser.error)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), Data([42]))
    browser.goUp()
    await browser.operation?.value
    XCTAssertEqual(browser.path, root.resolvingSymlinksInPath().path)
    browser.browse(base.path)
    await browser.operation?.value
    XCTAssertNotNil(browser.error)
    XCTAssertEqual(browser.path, root.resolvingSymlinksInPath().path)
  }

  func testGrowingFileStillUsesBoundedPreviewAndRemoteOfflineMakesNoConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "browser-large-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("large.bin")
    try Data([0]).write(to: url)
    let browser = WorkspaceFileBrowser(
      location: .local(.custom(rootURL: root, displayName: "Test")))
    defer { browser.close() }
    browser.browse()
    await browser.operation?.value
    let entry = try XCTUnwrap(browser.entries.first)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(WorkspaceFileBrowser.previewLimit + 1))
    try handle.close()
    browser.open(entry)
    await browser.operation?.value
    let preview = try XCTUnwrap(browser.preview)
    XCTAssertTrue(preview.isPartial)
    XCTAssertEqual(try Data(contentsOf: preview.url).count, 64 * 1024)
    let host = RemoteAgentBookmark(
      name: "Offline", url: URL(string: "wss://invalid.example/acp")!, cwd: "/project")
    let remote = WorkspaceFileBrowser(location: .remote(host, cwd: "/project"), isOffline: { true })
    defer { remote.close() }
    remote.browse()
    await remote.operation?.value
    XCTAssertTrue(remote.error?.contains("Airplane Mode") == true)
    XCTAssertTrue(remote.entries.isEmpty)
  }
}
