import Foundation
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class FileWorkspaceToolTests: XCTestCase {
  private var base: URL!
  private var root: URL!
  private var store: AppStore!
  private var conversation: Conversation!
  private var settings: AppSettings!

  override func setUp() async throws {
    try await super.setUp()
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = base.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    store = AppStore(
      persistence: PersistenceStore(localBaseURL: base.appendingPathComponent("state")))
    let deadline = Date().addingTimeInterval(10)
    while !store.hasLoadedPersistedSettings {
      guard Date() < deadline else {
        throw NSError(
          domain: "FileWorkspaceToolTests", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Timed out loading settings"])
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    conversation = Conversation()
    conversation.toolsEnabled = true
    conversation.enabledTools = [.files]
    settings = AppSettings()
    settings.toolSettings.filesWorkspaceAccessEnabled = true
    settings.toolSettings.filesAdvancedToolsEnabled = false
    // Exercise the settings snapshot used by an isolated run, including the
    // folder default. The live store deliberately has Files access disabled.
    store.settings.toolSettings.filesWorkspaceAccessEnabled = false
    settings.conversationFolderDefaults[conversation.folderID] = ConversationFolderDefaults(
      workingFolder: try WorkingFolderAccess.makeReference(from: root))
  }

  override func tearDown() async throws {
    store = nil
    try? FileManager.default.removeItem(at: base)
    try await super.tearDown()
  }

  func testChatCreatesAndDeletesFilesDirectlyAndThroughProxy() async throws {
    for proxy in [false, true] {
      settings.useToolProxy = proxy
      let definitions = ToolAgentRegistry.definitions(for: conversation, settings: settings)
      XCTAssertTrue(definitions.contains { $0.name == "files_mkdir" })
      XCTAssertTrue(definitions.contains { $0.name == "files_delete" })
      let created = await call("files_mkdir", ["path": .string("notes/reports")])
      XCTAssertFalse(created.hasPrefix("Error:"), created)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/reports").path))
      let written = await call(
        "files_write",
        [
          "path": .string("notes/reports/empty.txt"), "content": .string(""),
        ])
      XCTAssertFalse(written.hasPrefix("Error:"), written)
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("notes/reports/empty.txt")), Data())
      let binary = root.appendingPathComponent("notes/binary.dat")
      try Data([0xFF, 0x00, 0x80]).write(to: binary)
      let deleted = await call("files_delete", ["path": .string("notes/binary.dat")])
      XCTAssertFalse(deleted.hasPrefix("Error:"), deleted)
      XCTAssertFalse(FileManager.default.fileExists(atPath: binary.path))
      let denied = await call("files_delete", ["path": .string("notes")])
      XCTAssertTrue(denied.hasPrefix("Error:"), denied)
      XCTAssertTrue(denied.contains("recursive"), denied)
      let recursive = await call(
        "files_delete", ["path": .string("notes"), "recursive": .string("true")])
      XCTAssertFalse(recursive.hasPrefix("Error:"), recursive)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("notes").path))
    }
  }

  func testChatRejectsUnavailableToolsAndPathsOutsideItsFolder() async throws {
    let outside = base.appendingPathComponent("private.txt")
    try Data("keep".utf8).write(to: outside)
    for proxy in [false, true] {
      settings.useToolProxy = proxy
      for (name, arguments) in [
        ("files_mkdir", ["path": JSONValue.string("../outside")]),
        ("files_delete", ["path": JSONValue.string(outside.path)]),
        ("files_delete", ["path": JSONValue.string("."), "recursive": .bool(true)]),
      ] {
        let denied = await call(name, arguments)
        XCTAssertTrue(denied.hasPrefix("Error:"), denied)
      }
      settings.toolSettings.filesWorkspaceAccessEnabled = false
      let disabled = await call("files_mkdir", ["path": .string("disabled")])
      XCTAssertTrue(disabled.hasPrefix("Error:"), disabled)
      settings.toolSettings.filesWorkspaceAccessEnabled = true
    }
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: base.appendingPathComponent("outside").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("disabled").path))
  }

  func testAdvertisedFunctionToolDispatchesThroughFilesHandler() async throws {
    settings.toolSettings.filesAdvancedToolsEnabled = true
    try Data("int answer() { return 42; }\n".utf8).write(
      to: root.appendingPathComponent("answer.c"))
    let result = await call(
      "files_get_function", ["path": .string("answer.c"), "name": .string("answer")])
    XCTAssertFalse(result.hasPrefix("Error:"), result)
    XCTAssertTrue(result.contains("return 42"), result)
  }

  private func call(_ name: String, _ arguments: [String: JSONValue]) async -> String {
    let call = ParsedToolCall(
      name: settings.useToolProxy ? ToolProxy.callName : name,
      arguments: [:],
      argumentValues: settings.useToolProxy
        ? ["name": .string(name), "arguments": .object(arguments)] : arguments,
      rawBlock: "")
    return await ToolAgentRegistry.execute(
      call: call, conversation: conversation, settings: settings, store: store)
  }
}
