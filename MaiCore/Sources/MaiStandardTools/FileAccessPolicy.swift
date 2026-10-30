import Foundation
import MaiCore

/// Host-owned Files permissions. Models cannot change these through tool arguments.
/// Denials take precedence over prompts, and prompts over allowed roots.
public final class MaiFileAccessPolicy: @unchecked Sendable, Equatable {
  public typealias Access = ConfiguredFileAccess.Access

  public struct Rule: Equatable, Sendable {
    public var url: URL
    public var access: Access
    public var descendants: Bool

    public init(url: URL, access: Access, descendants: Bool = true) {
      self.url = MaiFileAccessPolicy.resolvedURL(url)
      self.access = access
      self.descendants = descendants
    }

    public func contains(_ url: URL) -> Bool {
      url.path == self.url.path || (descendants && MaiFileAccessPolicy.contains(url, in: self.url))
    }
  }

  public typealias Confirmation = @Sendable (URL, String) async throws -> Bool
  public let defaultAllowedURLs: [URL]
  private let lock = NSLock()
  private var rules: [Rule] = []
  private var outside: Access
  private var hidden: Access
  private var sensitive: Access
  private var symlinks: Access
  private var outsideConfigured = false
  private var revision = 0
  private let confirmation: Confirmation

  public init(
    outside: Access = .deny, hidden: Access = .allow, sensitive: Access = .ask,
    symlinks: Access = .ask,
    defaultAllowedURLs: [URL] = [],
    confirmation: @escaping Confirmation
  ) {
    self.outside = outside
    self.hidden = hidden
    self.sensitive = sensitive
    self.symlinks = symlinks
    self.defaultAllowedURLs = defaultAllowedURLs.map {
      $0.standardizedFileURL.resolvingSymlinksInPath()
    }
    self.confirmation = confirmation
  }

  public static func == (lhs: MaiFileAccessPolicy, rhs: MaiFileAccessPolicy) -> Bool {
    lhs === rhs
  }

  public func snapshot() -> (
    rules: [Rule], outside: Access, outsideConfigured: Bool, hidden: Access, sensitive: Access,
    symlinks: Access, revision: Int
  ) {
    lock.withLock { (rules, outside, outsideConfigured, hidden, sensitive, symlinks, revision) }
  }

  public func setOutside(_ access: Access) {
    lock.withLock {
      outside = access
      outsideConfigured = true
      revision += 1
    }
  }

  public func setHidden(_ access: Access) {
    lock.withLock {
      hidden = access
      revision += 1
    }
  }

  public func setSensitive(_ access: Access) {
    lock.withLock {
      sensitive = access
      revision += 1
    }
  }

  public func setSymlinks(_ access: Access) {
    lock.withLock {
      symlinks = access
      revision += 1
    }
  }

  public func set(_ rule: Rule) {
    lock.withLock {
      rules.removeAll { $0.url == rule.url }
      rules.append(rule)
      revision += 1
    }
  }

  public func remove(_ url: URL) {
    let resolved = Self.resolvedURL(url)
    lock.withLock {
      rules.removeAll { $0.url == resolved }
      revision += 1
    }
  }

  public func access(
    to url: URL, insideWorkspace: Bool, throughWorkspaceSymlink: Bool = false
  ) -> Access {
    let resolved = Self.resolvedURL(url)
    let state = snapshot()
    let matches = state.rules.filter {
      $0.contains(resolved) || ($0.access != .allow && $0.contains(url.standardizedFileURL))
    }
    if matches.contains(where: { $0.access == .deny }) { return .deny }
    if matches.contains(where: { $0.access == .ask }) { return .ask }
    if matches.contains(where: { $0.access == .allow }) { return .allow }
    if defaultAllowedURLs.contains(where: { Self.contains(resolved, in: $0) }) { return .allow }
    if throughWorkspaceSymlink, state.symlinks == .deny { return .deny }
    if state.hidden != .allow, Self.isHidden(url) || Self.isHidden(resolved) { return state.hidden }
    if state.sensitive != .allow, Self.isSensitive(url) || Self.isSensitive(resolved) { return state.sensitive }
    if insideWorkspace { return .allow }
    if throughWorkspaceSymlink { return state.symlinks }
    return state.outside
  }

  /// Names only: never read a secret to decide whether reading it is allowed.
  public static func isSensitive(_ url: URL) -> Bool {
    let names = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
    if names.contains(where: { [".ssh", ".gnupg", ".aws", ".kube", ".azure"].contains($0) }) { return true }
    let name = url.lastPathComponent.lowercased()
    return ["pem", "key", "p12", "pfx", "jks", "keystore", "gpg", "pgp", "kdbx", "age", "enc"]
      .contains(url.pathExtension.lowercased())
      || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials", ".netrc", ".npmrc", ".pypirc", ".env"].contains(name)
      || name.hasPrefix(".env.")
  }

  public static func isHidden(_ url: URL) -> Bool {
    // Workspace scratch directories are ordinary working files. Other hidden
    // ancestors and sensitive filenames still get their usual checks.
    url.standardizedFileURL.pathComponents.contains { $0.hasPrefix(".") && $0 != ".tmp" }
  }

  public func confirm(_ url: URL, operation: String) async throws -> Bool {
    try Task.checkCancellation()
    let approved = try await confirmation(url, operation)
    try Task.checkCancellation()
    return approved
  }

  static func contains(_ url: URL, in directory: URL) -> Bool {
    let parent = directory.path == "/" ? "/" : directory.path + "/"
    return url.path == directory.path || url.path.hasPrefix(parent)
  }

  /// Foundation may leave a nonexistent destination unresolved. Resolve its
  /// existing ancestor so creating a file through a link uses the same policy
  /// as reading it. Preserve dangling symlink entries for rename/delete checks.
  static func resolvedURL(_ url: URL) -> URL {
    var ancestor = url.standardizedFileURL
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: ancestor.path),
      (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil
    {
      let parent = ancestor.deletingLastPathComponent()
      if parent == ancestor { break }
      suffix.append(ancestor.lastPathComponent)
      ancestor = parent
    }
    return suffix.reversed().reduce(ancestor.resolvingSymlinksInPath().standardizedFileURL) {
      $0.appendingPathComponent($1)
    }.standardizedFileURL
  }
}

extension MaiFileWorkspaceConfiguration {
  public var effectiveRootURL: URL {
    (followsProcessWorkingDirectory ? AgentExecutionScope.directory : rootURL)
      .standardizedFileURL.resolvingSymlinksInPath()
  }

  public func containsAllowedPath(_ url: URL) -> Bool {
    let resolved = MaiFileAccessPolicy.resolvedURL(url)
    if MaiFileAccessPolicy.contains(resolved, in: effectiveRootURL) { return true }
    return additionalAllowedURLs.contains { allowed in
      let allowed = allowed.standardizedFileURL.resolvingSymlinksInPath()
      var directory: ObjCBool = false
      _ = FileManager.default.fileExists(atPath: allowed.path, isDirectory: &directory)
      return directory.boolValue
        ? MaiFileAccessPolicy.contains(resolved, in: allowed) : resolved == allowed
    }
  }

  /// Check the spelling under an allowed directory before resolving its links.
  /// Default scratch paths are not workspace roots and cannot grant link escapes.
  public func followsWorkspaceSymlink(_ url: URL) -> Bool {
    let lexical = url.standardizedFileURL
    guard !containsAllowedPath(lexical) else { return false }
    let grantedDirectories = pathAccessPolicy?.snapshot().rules
      .filter { $0.access == .allow && $0.descendants }.map(\.url) ?? []
    return ([effectiveRootURL] + additionalAllowedURLs + grantedDirectories).contains { root in
      let root = root.standardizedFileURL.resolvingSymlinksInPath()
      var directory: ObjCBool = false
      return FileManager.default.fileExists(atPath: root.path, isDirectory: &directory)
        && directory.boolValue && MaiFileAccessPolicy.contains(lexical, in: root)
    }
  }

  func permits(_ url: URL) -> Bool {
    guard let pathAccessPolicy else { return containsAllowedPath(url) }
    let resolved = MaiFileAccessPolicy.resolvedURL(url)
    let throughSymlink = followsWorkspaceSymlink(url)
      || (confirmedPolicyRevision == pathAccessPolicy.snapshot().revision
        && followedSymlinks.contains { MaiFileAccessPolicy.contains(resolved, in: $0.target) })
    switch pathAccessPolicy.access(
      to: url, insideWorkspace: containsAllowedPath(url), throughWorkspaceSymlink: throughSymlink)
    {
    case .allow: return true
    case .deny: return false
    case .ask:
      guard confirmedPolicyRevision == pathAccessPolicy.snapshot().revision else { return false }
      return confirmedPathURLs.contains {
        if pathAccessPolicy.snapshot().sensitive != .allow, MaiFileAccessPolicy.isSensitive(resolved) {
          return resolved == $0
        }
        return MaiFileAccessPolicy.contains(resolved, in: $0)
      }
    }
  }

  /// Prompts apply to this operation only. A directory mutation must also cover
  /// protected descendants, since move/remove would otherwise bypass their rules.
  func authorizing(
    paths: [String], operation: String, recursive: Bool = false, mutatingTree: Bool = false,
    movingTo: String? = nil
  ) async throws -> Self {
    guard let pathAccessPolicy else { return self }
    var result = self
    result.confirmedPolicyRevision = pathAccessPolicy.snapshot().revision
    for path in paths {
      let expanded = AgentHome.expandUserPath(path)
      let target =
        (expanded.hasPrefix("/")
        ? URL(fileURLWithPath: expanded) : effectiveRootURL.appendingPathComponent(expanded))
        .standardizedFileURL
      let resolvedTarget = MaiFileAccessPolicy.resolvedURL(target)
      var targets = [target]
      if recursive || mutatingTree {
        for rule in pathAccessPolicy.snapshot().rules
        where MaiFileAccessPolicy.contains(rule.url, in: resolvedTarget) {
          if !mutatingTree, MaiFileAccessPolicy.isHidden(rule.url), rule.url != resolvedTarget {
            continue
          }
          if mutatingTree && rule.access == .deny {
            throw MaiFileAccessError.denied(rule.url.path)
          }
          if rule.access == .ask,
            pathAccessPolicy.access(to: rule.url, insideWorkspace: containsAllowedPath(rule.url))
              != .deny
          {
            targets.append(rule.url)
          }
        }
      }
      for url in targets {
        let throughSymlink = followsWorkspaceSymlink(url)
        let resolved = MaiFileAccessPolicy.resolvedURL(url)
        switch pathAccessPolicy.access(
          to: url, insideWorkspace: containsAllowedPath(url), throughWorkspaceSymlink: throughSymlink)
        {
        case .deny: throw MaiFileAccessError.denied(url.path)
        case .allow: break
        case .ask:
          if !result.confirmedPathURLs.contains(resolved) {
            let description = throughSymlink ? "\(operation) (follow symlink from \(url.path))" : operation
            guard try await pathAccessPolicy.confirm(resolved, operation: description) else {
              throw MaiFileAccessError.notApproved(url.path)
            }
            result.confirmedPathURLs.append(resolved)
          }
        }
        // Tool implementations use canonical URLs after resolving the request.
        // Keep this provenance only for this operation, never as a session grant.
        if throughSymlink {
          var source = url
          while followsWorkspaceSymlink(source.deletingLastPathComponent()) {
            source.deleteLastPathComponent()
          }
          result.followedSymlinks.append(.init(
            source: source, target: MaiFileAccessPolicy.resolvedURL(source)))
        }
      }
      // Searches omit hidden entries. Tree mutations still affect them, so
      // authorize protected hidden descendants before renaming or deleting.
      var directory: ObjCBool = false
      if mutatingTree, (pathAccessPolicy.snapshot().hidden != .allow || pathAccessPolicy.snapshot().sensitive != .allow),
        FileManager.default.fileExists(atPath: target.path, isDirectory: &directory),
        directory.boolValue
      {
        var enumerationError: Error?
        guard
          let entries = FileManager.default.enumerator(
            at: resolvedTarget, includingPropertiesForKeys: [],
            errorHandler: { _, error in
              enumerationError = error
              return false
            })
        else {
          throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        while let url = entries.nextObject() as? URL {
          try Task.checkCancellation()
          guard MaiFileAccessPolicy.isHidden(url) || MaiFileAccessPolicy.isSensitive(url) else { continue }
          var affected = [url]
          if let movingTo, path == paths.first {
            let expanded = AgentHome.expandUserPath(movingTo)
            let destination =
              expanded.hasPrefix("/")
              ? URL(fileURLWithPath: expanded) : effectiveRootURL.appendingPathComponent(expanded)
            let suffix = url.path.dropFirst(
              resolvedTarget.path.count + (resolvedTarget.path == "/" ? 0 : 1))
            affected.append(destination.appendingPathComponent(String(suffix)).standardizedFileURL)
          }
          for affectedURL in affected {
            switch pathAccessPolicy.access(
              to: affectedURL, insideWorkspace: containsAllowedPath(affectedURL))
            {
            case .allow: continue
            case .deny: throw MaiFileAccessError.denied(affectedURL.path)
            case .ask:
              let resolved = MaiFileAccessPolicy.resolvedURL(affectedURL)
              if !result.confirmedPathURLs.contains(where: {
                MaiFileAccessPolicy.contains(resolved, in: $0)
              }) {
                guard try await pathAccessPolicy.confirm(resolved, operation: operation) else {
                  throw MaiFileAccessError.notApproved(affectedURL.path)
                }
                result.confirmedPathURLs.append(resolved)
              }
              entries.skipDescendants()
            }
          }
        }
        if let enumerationError { throw enumerationError }
      }
    }
    return result
  }
}

private enum MaiFileAccessError: LocalizedError {
  case denied(String)
  case notApproved(String)

  var errorDescription: String? {
    switch self {
    case .denied(let path): "Files access denied for '\(path)' by /path policy."
    case .notApproved(let path):
      "Files access was not approved for '\(path)'. Use /path to review permissions."
    }
  }
}
