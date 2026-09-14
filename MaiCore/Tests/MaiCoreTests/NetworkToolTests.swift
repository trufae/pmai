import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

private let networkTestContext = ToolExecutionContext(
  run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
  modelTurn: 1)

@Test("Standard tool factory exposes the portable network tools")
func standardFactoryIncludesNetworkTools() async throws {
  let tools = try await MaiStandardToolFactory().makeTools(
    context: PluginFactoryContext(id: "standard"))
  let names = Set(tools.map(\.definition.name))

  #expect(names.contains(MaiWeatherTool.name))
  #expect(names.contains(MaiWebSearchTool.name))
  #expect(names.contains(MaiWebFetchTool.name))
  #expect(names.contains(MaiMastodonTool.name))
  #expect(Set(MaiGitHubTool.toolNames).isSubset(of: names))
}

@Test("Standard tool factory can select and configure network tools")
func standardFactoryConfiguresNetworkTools() async throws {
  let tools = try await MaiStandardToolFactory().makeTools(
    context: PluginFactoryContext(
      id: "network",
      options: [
        "tools": .array([.string(MaiWebSearchTool.name), .string(MaiMastodonTool.name)]),
        "webSearchProvider": .string(MaiWebSearchProvider.searXNG.rawValue),
        "searXNGURL": .string("search.example.com"),
        "mastodonInstance": .string("social.example.com"),
        "mastodonAPIKeyEnvironment": .string("SOCIAL_TOKEN"),
        "mastodonWriteEnabled": .bool(true),
      ],
      environment: ["SOCIAL_TOKEN": "secret"]))

  #expect(tools.map(\.definition.name) == [MaiWebSearchTool.name, MaiMastodonTool.name])
  let search = try #require(tools[0] as? MaiWebSearchTool)
  #expect(search.configuration.provider == .searXNG)
  #expect(search.configuration.searXNGURL == "search.example.com")
  let mastodon = try #require(tools[1] as? MaiMastodonTool)
  #expect(mastodon.configuration.instance == "social.example.com")
  #expect(mastodon.configuration.apiKey == "secret")
  #expect(mastodon.configuration.writeEnabled)
}

@Test("Network tools reject invalid input without issuing requests")
func networkToolsValidateInput() async throws {
  let fetch = try await MaiWebFetchTool().call(
    arguments: .object(["url": .string("file:///etc/passwd")]),
    context: networkTestContext)
  #expect(fetch.isError)
  #expect(fetch.text == "Error: provide a valid HTTP or HTTPS URL.")

  let mastodon = try await MaiMastodonTool().call(
    arguments: .object([
      "action": .string("post"),
      "content": .string("hello"),
    ]),
    context: networkTestContext)
  #expect(mastodon.isError)
  #expect(mastodon.text.contains("disabled"))
}

@Test("Shared GitHub tool accepts common repository forms")
func githubRepositoryNormalization() {
  #expect(MaiGitHubTool.repoPath("torvalds/linux") == "torvalds/linux")
  #expect(MaiGitHubTool.repoPath("https://github.com/apple/swift.git") == "apple/swift")
  #expect(MaiGitHubTool.repoPath("git@github.com:radareorg/radare2.git") == "radareorg/radare2")
  #expect(MaiGitHubTool.repoPath("not-a-repository") == nil)
}

@Test("Shared web fetch cleaner extracts readable HTML")
func webFetchCleanerExtractsHTML() {
  let result = WebFetchContentCleaner.clean(
    "<html><head><title>A &amp; B</title></head><body><nav>Skip</nav><main>Hello&nbsp;world</main></body></html>",
    contentType: "text/html")
  #expect(result.title == "A & B")
  #expect(result.text == "Hello world")
}

@Test("Shared weather service retains deterministic moon phase calculation")
func weatherMoonPhase() {
  let reference = Date(timeIntervalSince1970: 947_182_440)
  let phase = MaiWeatherService.moonPhase(for: reference)
  #expect(phase.name == "New Moon")
  #expect(abs(phase.illumination) < 0.000_001)
}

@Test("Web fetch preserves raw source, whitespace, entities and repeated closing braces")
func webFetchPreservesSource() {
  let source = "func example() {\r\n  if true {\r\n    print(\"<html><body>&amp;</body></html>\")\r\n  }\r\n}\r\n}\r\n\r\n"
  for mime in ["text/plain; charset=utf-8", "application/json", "text/x-swift", "application/xml", nil] {
    #expect(WebFetchContentCleaner.clean(source, contentType: mime).text == source)
  }
  let text = "<html>an example in a plain text file</html>"
  #expect(WebFetchContentCleaner.clean(text, contentType: "text/plain").text == text)
  #expect(WebFetchContentCleaner.clean("<html><body>page</body></html>", contentType: nil).text == "page")
}
