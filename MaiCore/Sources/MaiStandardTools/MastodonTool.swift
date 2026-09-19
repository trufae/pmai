import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct MaiMastodonConfiguration: Equatable, Sendable {
  public var instance: String
  public var apiKey: String
  public var writeEnabled: Bool

  public init(
    instance: String = "mastodon.social",
    apiKey: String = "",
    writeEnabled: Bool = false
  ) {
    self.instance = instance
    self.apiKey = apiKey
    self.writeEnabled = writeEnabled
  }
}

/// A small Mastodon client deliberately exposed as one tool. The instance and
/// token live in tool settings, rather than becoming separate model tools.
public struct MaiMastodonTool: AgentTool {
  public static let name = "mastodon"

  public static let toolDefinition = ToolDefinition(
    name: name,
    description:
      "Use Mastodon on the configured instance. Run toot_search to find posts by keywords, post a status (optionally as a reply), or list recent posts from a user.",
    parameters: [
      ToolParameterDef(
        name: "action", type: "string",
        description: "Operation: toot_search, post, or user_posts.", required: true),
      ToolParameterDef(
        name: "query", type: "string",
        description: "Keywords for toot_search.", required: false),
      ToolParameterDef(
        name: "content", type: "string",
        description: "Text for post.", required: false),
      ToolParameterDef(
        name: "visibility", type: "string",
        description: "Post visibility: public, unlisted, private, or direct. Default: public.",
        required: false),
      ToolParameterDef(
        name: "username", type: "string",
        description: "Mastodon username or acct for user_posts.", required: false),
      ToolParameterDef(
        name: "reply_to_id", type: "string",
        description: "Status ID to reply to when action is post.", required: false),
      ToolParameterDef(
        name: "limit", type: "integer",
        description: "Number of posts, 1-40. Default: 10.", required: false),
      ToolParameterDef(
        name: "instance", type: "string",
        description: "Optional instance URL override; otherwise use Mastodon settings.",
        required: false),
      ToolParameterDef(
        name: "api_key", type: "string",
        description:
          "Optional API key override; otherwise use Mastodon settings. Never include it in a reply.",
        required: false),
    ])

  public let definition = Self.toolDefinition
  public let configuration: MaiMastodonConfiguration

  public init(configuration: MaiMastodonConfiguration = .init()) {
    self.configuration = configuration
  }

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    let result = await Self.execute(
      arguments: arguments.objectValue ?? [:],
      configuration: configuration)
    return ToolOutput(text: result, isError: result.hasPrefix("Error:"))
  }

  public static func execute(
    arguments: [String: AgentToolArgumentValue],
    configuration: MaiMastodonConfiguration
  ) async -> String {
    let action =
      arguments["action"]?.coercedStringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    let instance =
      arguments["instance"]?.coercedStringValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty ?? configuration.instance.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let baseURL = normalizedBaseURL(instance) else {
      return "Error: configure a valid Mastodon instance URL, such as https://mastodon.social."
    }
    let token = (arguments["api_key"]?.coercedStringValue.nilIfEmpty ?? configuration.apiKey)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    switch action {
    case "toot_search":
      let query =
        arguments["query"]?.coercedStringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !query.isEmpty else { return "Error: query is required for toot_search." }
      return await search(
        query: query, limit: limit(arguments), baseURL: baseURL, token: token)
    case "post":
      let content =
        arguments["content"]?.coercedStringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
      guard !content.isEmpty else { return "Error: content is required for post." }
      guard configuration.writeEnabled else {
        return "Error: Mastodon posting and replying are disabled in Mastodon settings."
      }
      guard !token.isEmpty else {
        return "Error: configure a Mastodon API key before posting."
      }
      return await post(
        content: content,
        replyToID: arguments["reply_to_id"]?.coercedStringValue.nilIfEmpty,
        visibility: arguments["visibility"]?.coercedStringValue.nilIfEmpty ?? "public",
        baseURL: baseURL,
        token: token)
    case "user_posts":
      let username =
        arguments["username"]?.coercedStringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
      guard !username.isEmpty else { return "Error: username is required for user_posts." }
      return await userPosts(
        username: username, limit: limit(arguments), baseURL: baseURL,
        token: token)
    default:
      return "Error: action must be toot_search, post, or user_posts."
    }
  }

  private struct Status: Decodable {
    let id: String
    let content: String
    let createdAt: String
    let url: String?
    let account: Account

    enum CodingKeys: String, CodingKey {
      case id, content
      case createdAt = "created_at"
      case url, account
    }
  }

  private struct Account: Decodable {
    let username: String
    let displayName: String
    enum CodingKeys: String, CodingKey {
      case username
      case displayName = "display_name"
    }
  }

  private struct SearchResult: Decodable { let statuses: [Status] }

  private static func search(query: String, limit: Int, baseURL: URL, token: String) async -> String
  {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("api/v2/search"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "type", value: "statuses"),
      URLQueryItem(name: "resolve", value: "true"),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    guard let url = components?.url else { return "Error: could not build Mastodon search URL." }
    do {
      let result: SearchResult = try await request(url: url, token: token)
      return render(result.statuses, heading: "Mastodon search for \"\(query)\"")
    } catch { return "Error: Mastodon search failed: \(error.localizedDescription)" }
  }

  private static func userPosts(username: String, limit: Int, baseURL: URL, token: String) async
    -> String
  {
    do {
      var lookup = URLComponents(
        url: baseURL.appendingPathComponent("api/v1/accounts/lookup"),
        resolvingAgainstBaseURL: false)
      lookup?.queryItems = [
        URLQueryItem(
          name: "acct", value: username.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
      ]
      guard let lookupURL = lookup?.url else {
        return "Error: could not build Mastodon account URL."
      }
      let account: AccountWithID = try await request(url: lookupURL, token: token)
      var statuses = URLComponents(
        url: baseURL.appendingPathComponent("api/v1/accounts/\(account.id)/statuses"),
        resolvingAgainstBaseURL: false)
      statuses?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
      guard let statusesURL = statuses?.url else {
        return "Error: could not build Mastodon posts URL."
      }
      let posts: [Status] = try await request(url: statusesURL, token: token)
      return render(posts, heading: "Recent posts by @\(account.username)")
    } catch { return "Error: could not fetch Mastodon user posts: \(error.localizedDescription)" }
  }

  private struct AccountWithID: Decodable {
    let id: String
    let username: String
  }

  private static func post(
    content: String, replyToID: String?, visibility: String, baseURL: URL, token: String
  ) async -> String {
    guard ["public", "unlisted", "private", "direct"].contains(visibility) else {
      return "Error: visibility must be public, unlisted, private, or direct."
    }
    var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/statuses"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var payload: [String: String] = ["status": content, "visibility": visibility]
    if let replyToID { payload["in_reply_to_id"] = replyToID }
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
      let status: Status = try await performRequest(request)
      return
        "Posted Mastodon status \(status.id)\(replyToID == nil ? "" : " as a reply").\n\(stripHTML(status.content))\(status.url.map { "\n\($0)" } ?? "")"
    } catch { return "Error: Mastodon post failed: \(error.localizedDescription)" }
  }

  private static func request<T: Decodable>(url: URL, token: String) async throws -> T {
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return try await performRequest(request)
  }

  private static func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw NSError(
        domain: "Mastodon", code: status,
        userInfo: [NSLocalizedDescriptionKey: "HTTP status \(status)"])
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private static func render(_ statuses: [Status], heading: String) -> String {
    guard !statuses.isEmpty else { return "\(heading): no posts found." }
    return heading + ":\n"
      + statuses.map {
        let author =
          $0.account.displayName.isEmpty
          ? "@\($0.account.username)" : "\($0.account.displayName) (@\($0.account.username))"
        return "- [\($0.id)] \(author): \(stripHTML($0.content))\($0.url.map { "\n  \($0)" } ?? "")"
      }.joined(separator: "\n")
  }

  private static func limit(_ arguments: [String: AgentToolArgumentValue]) -> Int {
    min(max(arguments["limit"]?.intValue ?? 10, 1), 40)
  }

  private static func normalizedBaseURL(_ value: String) -> URL? {
    var text = value
    if !text.contains("://") { text = "https://" + text }
    guard var components = URLComponents(string: text), components.scheme == "https",
      components.host != nil
    else { return nil }
    components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.query = nil
    components.fragment = nil
    return components.url
  }

  private static func stripHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
