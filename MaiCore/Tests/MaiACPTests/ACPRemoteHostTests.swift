import Foundation
import MaiACP
import MaiCore
import Testing

@Test("Only approved client credentials authorize access, and rotation/revocation remove it")
func acpServerPairingCredentials() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "acp-pairing-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ACPPairingStore(directory: directory)
  #expect(!store.authorizes("qr-invitation"))
  let token = try store.approve(id: "device", name: "PocketMai")
  #expect(store.authorizes(token))
  #expect(!store.authorizes("qr-invitation"))
  let replacement = try store.approve(id: "device", name: "PocketMai")
  #expect(replacement != token)
  #expect(!store.authorizes(token))
  #expect(store.authorizes(replacement))
  #expect(try store.clients().count == 1)
  try store.revoke(id: "device")
  #expect(!store.authorizes(replacement))
}

@Test("Pairing stores credentials privately and preserves a host's identity on reimport")
func acpRemoteHostPairing() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "acp-hosts-\(UUID())")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ACPRemoteHostStore(directory: directory)
  let url = try #require(URL(string: "wss://pmai.tunnel.example/acp"))
  let first = try store.pair(
    ACPRemoteConnection(name: "Workstation", url: url, token: "first-token", cwd: "/work",
      connectionProtocol: .opentunnel))
  let second = try store.pair(
    ACPRemoteConnection(name: "Renamed", url: url, token: "new-token", cwd: "/work/other",
      connectionProtocol: .opentunnel))
  #expect(first.id == second.id)
  #expect(second.agentAccess != true)
  try store.setAgentAccess(true, for: second)
  #expect(try store.host("renamed").agentAccess == true)
  try store.setAgentAccess(false, for: second)
  #expect(try store.host("renamed").agentAccess == false)
  #expect(try store.hosts().count == 1)
  var disabled = second
  disabled.agentAccess = false
  #expect(try store.host("renamed") == disabled)
  #expect(try store.host("renamed").connectionProtocol == .opentunnel)
  let provider = store.provider(for: second)
  #expect(provider.options["token"] == nil)
  #expect(provider.options["tokenFile"]?.stringValue == store.tokenFile(for: second).path)
  #expect(try String(contentsOf: store.tokenFile(for: second), encoding: .utf8) == "new-token")
  let index = try String(
    contentsOf: directory.appendingPathComponent("hosts.json"), encoding: .utf8)
  #expect(!index.contains("new-token"))
  #expect(
    (try FileManager.default.attributesOfItem(atPath: store.tokenFile(for: second).path)[
      .posixPermissions] as? NSNumber)?.intValue == 0o600)
  #expect(throws: JSONRPCError.self) {
    try store.pair(
      ACPRemoteConnection(
        name: "Renamed", url: #require(URL(string: "ws://127.0.0.1:19284/acp")), token: "token",
        cwd: "/work"))
  }
  try store.rename(second, to: "Desktop")
  let renamed = try store.host("desktop")
  #expect(renamed.id == first.id && renamed.cwd == second.cwd)
  #expect(try store.connection(for: renamed).token == "new-token")
  let movedURL = try #require(URL(string: "wss://new-host.example/acp"))
  try store.update(renamed, name: "Desktop", url: movedURL, cwd: "/new/work", agentAccess: true)
  let moved = try store.host("desktop")
  #expect(moved.id == renamed.id && moved.url == movedURL && moved.cwd == "/new/work" && moved.agentAccess == true)
  #expect(try store.connection(for: moved).token == "new-token")
  #expect(throws: JSONRPCError.self) {
    try store.update(moved, name: "Desktop", url: URL(string: "file:///tmp/no")!, cwd: "/work", agentAccess: false)
  }
  #expect(try store.host("desktop") == moved)
  #expect(throws: JSONRPCError.self) { try store.rename(renamed, to: " ") }
  let other = try store.pair(ACPRemoteConnection(name: "Other",
    url: #require(URL(string: "ws://127.0.0.1:19284/acp")), token: "other-token", cwd: "/work"))
  #expect(throws: JSONRPCError.self) { try store.rename(renamed, to: "OTHER") }
  try Data("{}".utf8).write(to: store.sessionFile(for: renamed))
  try store.remove(renamed)
  #expect(try store.hosts() == [other])
  #expect(!FileManager.default.fileExists(atPath: store.tokenFile(for: renamed).path))
  #expect(!FileManager.default.fileExists(atPath: store.sessionFile(for: renamed).path))
  #expect(try store.connection(for: other).token == "other-token")
}
