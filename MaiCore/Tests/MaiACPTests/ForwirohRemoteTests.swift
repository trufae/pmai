import Foundation
import MaiACP
import MaiCore
import Testing

#if os(macOS) || os(iOS) || os(Linux) || os(Android)
  private let peerID = String(repeating: "a", count: 64)

  @Test func forwirohConnectionProfileRoundTripsAndPersistsStableAddress() throws {
    let url = try #require(URL(string: "forwiroh://\(peerID)/acp"))
    var profile = try ACPRemoteConnection(
      name: "Workstation", url: url, token: "invitation-token", cwd: "/work",
      connectionProtocol: .forwiroh)
    profile.forwirohInvitation = "forwiroh:single-use-invitation"
    profile.requiresApproval = true
    #expect(try ACPRemoteConnection.parse(profile.uri()) == profile)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ACPRemoteHostStore(directory: directory)
    profile.token = "approved-token"
    profile.requiresApproval = false
    let host = try store.pair(profile)
    #expect(host.url == url)
    #expect(store.provider(for: host).options["url"] == .string(url.absoluteString))
    #expect(try store.hosts().first?.connectionProtocol == .forwiroh)
    let index = try String(
      contentsOf: directory.appendingPathComponent("hosts.json"), encoding: .utf8)
    #expect(!index.contains("single-use-invitation"))
    #expect(!index.contains("approved-token"))
  }

  @Test func forwirohRejectsMalformedOrConflictingProfiles() throws {
    for raw in [
      "forwiroh://short/acp", "forwiroh://\(peerID):80/acp",
      "forwiroh://user@\(peerID)/acp", "forwiroh://\(peerID)/other",
      "forwiroh://\(peerID)/acp?token=secret", "forwiroh://\(peerID)/acp#fragment",
    ] {
      #expect(throws: JSONRPCError.self) {
        try ACPRemoteConnection.validate(url: #require(URL(string: raw)))
      }
    }
    let url = try #require(URL(string: "forwiroh://\(peerID)/acp"))
    #expect(throws: JSONRPCError.self) {
      try ACPRemoteConnection(
        name: "bad", url: url, token: "t", cwd: "/", connectionProtocol: .local)
    }
    #expect(throws: JSONRPCError.self) {
      try ACPRemoteConnection(
        name: "bad", url: #require(URL(string: "ws://127.0.0.1/acp")), token: "t", cwd: "/",
        connectionProtocol: .forwiroh)
    }
    #expect(throws: JSONRPCError.self) { try WebSocketJSONRPCTransport(url: url) }
  }

#endif
