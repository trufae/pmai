import Foundation
import MaiCore

enum MacCLI {
  static let installCommand =
    "curl -fsSL https://raw.githubusercontent.com/trufae/pmai/main/www/install.sh | PMAI_INSTALL_DIR=\"$HOME/.local/bin\" sh"
  static let installationInstructions = """
    pmai was not found in PATH. Run this command in Terminal to install it in ~/.local/bin, then try again:

    \(installCommand)
    """

  struct NotInstalled: LocalizedError {
    var errorDescription: String? { MacCLI.installationInstructions }
  }

  static var environment: [String: String] {
    var environment = ProcessInfo.processInfo.environment
    // Finder does not inherit shell startup files. Preserve PATH precedence
    // and include the installer destination and conventional package managers.
    environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
      + ":" + AgentHome.userHomeDirectory().appendingPathComponent(".local/bin").path
      + ":/opt/homebrew/bin:/usr/local/bin"
    return environment
  }

  static func executable(environment: [String: String], workingDirectory: URL) throws -> String {
    do {
      return try LocalExecutable.resolve("pmai", environment: environment, workingDirectory: workingDirectory)
    } catch LocalExecutable.ResolutionError.notFound {
      throw NotInstalled()
    }
  }
}
