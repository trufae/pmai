import Foundation
import MaiCore
import MaiStandardTools

actor PromptFileAccess {
  private var approvedURLs: [URL] = []
  nonisolated let policy: MaiFileAccessPolicy

  init(
    approvalHandler: TerminalApprovalHandler, settings: ConfiguredFileAccess,
    environment: [String: String]
  ) {
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

  func contains(_ url: URL) -> Bool { approvedURLs.contains(url) }
  func add(_ url: URL) { if !approvedURLs.contains(url) { approvedURLs.append(url) } }
  func all() -> [URL] { approvedURLs }
  func remove(_ url: URL) { approvedURLs.removeAll { $0 == url } }
}
