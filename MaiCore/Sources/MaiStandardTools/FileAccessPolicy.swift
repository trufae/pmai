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
      self.url = url.standardizedFileURL.resolvingSymlinksInPath()
      self.access = access
      self.descendants = descendants
    }

    public func contains(_ url: URL) -> Bool {
      url.path == self.url.path || (descendants && MaiFileAccessPolicy.contains(url, in: self.url))
    }
  }

  public typealias Confirmation = @Sendable (URL, String) async throws -> Bool
  private let lock = NSLock()
  private var rules: [Rule] = []
  private var outside: Access
  private var hidden: Access
  private var outsideConfigured = false
  private var revision = 0
  private let confirmation: Confirmation

  public init(
    outside: Access = .deny, hidden: Access = .allow,
    confirmation: @escaping Confirmation
  ) {
    self.outside = outside
    self.hidden = hidden
    self.confirmation = confirmation
  }

  public static func == (lhs: MaiFileAccessPolicy, rhs: MaiFileAccessPolicy) -> Bool {
    lhs === rhs
  }

  public func snapshot() -> (
    rules: [Rule], outside: Access, outsideConfigured: Bool, hidden: Access, revision: Int
  ) {
    lock.withLock { (rules, outside, outsideConfigured, hidden, revision) }
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

  public func set(_ rule: Rule) {
    lock.withLock {
      rules.removeAll { $0.url == rule.url }
      rules.append(rule)
      revision += 1
    }
  }

  public func remove(_ url: URL) {
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    lock.withLock {
      rules.removeAll { $0.url == resolved }
      revision += 1
    }
  }

  public func access(to url: URL, insideWorkspace: Bool) -> Access {
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    let state = snapshot()
    let matches = state.rules.filter { $0.contains(resolved) }
    if matches.contains(where: { $0.access == .deny }) { return .deny }
    if matches.contains(where: { $0.access == .ask }) { return .ask }
    if matches.contains(where: { $0.access == .allow }) { return .allow }
    if state.hidden != .allow, Self.isHidden(url) || Self.isHidden(resolved) { return state.hidden }
    if insideWorkspace { return .allow }
    return state.outside
  }

  public static func isHidden(_ url: URL) -> Bool {
    url.standardizedFileURL.pathComponents.contains { $0.hasPrefix(".") }
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
}

extension MaiFileWorkspaceConfiguration {
  public var effectiveRootURL: URL {
    (followsProcessWorkingDirectory ? AgentExecutionScope.directory : rootURL)
      .standardizedFileURL.resolvingSymlinksInPath()
  }

  public func containsAllowedPath(_ url: URL) -> Bool {
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    if MaiFileAccessPolicy.contains(resolved, in: effectiveRootURL) { return true }
    return additionalAllowedURLs.contains { allowed in
      let allowed = allowed.standardizedFileURL.resolvingSymlinksInPath()
      var directory: ObjCBool = false
      _ = FileManager.default.fileExists(atPath: allowed.path, isDirectory: &directory)
      return directory.boolValue
        ? MaiFileAccessPolicy.contains(resolved, in: allowed) : resolved == allowed
    }
  }

  func permits(_ url: URL) -> Bool {
    guard let pathAccessPolicy else { return containsAllowedPath(url) }
    switch pathAccessPolicy.access(to: url, insideWorkspace: containsAllowedPath(url)) {
    case .allow: return true
    case .deny: return false
    case .ask:
      guard confirmedPolicyRevision == pathAccessPolicy.snapshot().revision else { return false }
      let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
      return confirmedPathURLs.contains { MaiFileAccessPolicy.contains(resolved, in: $0) }
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
      let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
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
        switch pathAccessPolicy.access(to: url, insideWorkspace: containsAllowedPath(url)) {
        case .deny: throw MaiFileAccessError.denied(url.path)
        case .allow: continue
        case .ask:
          let resolved = url.resolvingSymlinksInPath().standardizedFileURL
          if result.confirmedPathURLs.contains(resolved) { continue }
          guard try await pathAccessPolicy.confirm(resolved, operation: operation) else {
            throw MaiFileAccessError.notApproved(url.path)
          }
          result.confirmedPathURLs.append(resolved)
        }
      }
      // Searches omit hidden entries. Tree mutations still affect them, so
      // authorize protected hidden descendants before renaming or deleting.
      var directory: ObjCBool = false
      if mutatingTree, pathAccessPolicy.snapshot().hidden != .allow,
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
          guard MaiFileAccessPolicy.isHidden(url) else { continue }
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
              let resolved = affectedURL.resolvingSymlinksInPath().standardizedFileURL
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
