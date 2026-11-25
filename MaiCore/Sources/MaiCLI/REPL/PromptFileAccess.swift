import Foundation
import MaiCore
import MaiStandardTools

actor PromptFileAccess {
  private var approvedURLs: [URL]
  nonisolated let policy: MaiFileAccessPolicy
  nonisolated let home: AgentHome

  init(
    approvalHandler: TerminalApprovalHandler, settings: ConfiguredFileAccess,
    environment: [String: String], home: AgentHome, approvedURLs: [URL] = []
  ) {
    self.home = home
    self.approvedURLs = approvedURLs
    policy = MaiFileAccessPolicy(
      hidden: settings.hidden, sensitive: settings.sensitive, symlinks: settings.symlinks,
      defaultAllowedURLs: ConfiguredFileAccess.defaultAllowedPaths.map { URL(fileURLWithPath: $0) }
    ) { url, operation in
      try await approvalHandler.decidePromptPathAccess(
        url, operation: operation, preparingTurn: operation.hasPrefix("/vdb"), forceConfirmation: true)
    }
    if let outside = settings.outside { policy.setOutside(outside) }
    for rule in settings.rules {
      policy.set(.init(
        url: URL(fileURLWithPath: AgentHome.expandUserPath(rule.path, environment: environment)),
        access: rule.access, descendants: rule.descendants))
    }
  }

  func contains(_ url: URL) -> Bool { approvedURLs.contains { $0.path == url.path } }
  func add(_ url: URL) { if !contains(url) { approvedURLs.append(url) } }
  func all() -> [URL] { approvedURLs }
  func remove(_ url: URL) { approvedURLs.removeAll { $0.path == url.path } }
}
