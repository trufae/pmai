import MaiCore
import MaiOpenAI
import XCTest

@testable import PocketMai

final class ChatGPTProviderTests: XCTestCase {
  func testOpenAIProviderNamesMigrateAndWriteCanonicalJSON() throws {
    for name in ["openai", "openAICompatible"] {
      let data = Data("\"\(name)\"".utf8)
      let kind = try JSONDecoder().decode(ProviderKind.self, from: data)
      XCTAssertEqual(kind, .openAICompatible)
      XCTAssertEqual(String(decoding: try JSONEncoder().encode(kind), as: UTF8.self), "\"openai\"")
      let voice = try JSONDecoder().decode(TTSVoiceProviderKind.self, from: data)
      XCTAssertEqual(voice, .openAICompatible)
      XCTAssertEqual(String(decoding: try JSONEncoder().encode(voice), as: UTF8.self), "\"openai\"")
      let configured = try JSONDecoder().decode(ConfiguredProviderKind.self, from: data)
      XCTAssertEqual(configured, .openAI)
      XCTAssertEqual(configured.rawValue, "openai")
    }
  }

  func testChatGPTProviderArchivePreservesKindWithoutCredentials() throws {
    let endpoint = OpenAIEndpoint(
      name: "Personal ChatGPT", baseURL: "https://api.openai.com/v1",
      apiKey: "unused-api-key", oauthRefreshToken: "unused-refresh", kind: .chatGPT)
    let exported = ConfiguredProvider(pocketMai: endpoint)
    XCTAssertEqual(exported.kind.rawValue, "chatgpt")
    XCTAssertNil(exported.apiKey)
    XCTAssertNil(exported.options["pocketmai.oauthRefreshToken"])
    let imported = try XCTUnwrap(OpenAIEndpoint(archive: exported))
    XCTAssertEqual(imported.kind, .chatGPT)
    XCTAssertEqual(imported.apiKey, "")
    XCTAssertEqual(imported.oauthRefreshToken, "")
  }

  func testChatGPTConfigWithoutBaseURLImports() throws {
    let imported = try XCTUnwrap(OpenAIEndpoint(archive: .init(id: "chatgpt", kind: .chatGPT)))
    XCTAssertEqual(imported.kind.rawValue, "chatgpt")
    XCTAssertEqual(imported.baseURL, "https://api.openai.com/v1")
  }

  func testChatGPTUsesOwnProviderAndExcludesAudio() async throws {
    let endpoint = OpenAIEndpoint(
      name: "ChatGPT", baseURL: "https://api.openai.com/v1", kind: .chatGPT)
    let provider = try await PocketMaiPluginHost.shared.makeProvider(endpoint: endpoint)
    XCTAssertTrue(provider is ChatGPTProvider)
    XCTAssertTrue(provider.descriptor.capabilities.contains(.nativeToolCalling))
    XCTAssertFalse(provider.descriptor.capabilities.contains(.audioInput))
    let voices = try await OpenAICompatibleProvider.fetchVoices(endpoint: endpoint)
    XCTAssertEqual(voices, [])
  }

  func testChatGPTCanPrepareIOSSignInWithoutDeveloperClientID() async throws {
    let store = ChatGPTCredentialStore(providerID: "test-" + UUID().uuidString)
    let attempt = try await ChatGPTAuth.shared.beginSignIn(
      store: store,
      redirectURI: URL(string: "http://127.0.0.1:54321/auth/callback")!)
    let query = try XCTUnwrap(
      URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(query.first(where: { $0.name == "client_id" })?.value, "dynamic_agent_client")
    XCTAssertTrue(
      query.first(where: { $0.name == "ext_agent_host_id" })?.value?.hasPrefix("urn:uuid:") == true)
    XCTAssertNil(try store.load())
    await ChatGPTAuth.shared.cancelSignIn(attempt)
  }
}
