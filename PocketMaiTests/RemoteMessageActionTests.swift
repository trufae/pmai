import Foundation
import MaiACP
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class RemoteMessageActionTests: XCTestCase {
  func testRetryRestartAndResubmitUseTheRemoteSessionAndPersistItsHistory() async throws {
    try await withChat { chat, store, fixture, setOffline in
      let selected = try XCTUnwrap(chat.messages.first { $0.text == "Second" })
      let originalIDs = chat.messages.map(\.id)
      XCTAssertTrue(chat.canRetry(selected.id))
      XCTAssertTrue(chat.canResubmit(selected.id))
      let assistant = try XCTUnwrap(chat.messages.first { $0.role == "assistant" })
      XCTAssertFalse(chat.canResubmit(assistant.id))
      XCTAssertFalse(chat.canRetry(assistant.id))
      XCTAssertFalse(chat.canResubmit(UUID()))

      setOffline(true)
      XCTAssertFalse(chat.canRetry(selected.id))
      XCTAssertFalse(chat.canResubmit(selected.id))
      chat.retry(selected.id)
      chat.resubmit(selected.id)
      XCTAssertEqual(chat.messages.map(\.id), originalIDs)
      XCTAssertTrue(fixture.mutations.isEmpty)
      setOffline(false)

      chat.retry(selected.id)
      XCTAssertTrue(chat.busy)
      XCTAssertFalse(chat.canResubmit(selected.id))
      chat.resubmit(selected.id)  // A second tap while busy must not send again.
      try await waitForIdle(chat)
      XCTAssertNil(chat.error)
      XCTAssertEqual(chat.messages.map(\.text), ["First", "First answer", "Second", "New answer"])
      XCTAssertEqual(fixture.boundaries, ["msg_second"])
      XCTAssertEqual(fixture.prompts, ["Second"])
      XCTAssertEqual(chat.messages.first?.id, originalIDs.first)
      XCTAssertFalse(chat.canResubmit(selected.id))  // The removed message is stale.

      let retry = try XCTUnwrap(chat.messages.first { $0.text == "Second" })
      chat.retry(retry.id, restarting: true)
      try await waitForIdle(chat)
      XCTAssertNil(chat.error)
      XCTAssertEqual(fixture.boundaries, ["msg_second", "msg_first"])
      XCTAssertEqual(chat.messages.map(\.text), ["Second", "New answer"])

      let restartedIDs = chat.messages.map(\.id)
      let restarted = try XCTUnwrap(chat.messages.first)
      chat.resubmit(restarted.id)
      try await waitForIdle(chat)
      XCTAssertEqual(chat.messages.map(\.text), ["Second", "New answer", "Second", "New answer"])
      XCTAssertEqual(Array(chat.messages.prefix(2).map(\.id)), restartedIDs)
      XCTAssertEqual(fixture.boundaries.count, 2)
      XCTAssertEqual(fixture.prompts, ["Second", "Second", "Second"])
      let saved = try XCTUnwrap(store.host(chat.bookmark.id)?.conversations?.first)
      XCTAssertEqual(saved.sessionID, "ses_test")
      XCTAssertEqual(saved.messages.map(\.text), chat.messages.map(\.text))

      chat.disconnect()
      XCTAssertTrue(chat.canResubmit(restarted.id))
      chat.resubmit(restarted.id)
      try await waitForIdle(chat)
      XCTAssertEqual(fixture.prompts, ["Second", "Second", "Second", "Second"])
    }
  }

  func testFailedRewindDoesNotTrimCachedHistoryOrSendAPrompt() async throws {
    try await withChat { chat, store, fixture, _ in
      fixture.rejectRewind()
      let selected = try XCTUnwrap(chat.messages.first { $0.text == "Second" })
      let before = chat.messages.map(\.id)
      chat.retry(selected.id)
      try await waitForIdle(chat)
      XCTAssertNotNil(chat.error)
      XCTAssertFalse(chat.connected)
      XCTAssertTrue(store.failedHostIDs.contains(chat.bookmark.id))
      XCTAssertEqual(chat.messages.map(\.id), before)
      XCTAssertTrue(fixture.prompts.isEmpty)
      XCTAssertFalse(fixture.mutations.contains("POST /api/session/ses_test/revert/commit"))
    }
  }

  func testDeletingAnArbitraryRemoteMessageRewindsTheHostHistory() async throws {
    try await withChat { chat, _, fixture, _ in
      let selected = try XCTUnwrap(chat.messages.first { $0.text == "First answer" })
      XCTAssertTrue(chat.canDelete(selected.id))

      chat.delete(selected.id)
      try await waitForIdle(chat)

      XCTAssertNil(chat.error)
      XCTAssertEqual(fixture.boundaries, ["msg_answer"])
      XCTAssertEqual(chat.messages.map(\.text), ["First"])
    }
  }

  func testFailedModelResponseKeepsSettingsAndRetryAvailable() async throws {
    try await withChat { chat, store, fixture, _ in
      fixture.rejectNextPrompt()
      chat.send("First attempt")
      try await waitForIdle(chat)
      XCTAssertEqual(chat.error, "This API key has expired.")
      XCTAssertEqual(chat.status, "Session failed")
      XCTAssertTrue(chat.connected)
      XCTAssertFalse(store.failedHostIDs.contains(chat.bookmark.id))
      XCTAssertTrue(chat.canSend)

      await chat.refreshConfiguration()
      XCTAssertNil(chat.settingsError)
      XCTAssertEqual(chat.configurationOptions.first { $0.id == "model" }?.choices.count, 2)
      chat.setConfigurationOption(id: "model", value: .string("other"))
      try await waitForIdle(chat)
      XCTAssertNil(chat.settingsError)
      XCTAssertEqual(
        chat.configurationOptions.first { $0.id == "model" }?.currentValue, .string("other"))

      chat.send("Try the other model")
      try await waitForIdle(chat)
      XCTAssertNil(chat.error)
      XCTAssertTrue(chat.connected)
      XCTAssertEqual(chat.status, "Connected")
      XCTAssertEqual(fixture.prompts, ["First attempt", "Try the other model"])
      XCTAssertEqual(chat.messages.last?.text, "New answer")
    }
  }

  func testSendingWhileDisconnectedReconnectsBeforeSubmittingThePrompt() async throws {
    try await withChat { chat, _, fixture, _ in
      chat.disconnect()
      XCTAssertFalse(chat.connected)
      XCTAssertTrue(chat.canSubmit)

      chat.send("Send after reconnecting")
      XCTAssertTrue(chat.busy)
      XCTAssertEqual(chat.status, "Connecting…")

      try await waitForIdle(chat)
      XCTAssertNil(chat.error)
      XCTAssertTrue(chat.connected)
      XCTAssertEqual(fixture.prompts, ["Send after reconnecting"])
      XCTAssertEqual(chat.messages.suffix(2).map(\.text), ["Send after reconnecting", "New answer"])
    }
  }

  func testGroupedSettingsApplyEverySelectionAndBlockOverlappingActions() async throws {
    try await withChat { chat, _, fixture, _ in
      chat.setConfigurationOptions([
        (id: "model", value: .string("other")),
        (id: "model", value: .string("original")),
      ])
      XCTAssertTrue(chat.busy)
      XCTAssertTrue(chat.settingsLoading)
      chat.send("Do not interleave a prompt")
      chat.setConfigurationOption(id: "model", value: .string("other"))
      try await waitForIdle(chat)

      XCTAssertNil(chat.settingsError)
      XCTAssertFalse(chat.settingsLoading)
      XCTAssertEqual(fixture.selectedModels, ["other", "original"])
      XCTAssertTrue(fixture.prompts.isEmpty)
      XCTAssertEqual(
        chat.configurationOptions.first { $0.id == "model" }?.currentValue, .string("original"))
    }
  }

  func testGroupedSettingsKeepSuccessfulChangesAndStopAfterAnError() async throws {
    try await withChat { chat, _, fixture, _ in
      chat.setConfigurationOptions([
        (id: "model", value: .string("other")),
        (id: "model", value: .string("missing")),
        (id: "model", value: .string("original")),
      ])
      try await waitForIdle(chat)

      XCTAssertNotNil(chat.settingsError)
      XCTAssertFalse(chat.settingsLoading)
      XCTAssertTrue(chat.canSend)
      XCTAssertEqual(fixture.selectedModels, ["other"])
      XCTAssertEqual(
        chat.configurationOptions.first { $0.id == "model" }?.currentValue, .string("other"))
    }
  }

  private func waitForIdle(_ chat: RemoteAgentChat) async throws {
    for _ in 0..<500 {
      if !chat.busy { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Remote operation did not finish")
    throw URLError(.timedOut)
  }

  private func withChat(
    _ body:
      @MainActor (
        RemoteAgentChat, RemoteAgentStore, RemoteActionEndpoint, @MainActor (Bool) -> Void
      ) async throws
      -> Void
  ) async throws {
    let fixture = RemoteActionEndpoint()
    let host = "actions-\(UUID().uuidString.lowercased()).example"
    RemoteActionURLProtocol.install(fixture, host: host)
    defer { RemoteActionURLProtocol.remove(host: host) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RemoteAgentStore(file: directory.appendingPathComponent("connections.json"))
    let connection = try OpenCodeConnection(
      url: XCTUnwrap(URL(string: "https://\(host)")), token: "test", cwd: "/work")
    let id = try store.add(connection)
    defer { store.remove(id) }
    let bookmark = try XCTUnwrap(store.host(id))
    var offline = false
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteActionURLProtocol.self]
    let chat = RemoteAgentChat(
      bookmark: bookmark, conversation: .init(cwd: "/work", sessionID: "ses_test"),
      store: store, isOffline: { offline }, httpConfiguration: configuration)
    defer { chat.disconnect() }
    chat.connect()
    try await waitForIdle(chat)
    XCTAssertTrue(chat.connected, chat.error ?? "Not connected")
    try await body(chat, store, fixture, { offline = $0 })
  }
}

private final class RemoteActionEndpoint: @unchecked Sendable {
  private let lock = NSLock()
  private var history: [[String: JSONValue]] = [
    ["id": .string("msg_first"), "type": .string("user"), "text": .string("First")],
    [
      "id": .string("msg_answer"), "type": .string("assistant"),
      "content": .array([.object(["type": .string("text"), "text": .string("First answer")])]),
    ],
    ["id": .string("msg_second"), "type": .string("user"), "text": .string("Second")],
    [
      "id": .string("msg_last"), "type": .string("assistant"),
      "content": .array([.object(["type": .string("text"), "text": .string("Old answer")])]),
    ],
  ]
  private var recordedBoundaries: [String] = []
  private var recordedPrompts: [String] = []
  private var recordedMutations: [String] = []
  private var recordedModels: [String] = []
  private var failRewind = false
  private var failNextPrompt = false
  private var model = "original"
  var boundaries: [String] { lock.withLock { recordedBoundaries } }
  var prompts: [String] { lock.withLock { recordedPrompts } }
  var mutations: [String] { lock.withLock { recordedMutations } }
  var selectedModels: [String] { lock.withLock { recordedModels } }
  func rejectRewind() { lock.withLock { failRewind = true } }
  func rejectNextPrompt() { lock.withLock { failNextPrompt = true } }

  func respond(_ request: URLRequest) throws -> (Int, Data) {
    try lock.withLock {
      let method = request.httpMethod ?? "GET"
      let path = request.url!.path
      if method != "GET" { recordedMutations.append(method + " " + path) }
      var data = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
          let count = stream.read(&bytes, maxLength: bytes.count)
          if count <= 0 { break }
          data.append(contentsOf: bytes.prefix(count))
        }
      }
      let input =
        data.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: data).objectValue
      let result: JSONValue
      switch (method, path) {
      case ("GET", "/api/session/ses_test"):
        result = .object([
          "data": .object([
            "location": .object(["directory": .string("/work")]),
            "model": .object(["id": .string(model), "providerID": .string("test")]),
          ])
        ])
      case ("GET", "/api/model"):
        result = .object([
          "data": .array(["original", "other"].map {
            .object(["id": .string($0), "name": .string($0), "providerID": .string("test")])
          })
        ])
      case ("GET", "/api/agent"):
        result = .object(["data": .array([])])
      case ("POST", "/api/session/ses_test/model"):
        model = try XCTUnwrap(input?["model"]?.objectValue?["id"]?.stringValue)
        recordedModels.append(model)
        result = .null
      case ("GET", "/api/session/ses_test/message"), ("GET", "/api/session/ses_test/context"):
        result = .object(["data": .array(history.map(JSONValue.object))])
      case ("POST", "/api/session/ses_test/revert/stage"):
        XCTAssertEqual(input?["files"], .bool(false))
        if failRewind { return (409, Data("{}".utf8)) }
        recordedBoundaries.append(try XCTUnwrap(input?["messageID"]?.stringValue))
        result = .null
      case ("POST", "/api/session/ses_test/revert/commit"):
        let index = try XCTUnwrap(
          history.firstIndex { $0["id"]?.stringValue == recordedBoundaries.last })
        history.removeSubrange(index...)
        result = .null
      case ("POST", "/api/session/ses_test/prompt"):
        let text = try XCTUnwrap(input?["text"]?.stringValue)
        recordedPrompts.append(text)
        history.append([
          "id": .string(UUID().uuidString), "type": .string("user"), "text": .string(text),
        ])
        if !failNextPrompt {
          history.append([
            "id": .string(UUID().uuidString), "type": .string("assistant"),
            "content": .array([.object(["type": .string("text"), "text": .string("New answer")])]),
          ])
        }
        history.append([
          "id": .string(UUID().uuidString), "type": .string("idle"),
          "outcome": .string(failNextPrompt ? "failed" : "succeeded"),
          "error": failNextPrompt
            ? .object(["message": .string("This API key has expired.")]) : .null,
        ])
        failNextPrompt = false
        result = .null
      case ("POST", "/api/experimental/session/ses_test/wait"):
        result = .null
      case ("GET", "/api/session/ses_test/permission"):
        result = .object(["data": .array([])])
      default:
        XCTFail("Unexpected request: \(method) \(path)")
        throw URLError(.unsupportedURL)
      }
      return (200, try JSONEncoder().encode(result))
    }
  }
}

private final class RemoteActionURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var endpoints: [String: RemoteActionEndpoint] = [:]
  static func install(_ fixture: RemoteActionEndpoint, host: String) {
    lock.withLock { endpoints[host] = fixture }
  }
  static func remove(host: String) {
    lock.withLock { endpoints[host] = nil }
  }
  override class func canInit(with request: URLRequest) -> Bool {
    lock.withLock { endpoints[request.url?.host ?? ""] != nil }
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let fixture = try Self.lock.withLock {
        try XCTUnwrap(Self.endpoints[request.url?.host ?? ""])
      }
      let (status, data) = try fixture.respond(request)
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}
