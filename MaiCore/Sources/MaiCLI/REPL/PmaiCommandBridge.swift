import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension MaiCLI {
  /// What a command may change under a running turn, taken before it runs
  /// so the person can be told how the change and the run meet.
  /// What a pmai command run from a tool changed, waiting for the REPL loop to
  /// adopt it.
  struct PmaiToolChanges {
    var profile: SessionProfile
    var configuration: MaiConfiguration?
    var catalogs: [MCPServerCatalog]
  }

  /// The state one slash command may change, in the one place the REPL loop
  /// and the `pmai_run` tool both go through.
  ///
  /// The loop keeps its own copies for the length of a turn and hands them here
  /// before the turn starts; a command the model runs leaves what it changed
  /// behind and the loop adopts it when the turn ends. Without the hand-off a
  /// command run from a tool would save its change to the configuration file
  /// and the loop's next command would write its older copy straight back over
  /// it. Only the profile comes back with the change: the transcript and the
  /// queued attachments belong to the run in flight.
  final class PmaiCommandBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var session: REPLSession?
    private var configuration: MaiConfiguration?
    private var catalogs: [MCPServerCatalog] = []
    private var chatProcess: AgentPID?
    private var changes: PmaiToolChanges?

    /// The state a command starts from, or nil when no loop has handed any
    /// over yet.
    func begin() -> (
      session: REPLSession, configuration: MaiConfiguration?, catalogs: [MCPServerCatalog],
      chatProcess: AgentPID?
    )? {
      lock.withLock {
        guard let session else { return nil }
        return (session, configuration, catalogs, chatProcess)
      }
    }

    /// Keeps what the command changed for the loop's next `takeChanges`.
    func finish(
      session: REPLSession, configuration: MaiConfiguration?, catalogs: [MCPServerCatalog]
    ) {
      lock.withLock {
        changes = PmaiToolChanges(
          profile: session.profile, configuration: configuration, catalogs: catalogs)
      }
    }

    /// The loop hands over the state a command should start from.
    func sync(
      session: REPLSession,
      configuration: MaiConfiguration?,
      catalogs: [MCPServerCatalog],
      chatProcess: AgentPID?
    ) {
      lock.withLock {
        self.session = session
        self.configuration = configuration
        self.catalogs = catalogs
        self.chatProcess = chatProcess
      }
    }

    /// What the last command changed, handed over once.
    func takeChanges() -> PmaiToolChanges? {
      lock.withLock {
        defer { changes = nil }
        return changes
      }
    }
  }
}
