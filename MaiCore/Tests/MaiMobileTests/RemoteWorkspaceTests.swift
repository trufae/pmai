import Foundation
import MaiACP
import MaiCore
import MaiStandardTools
import Testing
@testable import MaiMobile

@Test("Old ACP bookmarks retain their transport and credentials")
func legacyRemoteHostConnection() throws {
  var original = try ACPRemoteConnection(name: "Worker",
    url: #require(URL(string: "wss://worker.test/acp")), token: "secret", cwd: "/work")
  original.requiresApproval = true
  let host = try JSONDecoder().decode(RemoteHostConnection.self, from: JSONEncoder().encode(original))
  #expect(host.backend == nil)
  #expect(host.url == original.url)
  #expect(host.token == original.token)
  #expect(throws: JSONRPCError.self) { try host.workspace() }
}

@Test("Workspace transfers preserve binary data and reject oversized reads and unintended overwrites")
func sharedWorkspaceTransfers() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let workspace = WorkspaceConnection.local(MaiWorkspaceFiles(configuration: .init(rootURL: root)))
  let data = Data([0, 255, 1, 128])
  try await workspace.write("sample.bin", data: data, overwrite: false)
  #expect(try await workspace.read("sample.bin", maximumSize: 4) == data)
  await #expect(throws: WorkspaceFileError.self) { try await workspace.read("sample.bin", maximumSize: 3) }
  await #expect(throws: WorkspaceFileError.self) {
    try await workspace.write("sample.bin", data: Data([99]), overwrite: false)
  }
  #expect(try await workspace.read("sample.bin", maximumSize: 4) == data)
  try await workspace.write("sample.bin", data: Data())
  #expect(try await workspace.read("sample.bin", maximumSize: 0).isEmpty)
  await workspace.close()
}

@Test("Switching remote workspaces restores only that host and folder's terminal history")
@MainActor func remoteWorkspaceHistoryIsolation() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let id = UUID()
  let endpoint = try #require(URL(string: "https://worker.test"))
  let profile = RemoteHostConnection(try OpenCodeConnection(url: endpoint, token: "secret", cwd: "/work"))
  let file = RemoteTerminalBuffer.fileURL(hostID: id, endpoint: endpoint, cwd: "/work",
    directory: root.appendingPathComponent("terminals"))
  var buffer = RemoteTerminalBuffer()
  let command = buffer.append("pwd")
  buffer.update(command, output: "/work", isError: false)
  try buffer.save(to: file)
  let workspace = RemoteWorkspaceState(directory: root)
  workspace.configure(hostID: id.uuidString, profile: profile, cwd: "/work")
  workspace.show(console: true)
  #expect(workspace.snapshot["terminalHistory"] as? [String] == ["pwd"])
  workspace.configure(hostID: id.uuidString, profile: profile, cwd: "/other")
  #expect(workspace.snapshot["terminalHistory"] as? [String] == [])
  workspace.configure(hostID: id.uuidString, profile: profile, cwd: "/work")
  workspace.show(console: true)
  #expect(workspace.snapshot["terminalHistory"] as? [String] == ["pwd"])
  workspace.hide()
  #expect(workspace.snapshot["terminalHistory"] as? [String] == [])
  workspace.show(console: true)
  #expect(workspace.snapshot["terminalHistory"] as? [String] == ["pwd"])
  workspace.close()
}
