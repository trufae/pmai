import Foundation
import MaiCore
import Testing
@testable import MaiMobile

private actor StreamingProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(id: "fixture", displayName: "Fixture")
  func availableModels() async throws -> [ModelDescriptor] { [ModelDescriptor(id: "fixture")] }
  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws -> ProviderResponse {
    await emit(.textDelta("Partial reply"))
    try await Task.sleep(for: .seconds(30))
    return ProviderResponse(message: .assistant("Complete reply"), stopReason: .stop)
  }
}

private actor ToolProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(id: "fixture", displayName: "Fixture", capabilities: [.nativeToolCalling, .streaming])
  func availableModels() async throws -> [ModelDescriptor] { [ModelDescriptor(id: "fixture")] }
  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws -> ProviderResponse {
    if request.messages.contains(where: { !$0.toolResults.isEmpty }) {
      await emit(.textDelta("5"))
      return ProviderResponse(message: .assistant("5"), stopReason: .stop)
    }
    return ProviderResponse(message: AgentMessage(role: .assistant, content: [
      .toolCall(.init(id: "calculate", name: "calc", arguments: .object(["expression": .string("2 + 3")]))),
    ]), stopReason: .toolCall)
  }
}

private actor CaptureProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(id: "fixture", displayName: "Fixture")
  var requests: [ProviderRequest] = []
  func availableModels() async throws -> [ModelDescriptor] { [] }
  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws -> ProviderResponse {
    requests.append(request)
    return ProviderResponse(message: .assistant("**Saved answer**"), stopReason: .stop)
  }
}

private func command(_ fields: [String: String]) throws -> String {
  String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
}

// Prevent tools running without a user decision and transcripts losing tool
// results when the native engine saves a completed agent turn.
@Test(.timeLimit(.minutes(1))) @MainActor func toolApprovalAndTranscriptPersist() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = ToolProvider()
  let (updates, continuation) = AsyncStream<String>.makeStream()
  defer { continuation.finish() }
  let engine = try MobileEngine(directory: directory, update: { continuation.yield($0) }, makeProvider: { _ in provider })
  engine.observe()
  engine.execute(try command(["action": "toolsEnabled", "enabled": "true"]))
  engine.execute(try command(["action": "model", "id": "fixture"]))
  engine.execute(try command(["action": "send", "text": "Calculate 2 + 3"]))
  var iterator = updates.makeAsyncIterator()
  var approvalSeen = false
  while let update = await iterator.next() {
    let snapshot = try state(update)
    let agent = snapshot["agent"] as? [String: Any]
    if let approval = (agent?["approvals"] as? [[String: String]])?.first {
      #expect(approval["name"] == "calc")
      approvalSeen = true
      engine.execute(try command(["action": "toolApproval", "id": try #require(approval["id"]), "choice": "approve"]))
    }
    if approvalSeen, snapshot["isGenerating"] as? Bool == false { break }
  }
  #expect(approvalSeen)
  let reloaded = try MobileEngine(directory: directory, update: { _ in })
  let messages = try #require(state(reloaded.snapshotJSON())["messages"] as? [[String: Any]])
  #expect(messages.last?["text"] as? String == "5")
  #expect(messages.contains { $0["role"] as? String == "tool" && ($0["text"] as? String)?.contains("5") == true })
}
private func state(_ json: String) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@Test @MainActor func multipleProvidersRetainIndependentCredentials() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let engine = try MobileEngine(directory: directory, update: { _ in })
  engine.execute(try command(["action": "provider", "baseURL": "https://one.example/v1", "apiKey": "one-key", "model": "one", "name": "First"]))
  engine.execute(try command(["action": "provider", "id": "second", "name": "Second", "baseURL": "https://two.example/v1", "apiKey": "two-key", "model": "two"]))
  engine.execute(try command(["action": "selectProvider", "id": "openai"]))
  let reloaded = try MobileEngine(directory: directory, update: { _ in })
  #expect(reloaded.chat.providers.count == 2)
  #expect(reloaded.chat.apiKey == "one-key")
  #expect(reloaded.chat.providers.first { $0.id == "second" }?.apiKey == "two-key")
  #expect(reloaded.chat.model == "one")
}

// Folder removal must keep conversations, and message editing must preserve
// attachment content in both the provider request and the saved transcript.
@Test @MainActor func folderAndMessageChangesPreserveAttachments() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = CaptureProvider()
  let engine = try MobileEngine(directory: directory, update: { _ in }, makeProvider: { _ in provider })
  engine.execute(try command(["action": "saveFolder", "name": "Work"]))
  let organization = try #require(state(engine.snapshotJSON())["organization"] as? [String: Any])
  let folder = try #require((organization["folders"] as? [[String: String]])?.first?["id"])
  engine.execute(try command(["action": "selectFolder", "id": folder]))
  engine.execute(try command(["action": "new"]))
  try engine.chat.chooseModel("fixture")
  let attachment = ContentPart.file(.init(name: "notes.md", mimeType: "text/markdown", text: "# Notes\nDetails"))
  await engine.chat.send("Read this", attachments: [attachment])
  #expect(await provider.requests.first?.messages.last?.content.contains(attachment) == true)
  let user = try #require(engine.chat.messages.first)
  engine.execute(try command(["action": "editMessage", "id": user.id, "text": "Read the notes"]))
  let answer = try #require(engine.chat.messages.last)
  engine.execute(try command(["action": "deleteMessage", "id": answer.id]))
  engine.execute(try command(["action": "removeFolder", "id": folder]))
  let reloaded = try MobileEngine(directory: directory, update: { _ in })
  #expect(reloaded.chat.messages.count == 1)
  #expect(reloaded.chat.messages.first?.content.contains(.text("Read the notes")) == true)
  #expect(reloaded.chat.messages.first?.content.contains(attachment) == true)
  let chats = try #require(state(reloaded.snapshotJSON())["chats"] as? [[String: Any]])
  #expect(chats.count == 1)
  #expect(chats.first?["folderID"] as? String == "unfiled")
}

@Test @MainActor func groupToggleKeepsIndividualToolChoices() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let tools = try MobileTools(directory: directory)
  await tools.loadCatalog()
  let groups = try #require(tools.snapshot["groups"] as? [[String: Any]])
  let group = try #require(groups.first { ($0["tools"] as? [String] ?? []).contains("calc") }?["id"] as? String)
  try tools.configure(["action": "toolEnabled", "name": "calc", "enabled": "false"])
  try tools.configure(["action": "groupEnabled", "id": group, "enabled": "false"])
  try tools.configure(["action": "groupEnabled", "id": group, "enabled": "true"])
  let reloaded = try MobileTools(directory: directory)
  await reloaded.loadCatalog()
  let definitions = try #require(reloaded.snapshot["tools"] as? [[String: Any]])
  #expect(definitions.first { $0["name"] as? String == "calc" }?["enabled"] as? Bool == false)
}

// Prevent losing provider/prompt settings when going through the generated API's
// serialized command boundary, including multiline and non-ASCII input.
@Test @MainActor func settingsCommandsPersist() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let engine = try MobileEngine(directory: directory, update: { _ in })
  engine.execute(try command(["action": "provider", "baseURL": "http://127.0.0.1:8080/v1",
    "apiKey": "fixture-secret", "model": "fixture-model"]))
  engine.execute(try command(["action": "prompt", "name": "Català", "text": "Respon en català.\nBreu." ]))
  let reloaded = try MobileEngine(directory: directory, update: { _ in })
  let snapshot = try state(reloaded.snapshotJSON())
  #expect(snapshot["model"] as? String == "fixture-model")
  #expect(snapshot["apiKey"] as? String == "fixture-secret")
  let prompts = try #require(snapshot["prompts"] as? [[String: String]])
  #expect(prompts.last?["text"] == "Respon en català.\nBreu.")
}

// Prevent a Kotlin observer missing streamed text or a Stop command failing to
// cancel Swift work and save the partial conversation. No live provider needed.
@Test(.timeLimit(.minutes(1))) @MainActor func streamingStopPublishesAndPersists() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = StreamingProvider()
  let (updates, continuation) = AsyncStream<String>.makeStream()
  defer { continuation.finish() }
  let engine = try MobileEngine(directory: directory, update: { continuation.yield($0) },
    makeProvider: { _ in provider })
  engine.observe()
  engine.execute(try command(["action": "model", "id": "fixture"]))
  engine.execute(try command(["action": "send", "text": "Hello"]))
  var iterator = updates.makeAsyncIterator()
  while let update = await iterator.next() {
    if try state(update)["streamedText"] as? String == "Partial reply" { break }
  }
  engine.execute(try command(["action": "stop"]))
  while let update = await iterator.next() {
    let snapshot = try state(update)
    if snapshot["isGenerating"] as? Bool == false && snapshot["status"] as? String == "Stopped" { break }
  }
  let reloaded = try MobileEngine(directory: directory, update: { _ in })
  let messages = try #require(state(reloaded.snapshotJSON())["messages"] as? [[String: Any]])
  #expect(messages.map { $0["text"] as? String } == ["Hello", "Partial reply"])
}
