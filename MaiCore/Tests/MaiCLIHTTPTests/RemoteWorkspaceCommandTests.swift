import Foundation
import MaiACP
import MaiStandardTools
import Testing

@testable import MaiCLI

@Test("Remote REPL transfers preserve binary bytes and failed downloads keep the local file")
func remoteWorkspaceTransfers() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let remote = root.appendingPathComponent("remote", isDirectory: true)
  let local = root.appendingPathComponent("local", isDirectory: true)
  try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
  let bytes = Data([0, 255, 128, 10])
  try bytes.write(to: local.appendingPathComponent("input file.bin"))
  let connection = WorkspaceConnection.local(MaiWorkspaceFiles(configuration: .init(rootURL: remote)))
  let terminal = TerminalWriter(capturesOutput: true)
  try await RemoteWorkspaceCommand.run("put", arguments: ["input file.bin"],
    connection: connection, directory: local, terminal: terminal)
  #expect(try Data(contentsOf: remote.appendingPathComponent("input file.bin")) == bytes)
  try await RemoteWorkspaceCommand.run("get", arguments: ["input file.bin", "download.bin"],
    connection: connection, directory: local, terminal: terminal)
  #expect(try Data(contentsOf: local.appendingPathComponent("download.bin")) == bytes)
  await #expect(throws: (any Error).self) {
    try await RemoteWorkspaceCommand.run("get", arguments: ["missing", "download.bin"],
      connection: connection, directory: local, terminal: terminal)
  }
  #expect(try Data(contentsOf: local.appendingPathComponent("download.bin")) == bytes)
}

@Test("Remote run keeps shell pipes and redirects on the host")
func remoteWorkspaceRedirection() throws {
  #expect(try REPLRedirectSyntax.parse(#"/remote run "dev host" printf '%s\n' "$PWD" | cat > remote.txt"#) == nil)
  #expect(try REPLRedirectSyntax.parse("/remote ls dev > local.txt") != nil)
}
