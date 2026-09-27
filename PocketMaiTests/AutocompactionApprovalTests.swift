import Foundation
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class AutocompactionApprovalTests: XCTestCase {
  private var store: AppStore!
  private var directory: URL!

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-compaction-\(UUID().uuidString)", isDirectory: true)
    store = AppStore(persistence: PersistenceStore(localBaseURL: directory))
    try await waitUntil { self.store.hasLoadedPersistedSettings && self.store.currentConversation != nil }
    store.settings.mlxAutoCompact = true
    store.settings.yoloModeEnabled = true
    store.updateCurrentConversationSettings {
      $0.provider = .mlx
      $0.mlxMaxKVSize = .size1024
      $0.messages = [
        ChatMessage(role: .user, text: String(repeating: "Keep this context. ", count: 800)),
        ChatMessage(role: .assistant, text: "Earlier reply"),
        ChatMessage(role: .assistant, text: "More details"),
        ChatMessage(role: .user, text: "Continue"),
      ]
    }
  }

  override func tearDown() async throws {
    for request in store.autocompactionApprovalRequests {
      store.resolveAutocompactionApproval(id: request.id, decision: .cancelRun)
    }
    store = nil
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  func testSkipPromptsEvenWithYOLOAndKeepsHistoryAndModelChanges() async throws {
    let conversation = try XCTUnwrap(store.currentConversation)
    let task = Task { await store.autoCompactIfNeeded(conversationID: conversation.id) }
    defer { task.cancel() }
    try await waitUntil { self.store.activeAutocompactionApprovalRequest != nil }
    let pending = try XCTUnwrap(store.activeAutocompactionApprovalRequest)
    XCTAssertEqual(pending.conversationID, conversation.id)
    XCTAssertGreaterThan(pending.estimatedTokens, pending.threshold)
    XCTAssertFalse(store.isCompacting)
    XCTAssertEqual(store.currentConversation?.messages, conversation.messages)
    store.updateCurrentConversationSettings { $0.modelID = "replacement-model" }
    store.resolveAutocompactionApproval(id: pending.id, decision: .continueWithoutCompacting)
    let continued = await task.value
    XCTAssertTrue(continued)
    XCTAssertEqual(store.currentConversation?.messages, conversation.messages)
    XCTAssertEqual(store.currentConversation?.modelID, "replacement-model")
    XCTAssertTrue(store.autocompactionApprovalRequests.isEmpty)
  }

  func testCancellationDismissesPendingPromptAndKeepsHistory() async throws {
    let conversation = try XCTUnwrap(store.currentConversation)
    let task = Task { await store.autoCompactIfNeeded(conversationID: conversation.id) }
    defer { task.cancel() }
    try await waitUntil { self.store.activeAutocompactionApprovalRequest != nil }
    task.cancel()
    let continued = await task.value
    XCTAssertFalse(continued)
    XCTAssertTrue(store.autocompactionApprovalRequests.isEmpty)
    XCTAssertEqual(store.currentConversation?.messages, conversation.messages)
  }

  func testStopDoesNotCompactOrContinue() async throws {
    let conversation = try XCTUnwrap(store.currentConversation)
    let task = Task { await store.autoCompactIfNeeded(conversationID: conversation.id) }
    defer { task.cancel() }
    try await waitUntil { self.store.activeAutocompactionApprovalRequest != nil }
    let id = try XCTUnwrap(store.activeAutocompactionApprovalRequest?.id)
    store.resolveAutocompactionApproval(id: id, decision: .cancelRun)
    // A second UI event must not resume the continuation twice.
    store.resolveAutocompactionApproval(id: id, decision: .compact)
    let continued = await task.value
    XCTAssertFalse(continued)
    XCTAssertEqual(store.currentConversation?.messages, conversation.messages)
  }

  func testClearTargetsRequestingChatAfterSelectionChanges() async throws {
    let conversation = try XCTUnwrap(store.currentConversation)
    let task = Task { await store.autoCompactIfNeeded(conversationID: conversation.id) }
    defer { task.cancel() }
    try await waitUntil { self.store.activeAutocompactionApprovalRequest != nil }
    let id = try XCTUnwrap(store.activeAutocompactionApprovalRequest?.id)
    store.newConversation()
    store.updateCurrentConversationSettings {
      $0.messages = [ChatMessage(role: .user, text: "Keep the other chat")]
    }
    let other = try XCTUnwrap(store.currentConversation)
    store.clearChatForAutocompaction(id: id)
    let continued = await task.value
    XCTAssertFalse(continued)
    XCTAssertEqual(store.conversation(withID: conversation.id)?.messages, [])
    XCTAssertEqual(store.currentConversation?.id, other.id)
    XCTAssertEqual(store.currentConversation?.messages, other.messages)
    XCTAssertTrue(store.autocompactionApprovalRequests.isEmpty)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else { throw WaitError.timedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private enum WaitError: Error { case timedOut }
}
