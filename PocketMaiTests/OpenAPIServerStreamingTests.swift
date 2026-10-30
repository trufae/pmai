import XCTest

@testable import PocketMai

@MainActor
final class OpenAPIServerStreamingTests: XCTestCase {
  func testFirstChunkArrivesBeforeCompletion() async throws {
    for format in [OpenAPIServerCompletionStream.Format.openAI, .ollamaChat, .ollamaGenerate] {
      let firstChunk = expectation(description: "first chunk")
      let gate = AsyncStream<Void>.makeStream()
      let response = OpenAPIServerCompletionStream.response(format: format, model: "test") { update in
        update("Hel")
        for await _ in gate.stream { break }
        update("Hello")
        return OpenAPIServerCompletionOutput(text: "Hello", model: "test")
      }
      XCTAssertTrue(String(decoding: response.serialized(), as: UTF8.self)
        .contains("Transfer-Encoding: chunked"))
      let consumer = Task { () throws -> [String] in
        var chunks: [String] = []
        for try await chunk in try XCTUnwrap(response.stream) {
          chunks.append(String(decoding: chunk, as: UTF8.self))
          if chunks.count == 1 { firstChunk.fulfill() }
        }
        return chunks
      }
      await fulfillment(of: [firstChunk], timeout: 2)
      gate.continuation.yield(())
      gate.continuation.finish()
      let chunks = try await consumer.value
      XCTAssertEqual(chunks.count, 3)
      let objects = try chunks.map { try object($0) }
      XCTAssertEqual(content(objects[0], format: format), "Hel")
      XCTAssertEqual(content(objects[1], format: format), "lo")
      if format == .openAI {
        XCTAssertEqual(objects[0]["id"] as? String, objects[2]["id"] as? String)
        XCTAssertTrue(chunks[2].hasSuffix("data: [DONE]\n\n"))
        let choices = try XCTUnwrap(objects[2]["choices"] as? [[String: Any]])
        XCTAssertEqual(choices[0]["finish_reason"] as? String, "stop")
      } else {
        XCTAssertEqual(objects[2]["done"] as? Bool, true)
      }
    }
  }

  func testUnicodeAndBufferedCompletionDoNotDuplicateText() throws {
    var encoder = OpenAPIServerCompletionStream(format: .ollamaGenerate, model: "test")
    XCTAssertEqual(try object(XCTUnwrap(encoder.update("e")))["response"] as? String, "e")
    XCTAssertEqual(try object(XCTUnwrap(encoder.update("e\u{301}🙂")))["response"] as? String, "\u{301}🙂")
    XCTAssertNil(encoder.update("e\u{301}🙂"))
    let finish = try object(encoder.finish(.init(
      text: "e\u{301}🙂", model: "test",
      toolRuns: [.init(name: "example", argumentsJSON: "{}", result: "ok", isError: false)])))
    XCTAssertEqual(finish["response"] as? String, "")
    XCTAssertEqual((finish["pocketmai_tool_calls"] as? [[String: Any]])?.count, 1)
  }

  func testGenerationErrorUsesStreamErrorWithoutSuccessTerminator() async throws {
    let response = OpenAPIServerCompletionStream.response(format: .openAI, model: "test") { update in
      update("partial")
      throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "broken"])
    }
    var chunks: [String] = []
    for try await chunk in try XCTUnwrap(response.stream) {
      chunks.append(String(decoding: chunk, as: UTF8.self))
    }
    XCTAssertEqual(chunks.count, 2)
    XCTAssertEqual(try object(chunks[1])["error"] as? String, "broken")
    XCTAssertFalse(chunks.joined().contains("[DONE]"))
  }

  func testCancelledConsumerCancelsGeneration() async throws {
    let started = expectation(description: "generation started")
    let cancelled = expectation(description: "generation cancelled")
    let response = OpenAPIServerCompletionStream.response(format: .openAI, model: "test") { update in
      update("partial")
      started.fulfill()
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        cancelled.fulfill()
        throw error
      }
      return .init(text: "unexpected", model: "test")
    }
    let consumer = Task {
      for try await _ in try XCTUnwrap(response.stream) {}
    }
    await fulfillment(of: [started], timeout: 2)
    consumer.cancel()
    await fulfillment(of: [cancelled], timeout: 2)
    _ = try? await consumer.value
  }

  func testCurrentChatToolsExecuteOnlyWhenServerAllowsThem() async throws {
    StubChatEndpoint.install()
    defer { StubChatEndpoint.uninstall() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: directory), monitorNetwork: false)
    let deadline = Date().addingTimeInterval(20)
    while !store.hasLoadedPersistedSettings && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(store.hasLoadedPersistedSettings)
    let endpoint = OpenAIEndpoint(
      name: "Server fixture", baseURL: "https://\(StubChatEndpoint.host)/v1", defaultModel: "server-model")
    store.settings.openAIEndpoints = [endpoint]
    store.settings.toolCallingMode = .text
    store.settings.toolApprovalMode = .yolo
    store.settings.useToolProxy = false
    store.settings.toolPolicy = .init(automatic: false)
    store.settings.agents[0].canSpawnSubagents = false
    store.settings.toolSettings.webSearchProvider = .searXNG
    store.settings.toolSettings.webSearchSearXNGURL = "https://\(StubChatEndpoint.host)"
    store.updateCurrentConversationSettings {
      $0.provider = .openAICompatible
      $0.endpointID = endpoint.id
      $0.modelID = "selected-model"
      $0.enabledTools = [.webSearch]
      $0.enabledMCPServers = []
    }
    let original = try XCTUnwrap(store.currentConversation)
    StubChatEndpoint.script = { request in
      let messages = request["messages"] as? [[String: Any]] ?? []
      let text = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
      let content = text.contains("Rizin search fixture") ? "Found the answer."
        : text.contains("web_search") ? "TOOL_CALL\ntool: web_search\nquery: rizin\nEND_TOOL_CALL"
        : "Tools unavailable."
      return (StubChatEndpoint.completion(content: content), 0)
    }
    let request = OpenAPIServerHTTPRequest(
      method: "POST", path: "/v1/chat/completions", queryItems: [:], headers: [:],
      body: Data(#"{"messages":[{"role":"user","content":"Search for rizin"}],"stream":false}"#.utf8))
    for allowTools in [false, true] {
      store.settings.openAPIServer.allowToolExecution = allowTools
      let response = await store.openAPIServerResponse(for: request)
      XCTAssertEqual(response.statusCode, 200, String(decoding: response.body, as: UTF8.self))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
      let choices = try XCTUnwrap(body["choices"] as? [[String: Any]])
      let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
      XCTAssertEqual(message["content"] as? String, allowTools ? "Found the answer." : "Tools unavailable.")
      XCTAssertEqual(StubChatEndpoint.searchQueries, allowTools ? ["rizin"] : [])
      XCTAssertEqual(store.currentConversation?.messages, original.messages)
    }
  }

  private func object(_ data: Data) throws -> [String: Any] {
    try object(String(decoding: data, as: UTF8.self))
  }

  private func object(_ frame: String) throws -> [String: Any] {
    let line = try XCTUnwrap(frame.split(separator: "\n").first)
    let json = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : String(line)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }

  private func content(_ object: [String: Any], format: OpenAPIServerCompletionStream.Format) -> String? {
    switch format {
    case .openAI:
      let choices = object["choices"] as? [[String: Any]]
      return (choices?.first?["delta"] as? [String: String])?["content"]
    case .ollamaChat: return (object["message"] as? [String: String])?["content"]
    case .ollamaGenerate: return object["response"] as? String
    }
  }
}
