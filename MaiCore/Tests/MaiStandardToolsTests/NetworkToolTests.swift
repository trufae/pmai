import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

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

  for number: JSONValue in [.number(1e100), .number(.infinity), .number(.nan), .number(1.5)] {
    let invalid = await MaiGitHubTool.execute(name: MaiGitHubTool.prName, arguments: [
      "repo": .string("trufae/pmai"), "number": number,
    ])
    #expect(invalid == "Error: number is required.")
  }
}

@Test("Shared GitHub tool accepts common repository forms")
func githubRepositoryNormalization() {
  #expect(MaiGitHubTool.repoPath("torvalds/linux") == "torvalds/linux")
  #expect(MaiGitHubTool.repoPath("https://github.com/apple/swift.git") == "apple/swift")
  #expect(MaiGitHubTool.repoPath("git@github.com:radareorg/radare2.git") == "radareorg/radare2")
  #expect(MaiGitHubTool.repoPath("not-a-repository") == nil)
}

@Test("GitHub factory resolves optional tokens without exposing them to the model")
func githubFactoryCredentials() async throws {
  for (options, environment, expected): ([String: JSONValue], [String: String], String) in [
    ([:], [:], ""),
    (["githubAPIKey": .string("saved")], [:], "saved"),
    (["githubAPIKey": .string("saved")], ["GITHUB_TOKEN": "environment"], "environment"),
    (["githubAPIKeyEnvironment": .string("GH_TOKEN")], ["GH_TOKEN": "custom"], "custom"),
  ] {
    let tools = try await MaiStandardToolFactory().makeTools(
      context: PluginFactoryContext(id: "github", options: options, environment: environment))
    let github = tools.compactMap { $0 as? MaiGitHubTool }
    #expect(github.count == MaiGitHubTool.toolNames.count)
    #expect(github.allSatisfy { $0.apiKey == expected })
    #expect(github.map(\.definition) == MaiGitHubTool.definitions)
  }
}

@Test(
  "Every GitHub action authenticates all requests only when a token is configured",
  arguments: ["", " \n", " secret "])
func githubAuthenticatedRequests(token: String) async throws {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [GitHubTestProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  for name in MaiGitHubTool.toolNames {
    let result = await MaiGitHubTool.execute(
      name: name,
      arguments: [
        "repo": .string(token.contains("secret") ? "owner/private" : "owner/public"),
        "number": .integer(7), "job_id": .integer(7), "path": .string("README.md"),
        "ref": .string("main"), "sha": .string("abc"),
      ], apiKey: token, session: session)
    #expect(!result.hasPrefix("Error:"), "\(name): \(result)")
  }
}

private final class GitHubTestProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    #expect(url.host == "api.github.com")
    #expect(request.httpMethod == "GET")
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == (url.path.contains("/private/") ? "Bearer secret" : nil))
    let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
    let body: String
    if accept == "application/vnd.github.diff" || accept == "application/vnd.github.raw+json"
      || url.path.hasSuffix("/logs")
    {
      body = "fixture text"
    } else if url.path.hasSuffix("/check-runs") {
      body = "{\"check_runs\":[]}"
    } else if ["7", "abc"].contains(url.lastPathComponent) {
      body = "{}"
    } else {
      body = "[]"
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Test(
  "GitHub redirects remove credentials outside the API origin",
  arguments: [
    "https://api.github.com/moved", "https://logs.example.com/signed",
    "http://api.github.com/moved", "https://api.github.com:8443/moved",
  ])
func githubRedirectCredentials(destination: String) async {
  var request = URLRequest(url: URL(string: destination)!)
  request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
  let response = HTTPURLResponse(
    url: URL(string: "https://api.github.com/original")!,
    statusCode: 302, httpVersion: nil, headerFields: nil)!
  let redirected = await withCheckedContinuation { continuation in
    GitHubRedirectDelegate().urlSession(
      .shared, task: URLSession.shared.dataTask(with: request),
      willPerformHTTPRedirection: response, newRequest: request
    ) { continuation.resume(returning: $0) }
  }
  #expect(
    redirected?.value(forHTTPHeaderField: "Authorization")
      == (destination == "https://api.github.com/moved" ? "Bearer secret" : nil))
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
