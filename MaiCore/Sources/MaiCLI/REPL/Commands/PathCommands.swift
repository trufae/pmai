import Foundation
import MaiCore
import MaiStandardTools

extension MaiCLI {
  /// Finds explicit filesystem paths only. Bare words are deliberately not
  /// treated as paths: an access grant must come from an unambiguous absolute,
  /// home-relative, or dot-relative reference in the person's prompt.
  private static func promptPaths(in text: String, relativeTo directory: URL) -> [URL] {
    #if os(Windows)
    let pattern = #"(?:^|(?<=[\s\"'`]))((?:[A-Za-z]:[\\/]|[\\/]|~[\\/]|\.\.?[\\/])[^\s\"'`<>|]+)"#
    #else
    let pattern = #"(?:^|(?<=[\s\"'`]))((?:/|~\/|\.\.?/)[^\s\"'`<>|]+)"#
    #endif
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    var seen = Set<URL>()
    return expression.matches(in: text, range: range).compactMap { match in
      guard let captured = Range(match.range(at: 1), in: text) else { return nil }
      let raw = text[captured].trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?)]}"))
      guard !raw.isEmpty else { return nil }
      let path = AgentHome.expandUserPath(String(raw))
      let url = (NSString(string: path).isAbsolutePath
        ? URL(fileURLWithPath: path)
        : directory.appendingPathComponent(path))
        .standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        FileManager.default.isReadableFile(atPath: url.path), !seen.contains(url)
      else { return nil }
      seen.insert(url)
      return url
    }
  }

  private static func refreshFileTools(
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    environment: [String: String],
    approvedURLs: [URL],
    policy: MaiFileAccessPolicy
  ) async throws {
    let source = configuration?.toolSources.first {
      $0.enabled && $0.kind == MaiStandardToolsPlugin.factoryKind
    }
    let context = source?.context(environment: environment)
      ?? PluginFactoryContext(id: "standard-tools", environment: environment)
    guard source != nil || configuration == nil else { return }
    var fileConfiguration = MaiStandardToolFactory.fileWorkspaceConfiguration(
      context: context, additionalAllowedURLs: approvedURLs)
    fileConfiguration.pathAccessPolicy = policy
    for tool in MaiFileWorkspaceTool.makeTools(configuration: fileConfiguration) {
      try await runtime.register(tool: tool, replacingExisting: true)
    }
    try await runtime.register(
      tool: MaiVectorDatabaseTool(configuration: fileConfiguration), replacingExisting: true)
  }

  static func handlePathCommand(
    _ argument: String,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    access: PromptFileAccess,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let command = parts.first?.lowercased() ?? "list"
    var value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if value.count >= 2, let first = value.first, let last = value.last,
      (first == "\"" && last == "\"") || (first == "'" && last == "'")
    {
      value = String(value.dropFirst().dropLast())
    }
    let environment = ProcessInfo.processInfo.environment
    let source = configuration?.toolSources.first {
      $0.enabled && $0.kind == MaiStandardToolsPlugin.factoryKind
    }
    let context =
      source?.context(environment: environment)
      ?? PluginFactoryContext(id: "standard-tools", environment: environment)
    var files = MaiStandardToolFactory.fileWorkspaceConfiguration(
      context: context, additionalAllowedURLs: await access.all())
    files.pathAccessPolicy = access.policy
    let state = access.policy.snapshot()
    switch command {
    case "list":
      let badges = [
        "allow": await terminal.paint("allow", role: .successForeground, bold: true),
        "ask": await terminal.paint("ask", role: .warningForeground, bold: true),
        "deny": await terminal.paint("deny", role: .errorForeground, bold: true),
      ]
      func badge(_ policy: MaiFileAccessPolicy.Access) -> String {
        badges[policy.rawValue] ?? policy.rawValue
      }
      func row(_ policy: MaiFileAccessPolicy.Access, _ path: String) -> String {
        "  " + String(repeating: " ", count: 5 - policy.rawValue.count) + badge(policy) + " " + path
      }
      let root = files.effectiveRootURL
      let rootPolicy = access.policy.access(to: root, insideWorkspace: true)
      let rootMode = await terminal.paint(
        files.followsProcessWorkingDirectory ? "[follows /cd]" : "[fixed root]",
        role: .thinkingForeground)
      var lines = [
        await terminal.paintHeading("Workspace"),
        "  Current directory: \(FileManager.default.currentDirectoryPath)",
        "  Files workspace:   \(root.path) \(rootMode)",
        "  Workspace access:  \(badge(rootPolicy))",
        "",
        await terminal.paintHeading("Defaults"),
        "  Outside allowed paths: \(badge(state.outside))",
        "  Hidden paths:          \(badge(state.hidden))",
        "  Sensitive paths:       \(badge(state.sensitive))",
        "  Workspace symlinks:    \(badge(state.symlinks))",
        "  Prompt path grants:    \(state.outsideConfigured ? badge(state.outside) : "tool approval")",
        "",
        await terminal.paintHeading("Additional paths"),
      ]
      for url in access.policy.defaultAllowedURLs {
        let policy = access.policy.access(to: url, insideWorkspace: false)
        let label = await terminal.paint("[temporary; default]", role: .thinkingForeground)
        lines.append(row(policy, url.path) + " " + label)
      }
      for url in files.additionalAllowedURLs {
        let policy = access.policy.access(to: url, insideWorkspace: true)
        let label = await terminal.paint("[session grant]", role: .thinkingForeground)
        lines.append(row(policy, url.path) + " " + label)
      }
      if access.policy.defaultAllowedURLs.isEmpty && files.additionalAllowedURLs.isEmpty {
        lines.append("  (none)")
      }
      lines += ["", await terminal.paintHeading("Saved rules")]
      for rule in state.rules.sorted(by: { $0.url.path < $1.url.path }) {
        let scope = await terminal.paint(rule.descendants ? "[subtree]" : "[file]", role: .thinkingForeground)
        lines.append(row(rule.access, rule.url.path) + " " + scope)
      }
      if state.rules.isEmpty { lines.append("  (none)") }
      lines += ["", await terminal.paint("/help path — commands and policy details", role: .thinkingForeground)]
      await terminal.line(lines.joined(separator: "\n"))
      return
    case "help":
      await terminal.line(pathHelp)
      return
    case "hidden", "sensitive", "symlinks":
      guard let policy = MaiFileAccessPolicy.Access(rawValue: value.lowercased()) else {
        await terminal.line("Usage: /path \(command) ask|deny|allow")
        return
      }
      if command == "hidden" { access.policy.setHidden(policy) }
      else if command == "symlinks" { access.policy.setSymlinks(policy) }
      else { access.policy.setSensitive(policy) }
      await terminal.note("Files \(command) path access: \(policy.rawValue)")
    case "outside":
      guard let policy = MaiFileAccessPolicy.Access(rawValue: value.lowercased()), policy != .allow
      else {
        await terminal.line("Usage: /path outside ask|deny")
        return
      }
      access.policy.setOutside(policy)
      await terminal.note("Files access outside allowed paths: \(policy.rawValue)")
    case "allow", "add", "deny", "reject", "ask", "prompt", "del":
      guard !value.isEmpty else {
        await terminal.line("Usage: /path \(command) PATH")
        return
      }
      let expanded = AgentHome.expandUserPath(value, environment: environment)
      let url =
        (NSString(string: expanded).isAbsolutePath
        ? URL(fileURLWithPath: expanded)
        : files.effectiveRootURL.appendingPathComponent(expanded))
        .standardizedFileURL.resolvingSymlinksInPath()
      if command == "del" {
        access.policy.remove(url)
        await access.remove(url)
        await terminal.note(
          "Removed explicit Files rule/grant for \(url.path). Parent grants and the workspace still apply; /path deny PATH blocks access."
        )
      } else {
        let policy: MaiFileAccessPolicy.Access =
          ["allow", "add"].contains(command)
          ? .allow
          : ["deny", "reject"].contains(command) ? .deny : .ask
        var directory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        #if os(Windows)
        let directorySuffix = value.hasSuffix("/") || value.hasSuffix("\\")
        #else
        let directorySuffix = value.hasSuffix("/")
        #endif
        access.policy.set(
          .init(
            url: url, access: policy,
            descendants: policy == .deny || directory.boolValue || directorySuffix))
        await terminal.note("Files policy: \(policy.rawValue) \(url.path)")
      }
      do {
        try await refreshFileTools(
          runtime: runtime, configuration: configuration, environment: environment,
          approvedURLs: await access.all(), policy: access.policy)
      } catch {
        await terminal.note(
          "Could not refresh Files tools: \(error.localizedDescription)", tone: .warning)
      }
    default:
      await terminal.line("Unknown /path subcommand '\(command)'.\n\(pathHelp)")
      return
    }
    if var draft = configuration, let configurationPath {
      let state = access.policy.snapshot()
      draft.fileAccess = .init(
        outside: state.outsideConfigured ? state.outside : nil, hidden: state.hidden, sensitive: state.sensitive,
        symlinks: state.symlinks,
        rules: state.rules.map {
          .init(path: $0.url.path, access: $0.access, descendants: $0.descendants)
        })
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
      } catch {
        await terminal.note(
          "Path changes apply to this session but could not be saved: \(error.localizedDescription)",
          tone: .warning)
      }
    }
  }

  /// Adds verified external prompt paths to the Files tool's allowlist before
  /// a turn begins. Path policy remains independent of general tool approval.
  static func preparePromptFileAccess(
    for text: String,
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    environment: [String: String],
    promptFileAccess: PromptFileAccess,
    approvalHandler: TerminalApprovalHandler,
    terminal: TerminalWriter
  ) async -> Bool {
    let source = configuration?.toolSources.first {
      $0.enabled && $0.kind == MaiStandardToolsPlugin.factoryKind
    }
    let context = source?.context(environment: environment)
      ?? PluginFactoryContext(id: "standard-tools", environment: environment)
    let fileConfiguration = MaiStandardToolFactory.fileWorkspaceConfiguration(context: context)
    let workspace = (fileConfiguration.followsProcessWorkingDirectory
      ? AgentExecutionScope.directory : fileConfiguration.rootURL)
      .standardizedFileURL.resolvingSymlinksInPath()
    var scopedConfiguration = fileConfiguration
    scopedConfiguration.additionalAllowedURLs = await promptFileAccess.all()
    scopedConfiguration.pathAccessPolicy = promptFileAccess.policy
    let paths = promptPaths(in: text, relativeTo: workspace)
    var changed = false
    for path in paths {
      // Naming a workspace link must not turn its per-operation approval into
      // a direct external session grant, even when ordinary tools use yolo.
      if scopedConfiguration.followsWorkspaceSymlink(path) { continue }
      let url = path.resolvingSymlinksInPath().standardizedFileURL
      if await promptFileAccess.contains(url) { continue }
      let access = promptFileAccess.policy.access(
        to: url, insideWorkspace: scopedConfiguration.containsAllowedPath(url))
      if access == .allow { continue }
      let state = promptFileAccess.policy.snapshot()
      if access == .deny && (state.outsideConfigured
        || state.hidden == .deny && MaiFileAccessPolicy.isHidden(url)
        || state.sensitive == .deny && MaiFileAccessPolicy.isSensitive(url)
        || state.rules.contains(where: {
          $0.access == .deny && $0.contains(url)
        })) {
        await terminal.note("Files access denied by /path policy: \(url.path)", tone: .warning)
        continue
      }
      // An ask rule is per access. Naming it in a prompt never turns it into
      // an ongoing grant; the actual Files call will request confirmation.
      if access == .ask && (state.hidden == .ask && MaiFileAccessPolicy.isHidden(url)
        || state.sensitive == .ask && MaiFileAccessPolicy.isSensitive(url)
        || state.rules.contains(where: {
          $0.access == .ask && $0.contains(url)
        })) {
        continue
      }
      do {
        guard try await approvalHandler.decidePromptPathAccess(
          url, forceConfirmation: state.outsideConfigured && state.outside == .ask) else {
          await terminal.note("External path access was not granted: \(url.path)", tone: .warning)
          return false
        }
      } catch is CancellationError {
        return false
      } catch {
        await terminal.note("Could not approve external path access: \(error.localizedDescription)", tone: .warning)
        return false
      }
      await promptFileAccess.add(url)
      changed = true
    }
    guard changed else { return true }
    do {
      let approved = await promptFileAccess.all()
      try await refreshFileTools(
        runtime: runtime, configuration: configuration, environment: environment,
        approvedURLs: approved, policy: promptFileAccess.policy)
      await terminal.note(
        "Files may access: \(approved.map(\.path).joined(separator: ", ")). Use /path to review, deny, or require prompts for these paths."
      )
      return true
    } catch {
      await terminal.note("Could not update file access: \(error.localizedDescription)", tone: .warning)
      return false
    }
  }
}
