import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private func repositoryTestSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [GitHubRepositoryProtocol.self]
  return URLSession(configuration: configuration)
}

@Test("GitHub repository discovery tools are registered without requiring a repository")
func githubRepositoryToolCatalog() throws {
  for name in ["github_list_repos", "github_search_repos"] {
    #expect(MaiGitHubTool.toolNames.contains(name))
    let tool = try #require(MaiGitHubTool(name: name))
    #expect(!tool.definition.parameters.contains { $0.name == "repo" })
    #expect(tool.definition.parameters.contains { $0.name == "page" })
  }
}

@Test("GitHub lists user, organization, and authenticated repositories with pagination")
func githubRepositoryListing() async {
  let session = repositoryTestSession()
  defer { session.invalidateAndCancel() }
  for (arguments, token): ([String: JSONValue], String) in [
    (["owner": .string(" octocat \n"), "limit": .integer(100), "page": .integer(2)], ""),
    (["owner": .string("radareorg"), "owner_type": .string(" ORG "), "limit": .integer(0)], ""),
    ([:], " test-token \n"),
  ] {
    let result = await MaiGitHubTool.execute(
      name: MaiGitHubTool.listReposName, arguments: arguments, apiKey: token, session: session)
    #expect(!result.hasPrefix("Error:"))
    #expect(result.contains("[octocat/Hello-World](https://github.com/octocat/Hello-World)"))
    #expect(result.contains("private, fork, archived, Swift, 42 stars, default branch: main"))
    #expect(result.contains("An example repository"))
    #expect(result.contains("[octocat/no-description]"))
    #expect(!result.contains("null"))
  }
}

@Test("GitHub repository search preserves qualifiers and returns useful repository summaries")
func githubRepositorySearch() async {
  let session = repositoryTestSession()
  defer { session.invalidateAndCancel() }
  let result = await MaiGitHubTool.execute(
    name: MaiGitHubTool.searchReposName,
    arguments: [
      "query": .string(" language:C++ stars:>100 & topic:tools \n"),
      "limit": .integer(5), "page": .integer(3),
    ], session: session)
  #expect(result.contains("123 matches, page 3, 2 shown"))
  #expect(result.contains("[octocat/Hello-World](https://github.com/octocat/Hello-World)"))
  #expect(result.contains("An example repository"))
}

@Test("GitHub repository discovery handles empty, incomplete, malformed, and failed responses")
func githubRepositoryResponses() async {
  let session = repositoryTestSession()
  defer { session.invalidateAndCancel() }
  let empty = await MaiGitHubTool.execute(
    name: MaiGitHubTool.listReposName, arguments: ["owner": .string("empty")], session: session)
  #expect(empty == "No repositories found for empty (page 1).")
  for (query, expected, isError) in [
    ("empty", "0 matches", false),
    ("incomplete", "incomplete search results", false),
    ("malformed", "unexpected GitHub response", true),
    ("rate-limited", "rate limit exceeded", true),
  ] {
    let result = await MaiGitHubTool.execute(
      name: MaiGitHubTool.searchReposName, arguments: ["query": .string(query)], session: session)
    #expect(result.contains(expected))
    #expect(result.hasPrefix("Error:") == isError)
  }
}

@Test("GitHub repository discovery rejects invalid input before making a request")
func githubRepositoryInputValidation() async {
  let session = repositoryTestSession()
  defer { session.invalidateAndCancel() }
  for (name, arguments, expected): (String, [String: JSONValue], String) in [
    (MaiGitHubTool.listReposName, [:], "provide owner or configure a GitHub token"),
    (MaiGitHubTool.listReposName, ["owner": .string("../octocat")], "owner must be"),
    (MaiGitHubTool.listReposName, ["owner_type": .string("invalid")], "owner_type must be"),
    (MaiGitHubTool.listReposName, ["owner_type": .string("org")], "owner is required"),
    (MaiGitHubTool.searchReposName, [:], "query is required"),
    (MaiGitHubTool.searchReposName, ["query": .string(" \n")], "query is required"),
  ] {
    let result = await MaiGitHubTool.execute(
      name: name, arguments: arguments, apiKey: " \n", session: session)
    #expect(result.hasPrefix("Error:"))
    #expect(result.contains(expected))
  }
  for page: JSONValue in [
    .integer(0), .integer(-1), .number(1.5), .number(.infinity), .number(.nan),
  ] {
    for name in [MaiGitHubTool.listReposName, MaiGitHubTool.searchReposName] {
      let result = await MaiGitHubTool.execute(
        name: name,
        arguments: ["owner": .string("octocat"), "query": .string("swift"), "page": page],
        session: session)
      #expect(result == "Error: page must be a positive integer.")
    }
  }
}

private final class GitHubRepositoryProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let query = Dictionary(
      uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        ?? [])
        .map { ($0.name, $0.value ?? "") })
    #expect(url.host == "api.github.com")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == (url.path == "/user/repos" ? "Bearer test-token" : nil))

    let repositories = """
      [{"full_name":"octocat/Hello-World","html_url":"https://github.com/octocat/Hello-World",
        "description":"An example repository","language":"Swift","stargazers_count":42,
        "private":true,"fork":true,"archived":true,"default_branch":"main"},
       {"full_name":"octocat/no-description","description":null,"language":null}]
      """
    var status = 200
    var headers: [String: String] = [:]
    let body: String
    switch url.path {
    case "/users/octocat/repos", "/orgs/radareorg/repos", "/user/repos", "/users/empty/repos":
      #expect(query["sort"] == "updated")
      #expect(query["direction"] == "desc")
      #expect(query["page"] == (url.path == "/users/octocat/repos" ? "2" : "1"))
      #expect(
        query["per_page"]
          == (url.path == "/users/octocat/repos"
            ? "30" : url.path == "/orgs/radareorg/repos" ? "1" : "10"))
      body = url.path == "/users/empty/repos" ? "[]" : repositories
    case "/search/repositories":
      switch query["q"] {
      case "language:C++ stars:>100 & topic:tools":
        #expect(!url.absoluteString.contains("+"))
        #expect(url.absoluteString.contains("C%2B%2B"))
        #expect(query["per_page"] == "5")
        #expect(query["page"] == "3")
        body = "{\"total_count\":123,\"incomplete_results\":false,\"items\":\(repositories)}"
      case "empty":
        body = "{\"total_count\":0,\"incomplete_results\":false,\"items\":[]}"
      case "incomplete":
        body = "{\"total_count\":2,\"incomplete_results\":true,\"items\":\(repositories)}"
      case "malformed":
        body = "{}"
      case "rate-limited":
        status = 403
        headers["x-ratelimit-remaining"] = "0"
        body = "{}"
      default:
        Issue.record("Unexpected repository search request: \(url)")
        body = "{}"
      }
    default:
      Issue.record("Unexpected repository request: \(url)")
      body = "{}"
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
