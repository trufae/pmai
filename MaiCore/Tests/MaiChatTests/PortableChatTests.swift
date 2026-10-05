import Foundation
import MaiCore
import Testing

@testable import MaiChat

private actor PortableTestProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(id: "openai", displayName: "Test")
  var requests: [ProviderRequest] = []
  var fail = false
  var suspend = false

  init(fail: Bool = false, suspend: Bool = false) {
    self.fail = fail
    self.suspend = suspend
  }

  func availableModels() async throws -> [ModelDescriptor] {
    [ModelDescriptor(id: "fixture-model"), ModelDescriptor(id: "other-model")]
  }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    await emit(.textDelta("Hello "))
    if fail { throw CocoaError(.fileReadUnknown) }
    if suspend { try await Task.sleep(for: .seconds(30)) }
    await emit(.textDelta("world"))
    return ProviderResponse(message: .assistant("Hello world"), stopReason: .stop)
  }
}

private func portableTestDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("pmai-chat-test-\(UUID())")
}

@Test @MainActor
func portableSettingsAndPromptRoundTrip() throws {
  let directory = portableTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PortableChat(directory: directory)
  store.baseURL = "http://10.0.2.2:8080/v1"
  store.apiKey = "secret"
  store.model = "local-model"
  try store.saveProvider()
  let prompt = try store.savePrompt(
    name: "Translator", text: "Translate to Catalan.\nKeep code intact.")
  let reloaded = try PortableChat(directory: directory)
  #expect(reloaded.baseURL == store.baseURL)
  #expect(reloaded.apiKey == "secret")
  #expect(reloaded.model == "local-model")
  #expect(reloaded.selectedPrompt == prompt)
  let attributes = try FileManager.default.attributesOfItem(
    atPath: directory.appendingPathComponent("settings.json").path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test @MainActor
func portableModelDiscoveryAndStreamingHistory() async throws {
  let directory = portableTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = PortableTestProvider()
  let store = try PortableChat(directory: directory, makeProvider: { _ in provider })
  await store.refreshModels()
  #expect(store.models.map(\.id) == ["fixture-model", "other-model"])
  try store.chooseModel("fixture-model")
  let prompt = try store.savePrompt(name: "Brief", text: "Answer briefly.")
  await store.send("Hello")
  #expect(store.errorMessage == nil)
  #expect(!store.isGenerating)
  #expect(store.messages.map(\.text) == ["Hello", "Hello world"])
  let requests = await provider.requests
  #expect(requests.count == 1)
  #expect(requests[0].model == "fixture-model")
  #expect(requests[0].messages.first?.role == .system)
  #expect(requests[0].messages.first?.text == prompt.text)
  #expect(requests[0].tools.isEmpty)
  #expect(requests[0].toolChoice == .none)
  #expect(requests[0].sessionID == store.chat.sessionID)
  let reloaded = try PortableChat(directory: directory)
  #expect(reloaded.chat.id == store.chat.id)
  #expect(reloaded.chat.messages == store.chat.messages)
  #expect(reloaded.chat.primaryAgent == store.chat.primaryAgent)
  #expect(reloaded.chat.sessionID == store.chat.sessionID)
  #expect(abs(reloaded.chat.updatedAt.timeIntervalSince(store.chat.updatedAt)) < 0.001)
  #expect(reloaded.chats.count == 1)
  try store.newChat()
  #expect(store.messages.isEmpty)
  #expect(store.chats.count == 1)
  try store.openChat(reloaded.chat.id)
  #expect(store.messages.map(\.text) == ["Hello", "Hello world"])
}

@Test @MainActor
func portableInvalidSetupDoesNotAppendMessages() async throws {
  let directory = portableTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PortableChat(directory: directory)
  store.baseURL = "file:///tmp/model"
  store.model = "model"
  await store.send("Hello")
  #expect(store.messages.isEmpty)
  #expect(store.errorMessage == PortableChatError.invalidURL.errorDescription)
  store.baseURL = "https://api.example.com/v1"
  store.model = ""
  await store.send("Hello")
  #expect(store.messages.isEmpty)
  #expect(store.errorMessage == PortableChatError.missingModel.errorDescription)
}

@Test @MainActor
func portableFailurePreservesPartialReply() async throws {
  let directory = portableTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = PortableTestProvider(fail: true)
  let store = try PortableChat(directory: directory, makeProvider: { _ in provider })
  store.model = "model"
  await store.send("Hello")
  #expect(store.errorMessage != nil)
  #expect(!store.isGenerating)
  #expect(store.messages.map(\.text) == ["Hello", "Hello "])
  #expect(try PortableChat(directory: directory).messages == store.messages)
}

@Test @MainActor
func portableStopAndConcurrentSendGuard() async throws {
  let directory = portableTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = PortableTestProvider(suspend: true)
  let store = try PortableChat(directory: directory, makeProvider: { _ in provider })
  store.model = "model"
  store.draft = "Hello"
  store.sendDraft()
  while store.streamedText.isEmpty { await Task.yield() }
  #expect(store.isGenerating)
  #expect(throws: PortableChatError.self) { try store.newChat() }
  await store.send("A second send")
  #expect(await provider.requests.count == 1)
  store.stop()
  while store.isGenerating { await Task.yield() }
  #expect(store.status == "Stopped")
  #expect(store.errorMessage == nil)
  #expect(store.messages.map(\.text) == ["Hello", "Hello "])
}

@Test @MainActor
func portableResumeRetainsOriginalInstructions() async throws {
  let directory = portableTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = PortableTestProvider()
  let store = try PortableChat(directory: directory, makeProvider: { _ in provider })
  store.model = "model"
  let prompt = try store.savePrompt(name: "Custom", text: "Original instructions")
  await store.send("Hello")
  let originalChatID = store.chat.id
  try store.savePrompt(id: prompt.id, name: "Custom", text: "Changed instructions")
  try store.newChat()
  try store.openChat(originalChatID)
  #expect(store.selectedPrompt?.text == "Original instructions")
  await store.send("Again")
  #expect(await provider.requests.last?.messages.first?.text == "Original instructions")
}

@Test @MainActor
func portableCorruptSettingsAreNotOverwritten() throws {
  let directory = portableTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("settings.json")
  let invalid = Data("not json".utf8)
  try invalid.write(to: url)
  #expect(throws: DecodingError.self) { try PortableChat(directory: directory) }
  #expect(try Data(contentsOf: url) == invalid)
}
