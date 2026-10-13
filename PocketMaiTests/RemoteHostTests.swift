import Foundation
import MaiACP
import XCTest

@testable import PocketMai

@MainActor
final class RemoteHostTests: XCTestCase {
  private func withStore(
    _ bookmarks: [RemoteAgentBookmark],
    body: (RemoteAgentStore, URL) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "remote-host-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("connections.json")
    try JSONEncoder().encode(bookmarks).write(to: file)
    try body(RemoteAgentStore(file: file), file)
  }

  func testLegacyWorkspaceConnectionsBecomeOneHostWithoutLosingChats() throws {
    let url = try XCTUnwrap(URL(string: "wss://worker.example/acp"))
    let first = RemoteAgentBookmark(
      name: "Worker", url: url, cwd: "/work/one",
      sessionID: "one", messages: [.init(role: "user", text: "First conversation")])
    let second = RemoteAgentBookmark(
      name: "Worker", url: url, cwd: "/work/two",
      sessionID: "two", messages: [.init(role: "user", text: "Second conversation")])
    try withStore([first, second]) { store, file in
      XCTAssertEqual(store.connections.count, 1)
      let host = try XCTUnwrap(store.connections.first)
      XCTAssertEqual(host.id, first.id)
      XCTAssertEqual(Set(store.folders(for: host).map(\.cwd)), Set(["/work/one", "/work/two"]))
      XCTAssertEqual(
        Set(store.conversations(for: host).compactMap(\.sessionID)), Set(["one", "two"]))
      let newChat = store.newConversation(hostID: host.id, cwd: "/work/one")
      let reloaded = RemoteAgentStore(file: file)
      let reloadedHost = try XCTUnwrap(reloaded.connections.first)
      XCTAssertEqual(reloaded.conversations(for: reloadedHost).count, 3)
      XCTAssertTrue(reloaded.conversations(for: reloadedHost).contains { $0.id == newChat.id })
    }
  }

  func testDiscoveryKeepsOpaqueSessionIdentityAndIsolatesHosts() throws {
    let first = RemoteAgentBookmark(
      name: "First", url: try XCTUnwrap(URL(string: "wss://first.example/acp")), cwd: "/work")
    let second = RemoteAgentBookmark(
      name: "Second", url: try XCTUnwrap(URL(string: "wss://second.example/acp")), cwd: "/work")
    try withStore([first, second]) { store, file in
      let snapshot = ACPWorkspaceSnapshot(
        folders: [.init(cwd: "/work", name: "Project")],
        sessions: [.init(sessionID: "opaque-session", cwd: "/work", title: "Remote chat")])
      store.updateWorkspace(first.id, snapshot: snapshot)
      let firstHost = try XCTUnwrap(store.host(first.id))
      let chat = try XCTUnwrap(store.conversations(for: firstHost).first)
      store.updateWorkspace(first.id, snapshot: snapshot)
      XCTAssertEqual(
        store.conversations(for: try XCTUnwrap(store.host(first.id))).first?.id, chat.id)
      XCTAssertTrue(store.conversations(for: try XCTUnwrap(store.host(second.id))).isEmpty)
      var updated = chat
      updated.messages = [.init(role: "user", text: "Continue")]
      store.update(first.id, conversation: updated)
      let reloaded = RemoteAgentStore(file: file)
      XCTAssertEqual(
        reloaded.conversations(for: try XCTUnwrap(reloaded.host(first.id))).first?.messages.first?
          .text, "Continue")
      XCTAssertTrue(reloaded.conversations(for: try XCTUnwrap(reloaded.host(second.id))).isEmpty)
    }
  }

  func testHostColorApprovalStateAndReconnectRevisionPersist() throws {
    let original = RemoteAgentBookmark(
      name: "Workstation",
      url: try XCTUnwrap(URL(string: "ws://192.168.1.5:19283/acp")), cwd: "/work",
      accentColor: "custom:#22AA55", requiresApproval: true)
    try withStore([original]) { store, file in
      store.reconnect(original.id)
      let updated = try XCTUnwrap(store.host(original.id))
      XCTAssertNotNil(updated.revision)
      let reloaded = try XCTUnwrap(RemoteAgentStore(file: file).host(original.id))
      XCTAssertEqual(reloaded.accentColor, "custom:#22AA55")
      XCTAssertEqual(reloaded.requiresApproval, true)
      XCTAssertEqual(reloaded.revision, updated.revision)
      XCTAssertEqual(reloaded.url, original.url)
    }
  }
}
