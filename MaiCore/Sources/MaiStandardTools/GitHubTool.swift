import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Read-only GitHub tools backed by the public REST API. No authentication is
/// used, so only public repositories are reachable and the unauthenticated
/// rate limit (60 requests/hour per IP) applies.
public struct MaiGitHubTool: AgentTool {
  public static let listPRsName = "github_list_prs"
  public static let prName = "github_pr"
  public static let prDiffName = "github_pr_diff"
  public static let listFilesName = "github_list_files"
  public static let readFileName = "github_read_file"
  public static let commitsName = "github_commits"
  public static let commitName = "github_commit"
  public static let issuesName = "github_issues"
  public static let issueName = "github_issue"
  public static let releasesName = "github_releases"
  public static let ciStatusName = "github_ci_status"
  public static let ciLogName = "github_ci_log"

  public static let toolNames: [String] = [
    listPRsName, prName, prDiffName, listFilesName, readFileName,
    commitsName, commitName, issuesName, issueName, releasesName, ciStatusName, ciLogName,
  ]

  private static let repoParameter = ToolParameterDef(
    name: "repo", type: "string",
    description: "Repository as owner/name, such as torvalds/linux, or a github.com URL.",
    required: true)
  private static let refParameter = ToolParameterDef(
    name: "ref", type: "string",
    description: "Branch, tag, or commit SHA. Omit for the default branch.",
    required: false)
  private static let limitParameter = ToolParameterDef(
    name: "limit", type: "integer",
    description: "Maximum number of results, 1-30. Default: 10.",
    required: false)

  public static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listPRsName,
      description: "List pull requests of a public GitHub repository.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "state", type: "string",
          description: "Filter: open, closed, or all. Default: open.",
          required: false),
        limitParameter,
      ]),
    ToolDefinition(
      name: prName,
      description:
        "Show one pull request: title, author, state, branches, description, and changed files with additions/deletions. Use github_pr_diff for the code changes.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "number", type: "integer",
          description: "Pull request number.", required: true),
      ]),
    ToolDefinition(
      name: prDiffName,
      description: "Fetch the unified diff of a pull request, for code review or bug hunting.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "number", type: "integer",
          description: "Pull request number.", required: true),
      ]),
    ToolDefinition(
      name: listFilesName,
      description: "List files and folders at a path of a public GitHub repository.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "path", type: "string",
          description: "Folder path inside the repository. Omit for the repository root.",
          required: false),
        refParameter,
      ]),
    ToolDefinition(
      name: readFileName,
      description: "Read one text file from a public GitHub repository.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "path", type: "string",
          description: "File path inside the repository, such as src/main.c.",
          required: true),
        refParameter,
      ]),
    ToolDefinition(
      name: commitsName,
      description:
        "List recent commits of a public GitHub repository, optionally for one file or folder. Useful to inspect history or suggest commit messages.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "path", type: "string",
          description: "Only commits touching this file or folder. Omit for all commits.",
          required: false),
        refParameter,
        limitParameter,
      ]),
    ToolDefinition(
      name: commitName,
      description: "Show one commit: message, author, stats, and per-file patches.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "sha", type: "string",
          description: "Commit SHA, full or abbreviated.", required: true),
      ]),
    ToolDefinition(
      name: issuesName,
      description: "List issues of a public GitHub repository.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "state", type: "string",
          description: "Filter: open, closed, or all. Default: open.",
          required: false),
        limitParameter,
      ]),
    ToolDefinition(
      name: issueName,
      description: "Show one issue with its description and comments.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "number", type: "integer",
          description: "Issue number.", required: true),
      ]),
    ToolDefinition(
      name: releasesName,
      description:
        "List releases of a public GitHub repository as markdown, with each release's downloadable assets and source archives as download links.",
      parameters: [
        repoParameter,
        limitParameter,
      ]),
    ToolDefinition(
      name: ciStatusName,
      description:
        "List CI check runs (GitHub Actions jobs and other checks) for a commit, branch, or tag, with status, conclusion, and job IDs for github_ci_log.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "ref", type: "string",
          description:
            "Branch, tag, or commit SHA to check. Use the PR head SHA from github_pr for pull requests.",
          required: true),
      ]),
    ToolDefinition(
      name: ciLogName,
      description:
        "Fetch the log of one GitHub Actions job by its job ID (the check run ID from github_ci_status). Returns the log tail where failures usually appear.",
      parameters: [
        repoParameter,
        ToolParameterDef(
          name: "job_id", type: "integer",
          description: "GitHub Actions job ID from github_ci_status.", required: true),
      ]),
  ]

  public let definition: ToolDefinition

  public init?(name: String) {
    guard let definition = Self.definitions.first(where: { $0.name == name }) else { return nil }
    self.definition = definition
  }

  public static func makeTools() -> [MaiGitHubTool] {
    definitions.compactMap { MaiGitHubTool(name: $0.name) }
  }

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    let result = await Self.execute(
      name: definition.name,
      arguments: arguments.objectValue ?? [:])
    return ToolOutput(text: result, isError: result.hasPrefix("Error:"))
  }

  public static func execute(
    name: String,
    arguments: [String: AgentToolArgumentValue]
  ) async -> String {
    guard let repo = repoPath(arguments["repo"]?.stringValue ?? "") else {
      return "Error: repo is required as owner/name, such as torvalds/linux."
    }
    switch name {
    case listPRsName:
      return await GitHubService.listPullRequests(
        repo: repo, state: stateArgument(arguments), limit: limitArgument(arguments))
    case prName:
      guard let number = numberArgument(arguments, key: "number") else {
        return "Error: number is required."
      }
      return await GitHubService.pullRequest(repo: repo, number: number)
    case prDiffName:
      guard let number = numberArgument(arguments, key: "number") else {
        return "Error: number is required."
      }
      return await GitHubService.pullRequestDiff(repo: repo, number: number)
    case listFilesName:
      return await GitHubService.listFiles(
        repo: repo,
        path: arguments["path"]?.stringValue ?? "",
        ref: arguments["ref"]?.stringValue ?? "")
    case readFileName:
      let path = (arguments["path"]?.stringValue ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty else { return "Error: path is required." }
      return await GitHubService.readFile(
        repo: repo, path: path, ref: arguments["ref"]?.stringValue ?? "")
    case commitsName:
      return await GitHubService.commits(
        repo: repo,
        path: arguments["path"]?.stringValue ?? "",
        ref: arguments["ref"]?.stringValue ?? "",
        limit: limitArgument(arguments))
    case commitName:
      let sha = (arguments["sha"]?.stringValue ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !sha.isEmpty else { return "Error: sha is required." }
      return await GitHubService.commit(repo: repo, sha: sha)
    case issuesName:
      return await GitHubService.listIssues(
        repo: repo, state: stateArgument(arguments), limit: limitArgument(arguments))
    case issueName:
      guard let number = numberArgument(arguments, key: "number") else {
        return "Error: number is required."
      }
      return await GitHubService.issue(repo: repo, number: number)
    case releasesName:
      return await GitHubService.listReleases(repo: repo, limit: limitArgument(arguments))
    case ciStatusName:
      let ref = (arguments["ref"]?.stringValue ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !ref.isEmpty else { return "Error: ref is required." }
      return await GitHubService.ciStatus(repo: repo, ref: ref)
    case ciLogName:
      guard let jobID = numberArgument(arguments, key: "job_id") else {
        return "Error: job_id is required."
      }
      return await GitHubService.ciLog(repo: repo, jobID: jobID)
    default:
      return "Error: unknown GitHub tool."
    }
  }

  /// Accepts owner/name, github.com URLs, and git remote URLs.
  public static func repoPath(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"]
    where s.lowercased().hasPrefix(prefix) {
      s = String(s.dropFirst(prefix.count))
      break
    }
    if s.lowercased().hasSuffix(".git") { s.removeLast(4) }
    let parts = s.split(separator: "/").map(String.init)
    guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
    guard
      parts[0].unicodeScalars.allSatisfy(allowed.contains),
      parts[1].unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    return "\(parts[0])/\(parts[1])"
  }

  private static func stateArgument(_ arguments: [String: AgentToolArgumentValue]) -> String {
    let state = (arguments["state"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["open", "closed", "all"].contains(state) ? state : "open"
  }

  private static func limitArgument(_ arguments: [String: AgentToolArgumentValue]) -> Int {
    let limit = arguments["limit"]?.intValue ?? 10
    return min(max(limit, 1), 30)
  }

  private static func numberArgument(
    _ arguments: [String: AgentToolArgumentValue], key: String
  ) -> Int? {
    guard let number = arguments[key]?.intValue, number > 0 else { return nil }
    return number
  }
}

enum GitHubService {
  private static let userAgent = "mai/1.0 (+https://github.com/trufae/mai)"
  private static let requestTimeout: TimeInterval = 15
  private static let maxBodyChars = 4_000
  private static let maxFileChars = 30_000
  private static let maxDiffChars = 30_000
  private static let maxLogChars = 15_000

  private struct RequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  // MARK: - Pull requests

  static func listPullRequests(repo: String, state: String, limit: Int) async -> String {
    do {
      let data = try await get(
        "/repos/\(repo)/pulls",
        query: [
          URLQueryItem(name: "state", value: state),
          URLQueryItem(name: "per_page", value: String(limit)),
        ])
      guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return "Error: unexpected GitHub response."
      }
      if items.isEmpty { return "No \(state) pull requests in \(repo)." }
      let lines = items.map { pr -> String in
        let number = intValue(pr["number"]).map { "#\($0)" } ?? "#?"
        let title = stringValue(pr["title"]) ?? ""
        let author = stringValue((pr["user"] as? [String: Any])?["login"]) ?? "?"
        let state = prStateLabel(pr)
        let updated = stringValue(pr["updated_at"]) ?? ""
        let draft = (pr["draft"] as? Bool) == true ? " [draft]" : ""
        return "- \(number) [\(state)]\(draft) \(title) (@\(author), updated \(updated))"
      }
      return "Pull requests of \(repo) (\(state)):\n" + lines.joined(separator: "\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func pullRequest(repo: String, number: Int) async -> String {
    do {
      let data = try await get("/repos/\(repo)/pulls/\(number)")
      guard let pr = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return "Error: unexpected GitHub response."
      }
      var lines: [String] = []
      let title = stringValue(pr["title"]) ?? ""
      lines.append("PR #\(number) of \(repo): \(title)")
      let author = stringValue((pr["user"] as? [String: Any])?["login"]) ?? "?"
      lines.append("Author: @\(author)  State: \(prStateLabel(pr))")
      let base = stringValue((pr["base"] as? [String: Any])?["ref"]) ?? "?"
      let head = stringValue((pr["head"] as? [String: Any])?["ref"]) ?? "?"
      let headSHA = stringValue((pr["head"] as? [String: Any])?["sha"]) ?? "?"
      lines.append("Branches: \(head) -> \(base)  Head SHA: \(headSHA)")
      let additions = intValue(pr["additions"]) ?? 0
      let deletions = intValue(pr["deletions"]) ?? 0
      let changed = intValue(pr["changed_files"]) ?? 0
      lines.append("Changes: \(changed) files, +\(additions) -\(deletions)")
      if let body = stringValue(pr["body"]), !body.isEmpty {
        lines.append("")
        lines.append(truncated(body, limit: maxBodyChars))
      }
      let files = await pullRequestFiles(repo: repo, number: number)
      if !files.isEmpty {
        lines.append("")
        lines.append("Changed files:")
        lines.append(files)
      }
      return lines.joined(separator: "\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  private static func pullRequestFiles(repo: String, number: Int) async -> String {
    guard
      let data = try? await get(
        "/repos/\(repo)/pulls/\(number)/files",
        query: [URLQueryItem(name: "per_page", value: "100")]),
      let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return "" }
    return items.map { file in
      let name = stringValue(file["filename"]) ?? "?"
      let status = stringValue(file["status"]) ?? "?"
      let additions = intValue(file["additions"]) ?? 0
      let deletions = intValue(file["deletions"]) ?? 0
      return "- \(name) (\(status), +\(additions) -\(deletions))"
    }.joined(separator: "\n")
  }

  static func pullRequestDiff(repo: String, number: Int) async -> String {
    do {
      let data = try await get(
        "/repos/\(repo)/pulls/\(number)", accept: "application/vnd.github.diff")
      guard let diff = String(data: data, encoding: .utf8), !diff.isEmpty else {
        return "PR #\(number) of \(repo) has an empty diff."
      }
      return "Diff of PR #\(number) of \(repo):\n" + truncated(diff, limit: maxDiffChars)
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Repository contents

  static func listFiles(repo: String, path: String, ref: String) async -> String {
    let cleanPath = normalizedPath(path)
    do {
      let data = try await get(
        "/repos/\(repo)/contents/\(escapedPath(cleanPath))", query: refQuery(ref))
      guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        // A file path returns a single object instead of an array.
        return "Error: '\(cleanPath)' is not a folder. Use github_read_file for files."
      }
      if items.isEmpty { return "Empty folder." }
      let lines = items.map { item -> String in
        let name = stringValue(item["name"]) ?? "?"
        let type = stringValue(item["type"]) ?? "file"
        let size = intValue(item["size"]) ?? 0
        return type == "dir" ? "- \(name)/" : "- \(name) (\(size) bytes)"
      }
      let location = cleanPath.isEmpty ? repo : "\(repo)/\(cleanPath)"
      return "Files in \(location):\n" + lines.joined(separator: "\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func readFile(repo: String, path: String, ref: String) async -> String {
    let cleanPath = normalizedPath(path)
    do {
      let data = try await get(
        "/repos/\(repo)/contents/\(escapedPath(cleanPath))",
        query: refQuery(ref),
        accept: "application/vnd.github.raw+json")
      guard let text = String(data: data, encoding: .utf8) else {
        return "Error: '\(cleanPath)' is not a UTF-8 text file (\(data.count) bytes)."
      }
      return "Content of \(repo)/\(cleanPath):\n" + truncated(text, limit: maxFileChars)
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Commits

  static func commits(repo: String, path: String, ref: String, limit: Int) async -> String {
    var query = [URLQueryItem(name: "per_page", value: String(limit))]
    let cleanPath = normalizedPath(path)
    if !cleanPath.isEmpty {
      query.append(URLQueryItem(name: "path", value: cleanPath))
    }
    let cleanRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanRef.isEmpty {
      query.append(URLQueryItem(name: "sha", value: cleanRef))
    }
    do {
      let data = try await get("/repos/\(repo)/commits", query: query)
      guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return "Error: unexpected GitHub response."
      }
      if items.isEmpty { return "No commits found." }
      let lines = items.map { item -> String in
        let sha = String((stringValue(item["sha"]) ?? "?").prefix(10))
        let commit = item["commit"] as? [String: Any] ?? [:]
        let message =
          (stringValue(commit["message"]) ?? "")
          .components(separatedBy: .newlines).first ?? ""
        let author = commit["author"] as? [String: Any] ?? [:]
        let name = stringValue(author["name"]) ?? "?"
        let date = stringValue(author["date"]) ?? ""
        return "- \(sha) \(date) \(name): \(message)"
      }
      return "Commits of \(repo):\n" + lines.joined(separator: "\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func commit(repo: String, sha: String) async -> String {
    do {
      let data = try await get("/repos/\(repo)/commits/\(sha)")
      guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return "Error: unexpected GitHub response."
      }
      var lines: [String] = []
      let fullSHA = stringValue(item["sha"]) ?? sha
      lines.append("Commit \(fullSHA) of \(repo)")
      let commit = item["commit"] as? [String: Any] ?? [:]
      let author = commit["author"] as? [String: Any] ?? [:]
      let name = stringValue(author["name"]) ?? "?"
      let date = stringValue(author["date"]) ?? ""
      lines.append("Author: \(name)  Date: \(date)")
      if let stats = item["stats"] as? [String: Any] {
        let additions = intValue(stats["additions"]) ?? 0
        let deletions = intValue(stats["deletions"]) ?? 0
        lines.append("Stats: +\(additions) -\(deletions)")
      }
      if let message = stringValue(commit["message"]), !message.isEmpty {
        lines.append("")
        lines.append(truncated(message, limit: maxBodyChars))
      }
      let files = item["files"] as? [[String: Any]] ?? []
      var patches: [String] = []
      for file in files {
        let filename = stringValue(file["filename"]) ?? "?"
        let status = stringValue(file["status"]) ?? "?"
        patches.append("--- \(filename) (\(status))")
        if let patch = stringValue(file["patch"]), !patch.isEmpty {
          patches.append(patch)
        }
      }
      if !patches.isEmpty {
        lines.append("")
        lines.append(truncated(patches.joined(separator: "\n"), limit: maxDiffChars))
      }
      return lines.joined(separator: "\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Issues

  static func listIssues(repo: String, state: String, limit: Int) async -> String {
    do {
      // The /issues endpoint returns pull requests interleaved with issues, so
      // requesting exactly `limit` items and filtering PRs out afterward yields
      // fewer than `limit` issues (or none, when the recent window is all PRs).
      // Over-fetch (at least 20) and trim to `limit` once PRs have been removed.
      let data = try await get(
        "/repos/\(repo)/issues",
        query: [
          URLQueryItem(name: "state", value: state),
          URLQueryItem(name: "per_page", value: String(max(limit, 20))),
        ])
      guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return "Error: unexpected GitHub response."
      }
      // The issues endpoint also returns pull requests; keep plain issues only.
      let issues = items.filter { $0["pull_request"] == nil }.prefix(limit)
      if issues.isEmpty { return "No \(state) issues in \(repo)." }
      let lines = issues.map { issue -> String in
        let number = intValue(issue["number"]).map { "#\($0)" } ?? "#?"
        let title = stringValue(issue["title"]) ?? ""
        let author = stringValue((issue["user"] as? [String: Any])?["login"]) ?? "?"
        let state = stringValue(issue["state"]) ?? "?"
        let comments = intValue(issue["comments"]) ?? 0
        let labels = (issue["labels"] as? [[String: Any]] ?? [])
          .compactMap { stringValue($0["name"]) }
        let labelText = labels.isEmpty ? "" : " [\(labels.joined(separator: ", "))]"
        return "- \(number) [\(state)]\(labelText) \(title) (@\(author), \(comments) comments)"
      }
      return "Issues of \(repo) (\(state)):\n" + lines.joined(separator: "\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func issue(repo: String, number: Int) async -> String {
    do {
      let data = try await get("/repos/\(repo)/issues/\(number)")
      guard let issue = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return "Error: unexpected GitHub response."
      }
      var lines: [String] = []
      let title = stringValue(issue["title"]) ?? ""
      lines.append("Issue #\(number) of \(repo): \(title)")
      let author = stringValue((issue["user"] as? [String: Any])?["login"]) ?? "?"
      let state = stringValue(issue["state"]) ?? "?"
      let created = stringValue(issue["created_at"]) ?? ""
      lines.append("Author: @\(author)  State: \(state)  Created: \(created)")
      if let body = stringValue(issue["body"]), !body.isEmpty {
        lines.append("")
        lines.append(truncated(body, limit: maxBodyChars))
      }
      if let comments = await issueComments(repo: repo, number: number), !comments.isEmpty {
        lines.append("")
        lines.append("Comments:")
        lines.append(comments)
      }
      return lines.joined(separator: "\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  private static func issueComments(repo: String, number: Int) async -> String? {
    guard
      let data = try? await get(
        "/repos/\(repo)/issues/\(number)/comments",
        query: [URLQueryItem(name: "per_page", value: "20")]),
      let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return nil }
    return items.map { comment in
      let author = stringValue((comment["user"] as? [String: Any])?["login"]) ?? "?"
      let date = stringValue(comment["created_at"]) ?? ""
      let body = truncated(stringValue(comment["body"]) ?? "", limit: 1_000)
      return "@\(author) (\(date)):\n\(body)"
    }.joined(separator: "\n---\n")
  }

  // MARK: - Releases

  static func listReleases(repo: String, limit: Int) async -> String {
    do {
      let data = try await get(
        "/repos/\(repo)/releases",
        query: [URLQueryItem(name: "per_page", value: String(limit))])
      guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return "Error: unexpected GitHub response."
      }
      if items.isEmpty { return "No releases in \(repo)." }
      let blocks = items.map { release -> String in
        let tag = stringValue(release["tag_name"]) ?? "?"
        let name = stringValue(release["name"])
        let heading = (name == nil || name == tag) ? tag : "\(tag) — \(name!)"
        var badges: [String] = []
        if (release["prerelease"] as? Bool) == true { badges.append("pre-release") }
        if (release["draft"] as? Bool) == true { badges.append("draft") }
        let badgeText = badges.isEmpty ? "" : " [\(badges.joined(separator: ", "))]"
        let date = stringValue(release["published_at"]) ?? stringValue(release["created_at"]) ?? ""
        let dateText = date.isEmpty ? "" : " (\(date))"

        var lines = ["### \(heading)\(badgeText)\(dateText)"]
        if let page = stringValue(release["html_url"]) {
          lines.append("Release page: \(page)")
        }

        let assets = release["assets"] as? [[String: Any]] ?? []
        let assetLinks = assets.compactMap { asset -> String? in
          guard let url = stringValue(asset["browser_download_url"]) else { return nil }
          let assetName = stringValue(asset["name"]) ?? url
          let size = intValue(asset["size"]).map { " (\(formattedBytes($0)))" } ?? ""
          let downloads = intValue(asset["download_count"]).map { ", \($0) downloads" } ?? ""
          return "- [\(assetName)](\(url))\(size)\(downloads)"
        }
        if assetLinks.isEmpty {
          lines.append("Assets: none")
        } else {
          lines.append("Assets:")
          lines.append(contentsOf: assetLinks)
        }

        // Source archives are always available for a tag, even without assets.
        let escapedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        lines.append(
          "- [Source code (zip)](https://github.com/\(repo)/archive/refs/tags/\(escapedTag).zip)")
        lines.append(
          "- [Source code (tar.gz)](https://github.com/\(repo)/archive/refs/tags/\(escapedTag).tar.gz)"
        )
        return lines.joined(separator: "\n")
      }
      return "Releases of \(repo) (showing \(items.count)):\n\n"
        + blocks.joined(separator: "\n\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  private static func formattedBytes(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
  }

  // MARK: - CI

  static func ciStatus(repo: String, ref: String) async -> String {
    do {
      let data = try await get(
        "/repos/\(repo)/commits/\(ref)/check-runs",
        query: [URLQueryItem(name: "per_page", value: "50")])
      guard
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let runs = object["check_runs"] as? [[String: Any]]
      else {
        return "Error: unexpected GitHub response."
      }
      if runs.isEmpty { return "No check runs for \(ref) in \(repo)." }
      let lines = runs.map { run -> String in
        let id = intValue(run["id"]).map(String.init) ?? "?"
        let name = stringValue(run["name"]) ?? "?"
        let status = stringValue(run["status"]) ?? "?"
        let conclusion = stringValue(run["conclusion"]) ?? "pending"
        var line = "- \(name): \(status)/\(conclusion) (job_id: \(id))"
        if let output = run["output"] as? [String: Any],
          let summary = stringValue(output["summary"]), !summary.isEmpty
        {
          line += "\n  \(truncated(summary, limit: 300))"
        }
        return line
      }
      return "Check runs for \(ref) in \(repo):\n" + lines.joined(separator: "\n")
        + "\n\nUse github_ci_log with a job_id to read a GitHub Actions job log."
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func ciLog(repo: String, jobID: Int) async -> String {
    do {
      let data = try await get("/repos/\(repo)/actions/jobs/\(jobID)/logs", accept: "*/*")
      guard let log = String(data: data, encoding: .utf8), !log.isEmpty else {
        return "Job \(jobID) has an empty log."
      }
      // Failures show up at the end, so keep the tail.
      let tail =
        log.count > maxLogChars
        ? "[... log truncated ...]\n" + log.suffix(maxLogChars)
        : log
      return "Log of job \(jobID) in \(repo):\n" + tail
    } catch {
      // Raw log download often requires authentication; the check run's
      // output and annotations are public and usually carry the failure.
      if let fallback = await checkRunDetails(repo: repo, checkRunID: jobID) {
        return fallback
      }
      return
        "Error: \(error.localizedDescription) (GitHub requires authentication to download raw logs of this job; github_ci_status still shows each check's conclusion and summary)."
    }
  }

  private static func checkRunDetails(repo: String, checkRunID: Int) async -> String? {
    guard
      let data = try? await get("/repos/\(repo)/check-runs/\(checkRunID)"),
      let run = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    var lines: [String] = []
    let name = stringValue(run["name"]) ?? "?"
    let status = stringValue(run["status"]) ?? "?"
    let conclusion = stringValue(run["conclusion"]) ?? "pending"
    lines.append(
      "Raw log of job \(checkRunID) requires authentication; check run details for '\(name)' (\(status)/\(conclusion)):"
    )
    if let output = run["output"] as? [String: Any] {
      if let title = stringValue(output["title"]) { lines.append(title) }
      if let summary = stringValue(output["summary"]) {
        lines.append(truncated(summary, limit: maxBodyChars))
      }
      if let text = stringValue(output["text"]) {
        lines.append(truncated(text, limit: maxBodyChars))
      }
    }
    if let data = try? await get(
      "/repos/\(repo)/check-runs/\(checkRunID)/annotations",
      query: [URLQueryItem(name: "per_page", value: "50")]),
      let annotations = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
      !annotations.isEmpty
    {
      lines.append("")
      lines.append("Annotations:")
      for annotation in annotations {
        let path = stringValue(annotation["path"]) ?? "?"
        let line = intValue(annotation["start_line"]) ?? 0
        let level = stringValue(annotation["annotation_level"]) ?? "note"
        let message = truncated(stringValue(annotation["message"]) ?? "", limit: 500)
        lines.append("- \(path):\(line) [\(level)] \(message)")
      }
    }
    return lines.count > 1 ? lines.joined(separator: "\n") : nil
  }

  // MARK: - HTTP

  private static func get(
    _ path: String,
    query: [URLQueryItem] = [],
    accept: String = "application/vnd.github+json"
  ) async throws -> Data {
    var components = URLComponents(string: "https://api.github.com")
    components?.path = path
    if !query.isEmpty {
      components?.queryItems = query
    }
    guard let url = components?.url else {
      throw RequestError(message: "invalid GitHub API URL.")
    }
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.timeoutInterval = requestTimeout
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw RequestError(message: "no HTTP response from GitHub.")
    }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 403 || http.statusCode == 429,
        (http.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "") == "0"
      {
        throw RequestError(
          message:
            "GitHub API rate limit exceeded (60 unauthenticated requests per hour). Try again later."
        )
      }
      if http.statusCode == 404 {
        throw RequestError(
          message: "not found on GitHub (private repositories are not accessible without login).")
      }
      let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
      throw RequestError(message: "GitHub HTTP \(http.statusCode): \(body)")
    }
    return data
  }

  private static func refQuery(_ ref: String) -> [URLQueryItem] {
    let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? [] : [URLQueryItem(name: "ref", value: trimmed)]
  }

  private static func normalizedPath(_ path: String) -> String {
    path.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private static func escapedPath(_ path: String) -> String {
    let allowed = CharacterSet.urlPathAllowed
    return path.split(separator: "/")
      .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
      .joined(separator: "/")
  }

  private static func prStateLabel(_ pr: [String: Any]) -> String {
    if stringValue(pr["merged_at"]) != nil { return "merged" }
    return stringValue(pr["state"]) ?? "?"
  }

  private static func truncated(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return text.prefix(limit) + "\n[... truncated, \(text.count - limit) characters omitted ...]"
  }

  private static func stringValue(_ raw: Any?) -> String? {
    guard let s = raw as? String, !s.isEmpty else { return nil }
    return s
  }

  private static func intValue(_ raw: Any?) -> Int? {
    if let int = raw as? Int { return int }
    if let double = raw as? Double { return Int(exactly: double) }
    if let number = raw as? NSNumber { return number.intValue }
    return nil
  }
}
