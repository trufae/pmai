import Foundation
import Synchronization
import Testing

@testable import MaiCore
@testable import MaiStandardTools

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private let reviewSHA = String(repeating: "a", count: 40)
private let suggestion =
  "Keep the early return.\n```suggestion\nif (!ok) {\n  return false;\n}\n```"

private func reviewTestSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [GitHubReviewProtocol.self]
  return URLSession(configuration: configuration)
}

@Test("GitHub review tools are registered, internet-dependent, and approval classified")
func githubReviewCatalog() throws {
  let tools = MaiGitHubTool.makeTools(apiKey: "test-token")
  for name in ["github_pr_comments", "github_comment", "github_review", "github_create_pr"] {
    let definition = try #require(tools.first { $0.definition.name == name }?.definition)
    #expect(MaiGitHubTool.toolNames.contains(name))
    #expect(definition.annotations.requiresInternet)
    #expect(definition.annotations.approval == .confirm)
    #expect(!definition.annotations.concurrent)
    #expect(definition.annotations.readOnly == (name == "github_pr_comments"))
    #expect(definition.annotations.idempotent == (name == "github_pr_comments"))
    #expect(!definition.parameters.contains { $0.name == "token" || $0.name == "apiKey" })
  }
  let review = try #require(MaiGitHubTool(name: "github_review")?.definition)
  let valid: JSONValue = .object([
    "repo": .string("owner/repo"), "number": .integer(7), "commit_id": .string(reviewSHA),
    "body": .string("Please fix this."),
    "comments": .array([
      .object([
        "path": .string("src/a.c"), "line": .integer(12), "body": .string(suggestion),
      ])
    ]),
  ])
  #expect(ToolSchemaValidator.validate(arguments: valid, definition: review) == nil)
  var invalid = try #require(valid.objectValue)
  invalid["comments"] = .array([.object(["path": .string("src/a.c")])])
  #expect(ToolSchemaValidator.validate(arguments: .object(invalid), definition: review) != nil)
}

@Test("GitHub posts conversation comments on issues and PRs without changing Markdown")
func githubPostComments() async {
  let session = reviewTestSession()
  defer { session.invalidateAndCancel() }
  for number in [7, 8] {
    let result = await MaiGitHubTool.execute(
      name: MaiGitHubTool.commentName,
      arguments: [
        "repo": .string("owner/repo"), "number": .integer(number), "body": .string(suggestion),
      ],
      apiKey: " test-token \n", session: session)
    #expect(
      result == "Created (id: 101): https://github.com/owner/repo/issues/\(number)#issuecomment-101"
    )
  }
}

@Test("GitHub submits one batch review with single-line, multiline suggestions and LEFT comments")
func githubPostReview() async {
  let session = reviewTestSession()
  defer { session.invalidateAndCancel() }
  for event in ["COMMENT", "APPROVE", "REQUEST_CHANGES"] {
    var arguments: [String: JSONValue] = [
      "repo": .string("owner/repo"), "number": .integer(7), "commit_id": .string(reviewSHA),
      "body": .string("Please fix this."),
      "comments": .array([
        .object(["path": .string("src/a.c"), "line": .integer(12), "body": .string(suggestion)]),
        .object([
          "path": .string("src/b.c"), "start_line": .integer(20), "line": .integer(21),
          "body": .string(suggestion),
        ]),
        .object([
          "path": .string("src/c.c"), "side": .string("LEFT"), "line": .integer(5),
          "body": .string("Why remove this?"),
        ]),
      ]),
    ]
    if event != "COMMENT" { arguments["event"] = .string(event) }
    let result = await MaiGitHubTool.execute(
      name: MaiGitHubTool.reviewName, arguments: arguments, apiKey: "test-token", session: session)
    #expect(
      result == "Created (id: 102): https://github.com/owner/repo/pull/7#pullrequestreview-102")
  }
  let approval = await MaiGitHubTool.execute(
    name: MaiGitHubTool.reviewName,
    arguments: [
      "repo": .string("owner/repo"), "number": .integer(8), "commit_id": .string(reviewSHA),
      "event": .string("APPROVE"),
    ],
    apiKey: "test-token", session: session)
  #expect(!approval.hasPrefix("Error:"))
}

@Test("GitHub creates normal and draft PRs from pushed branches, including forks")
func githubCreatePR() async {
  let session = reviewTestSession()
  defer { session.invalidateAndCancel() }
  for draft in [false, true] {
    var arguments: [String: JSONValue] = [
      "repo": .string("owner/repo"), "head": .string(draft ? "contributor:fix" : "fix"),
      "base": .string("main"), "title": .string("Fix review tools"),
    ]
    if draft {
      arguments["draft"] = .bool(true)
      arguments["body"] = .string("Description\n\n- Tested locally.")
    }
    let result = await MaiGitHubTool.execute(
      name: MaiGitHubTool.createPRName, arguments: arguments, apiKey: "test-token", session: session
    )
    #expect(result == "Created #9 (id: 103): https://github.com/owner/repo/pull/9")
  }
}

@Test("GitHub discussion paginates all categories and preserves review and reply relationships")
func githubReadDiscussion() async {
  let session = reviewTestSession()
  defer { session.invalidateAndCancel() }
  let result = await MaiGitHubTool.execute(
    name: MaiGitHubTool.prCommentsName,
    arguments: [
      "repo": .string("owner/repo"), "number": .integer(7), "page": .integer(2),
      "limit": .integer(3),
    ],
    session: session)
  for expected in [
    "discussion page 2", "Conversation comments:", "Reviews:", "Inline comments:",
    "id: 101 @author", "id: 102 @reviewer", "state: CHANGES_REQUESTED", "body of review",
    "path: src/a.c", "line: 12", "start_line: 10", "side: RIGHT", "start_side: RIGHT",
    "pull_request_review_id: 102", "in_reply_to_id: 104", "original_line: 11",
    "original_start_line: 9", "commit_id: \(reviewSHA)", "```suggestion", "body of reply",
    "https://github.com/owner/repo/pull/7#discussion_r105",
  ] { #expect(result.contains(expected)) }
  #expect(!result.contains("null"))
  let empty = await MaiGitHubTool.execute(
    name: MaiGitHubTool.prCommentsName,
    arguments: ["repo": .string("owner/repo"), "number": .integer(8)], session: session)
  #expect(empty.components(separatedBy: "None on this page.").count == 4)
}

@Test("GitHub rejects missing credentials and invalid write inputs before making requests")
func githubReviewValidation() async {
  let session = reviewTestSession()
  defer { session.invalidateAndCancel() }
  for name in [MaiGitHubTool.commentName, MaiGitHubTool.reviewName, MaiGitHubTool.createPRName] {
    let result = await MaiGitHubTool.execute(
      name: name, arguments: ["repo": .string("invalid/input")], apiKey: " \n", session: session)
    #expect(result.contains("configure a GitHub token"))
  }
  let base: [String: JSONValue] = [
    "repo": .string("invalid/input"), "number": .integer(1), "commit_id": .string(reviewSHA),
    "body": .string("Please fix this."),
  ]
  for (key, value): (String, JSONValue) in [
    ("commit_id", .string("main")), ("event", .string("PENDING")),
    ("body", .string(" \n")), ("comments", .string("[]")),
    ("comments", .array([.string("invalid")])),
  ] {
    var arguments = base
    arguments[key] = value
    let result = await MaiGitHubTool.execute(
      name: MaiGitHubTool.reviewName, arguments: arguments, apiKey: "test-token", session: session)
    #expect(result.hasPrefix("Error:"))
  }
  for invalid: [String: JSONValue] in [
    ["line": .integer(0)], ["line": .number(1.5)], ["body": .string(" ")],
    ["side": .string("OTHER")], ["start_line": .integer(15)],
    ["start_line": .integer(10)], ["start_line": .integer(0)],
    ["start_side": .string("LEFT")],
    ["start_line": .integer(9), "start_side": .string("OTHER")],
  ] {
    var arguments = base
    let comment: [String: JSONValue] = [
      "path": .string("a.c"), "line": .integer(10), "body": .string("Fix this."),
    ]
    arguments["comments"] = .array([.object(comment.merging(invalid) { _, value in value })])
    let result = await MaiGitHubTool.execute(
      name: MaiGitHubTool.reviewName, arguments: arguments, apiKey: "test-token", session: session)
    #expect(result.hasPrefix("Error:"))
  }
  for (name, extra): (String, [String: JSONValue]) in [
    (MaiGitHubTool.commentName, ["body": .string(" ")]),
    (MaiGitHubTool.commentName, ["number": .integer(0)]),
    (MaiGitHubTool.prCommentsName, ["page": .integer(0)]),
    (MaiGitHubTool.createPRName, [:]),
    (
      MaiGitHubTool.createPRName,
      ["head": .string("fix"), "base": .string("main"), "title": .string(" ")]
    ),
    (
      MaiGitHubTool.createPRName,
      [
        "head": .string("fix"), "base": .string("main"), "title": .string("Fix"),
        "draft": .string("false"),
      ]
    ),
  ] {
    let result = await MaiGitHubTool.execute(
      name: name, arguments: base.merging(extra) { _, value in value }, apiKey: "test-token",
      session: session)
    #expect(result.hasPrefix("Error:"))
  }
}

@Test("GitHub reports failed writes without retrying and rejects malformed responses")
func githubReviewErrors() async {
  let session = reviewTestSession()
  defer { session.invalidateAndCancel() }
  for (repo, expected) in [
    ("error/401", "Check token validity"), ("error/403", "write permissions"),
    ("error/422", "GitHub HTTP 422"), ("error/429", "rate limit exceeded"),
    ("error/malformed", "unexpected GitHub write response"),
    ("error/network", "write outcome is unknown"),
  ] {
    let result = await MaiGitHubTool.execute(
      name: MaiGitHubTool.commentName,
      arguments: ["repo": .string(repo), "number": .integer(7), "body": .string(suggestion)],
      apiKey: "test-token", session: session)
    #expect(result.hasPrefix("Error:"))
    #expect(result.contains(expected))
    #expect(
      GitHubReviewProtocol.writeCounts.withLock { $0["/repos/\(repo)/issues/7/comments"] } == 1)
  }
}

@Test("GitHub refuses redirects for writes, even to the API origin")
func githubWriteRedirects() async {
  for destination in ["https://api.github.com/moved", "https://other.example/moved"] {
    var original = URLRequest(url: URL(string: "https://api.github.com/original")!)
    original.httpMethod = "POST"
    original.httpBody = Data(suggestion.utf8)
    let response = HTTPURLResponse(
      url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
    let redirected = await withCheckedContinuation { continuation in
      GitHubRedirectDelegate().urlSession(
        .shared, task: URLSession.shared.dataTask(with: original),
        willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: destination)!)
      ) { continuation.resume(returning: $0) }
    }
    #expect(redirected == nil)
  }
}

private final class GitHubReviewProtocol: URLProtocol, @unchecked Sendable {
  static let writeCounts = Mutex([String: Int]())
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    #expect(url.host == "api.github.com")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    var status = request.httpMethod == "POST" ? 201 : 200
    var headers: [String: String] = [:]
    var body: JSONValue = .object([:])
    if request.httpMethod == "POST" {
      Self.writeCounts.withLock { $0[url.path, default: 0] += 1 }
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      var data = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          data.append(contentsOf: buffer.prefix(count))
        }
      }
      let payload = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
      #expect(!payload.isEmpty)
      switch url.path {
      case "/repos/owner/repo/issues/7/comments", "/repos/owner/repo/issues/8/comments":
        #expect(payload == ["body": .string(suggestion)])
        let number = url.path.contains("/7/") ? 7 : 8
        body = .object([
          "id": .integer(101),
          "html_url": .string("https://github.com/owner/repo/issues/\(number)#issuecomment-101"),
        ])
      case "/repos/owner/repo/pulls/7/reviews", "/repos/owner/repo/pulls/8/reviews":
        #expect(payload["commit_id"] == .string(reviewSHA))
        #expect(
          ["COMMENT", "APPROVE", "REQUEST_CHANGES"].contains(payload["event"]?.stringValue ?? ""))
        let comments = payload["comments"]?.arrayValue ?? []
        if url.path.contains("/7/") {
          #expect(payload["body"] == .string("Please fix this."))
          #expect(comments.count == 3)
          #expect(comments.first?.objectValue?["body"] == .string(suggestion))
          #expect(comments.first?.objectValue?["side"] == .string("RIGHT"))
          #expect(comments.first?.objectValue?["start_side"] == nil)
          #expect(comments.dropFirst().first?.objectValue?["start_line"] == .integer(20))
          #expect(comments.dropFirst().first?.objectValue?["start_side"] == .string("RIGHT"))
          #expect(comments.last?.objectValue?["side"] == .string("LEFT"))
        } else {
          #expect(payload["event"] == .string("APPROVE"))
          #expect(payload["body"] == .string(""))
          #expect(comments.isEmpty)
        }
        body = .object([
          "id": .integer(102),
          "html_url": .string("https://github.com/owner/repo/pull/7#pullrequestreview-102"),
        ])
      case "/repos/owner/repo/pulls":
        let draft = payload["draft"] == .bool(true)
        #expect(payload["head"] == .string(draft ? "contributor:fix" : "fix"))
        #expect(payload["base"] == .string("main"))
        #expect(payload["title"] == .string("Fix review tools"))
        #expect(payload["body"] == (draft ? .string("Description\n\n- Tested locally.") : nil))
        #expect(payload["repo"] == nil)
        body = .object([
          "id": .integer(103), "number": .integer(9),
          "html_url": .string("https://github.com/owner/repo/pull/9"),
        ])
      case let path where path.hasPrefix("/repos/error/"):
        let scenario = path.split(separator: "/")[2]
        if scenario == "network" {
          client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
          return
        }
        status = Int(scenario) ?? 201
        body = .object(["message": .string("Rejected")])
        if scenario == "429" { headers["x-ratelimit-remaining"] = "0" }
      default:
        Issue.record("Unexpected GitHub write: \(url)")
      }
    } else {
      #expect(request.httpMethod == "GET")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let empty = url.path.contains("/8/")
      #expect(query.contains(URLQueryItem(name: "page", value: empty ? "1" : "2")))
      #expect(query.contains(URLQueryItem(name: "per_page", value: empty ? "10" : "3")))
      if empty {
        body = .array([])
      } else {
        switch url.path {
        case "/repos/owner/repo/issues/7/comments":
          body = .array([
            .object([
              "id": .integer(101), "user": .object(["login": .string("author")]),
              "body": .string("Please review again."),
            ])
          ])
        case "/repos/owner/repo/pulls/7/reviews":
          body = .array([
            .object([
              "id": .integer(102), "user": .object(["login": .string("reviewer")]),
              "state": .string("CHANGES_REQUESTED"), "body": .string("body of review"),
              "submitted_at": .string("2026-10-25T08:00:00Z"),
            ])
          ])
        case "/repos/owner/repo/pulls/7/comments":
          body = .array([
            .object([
              "id": .integer(105), "user": .object(["login": .string("author")]),
              "path": .string("src/a.c"), "line": .integer(12), "start_line": .integer(10),
              "side": .string("RIGHT"), "start_side": .string("RIGHT"),
              "original_line": .integer(11), "original_start_line": .integer(9),
              "pull_request_review_id": .integer(102), "in_reply_to_id": .integer(104),
              "commit_id": .string(reviewSHA), "body": .string("body of reply\n\(suggestion)"),
              "html_url": .string("https://github.com/owner/repo/pull/7#discussion_r105"),
              "original_commit_id": .null,
            ])
          ])
        default:
          Issue.record("Unexpected GitHub read: \(url)")
        }
      }
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(body))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
