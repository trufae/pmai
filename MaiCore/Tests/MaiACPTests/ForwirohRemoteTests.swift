import Foundation
@testable import MaiACP
import MaiCore
import Testing

@Test func forwirohReconnectUsesTypedFailures() {
  #expect(RemoteConnectionRecovery.shouldRetry(JSONRPCTransportError.closed))
  #expect(RemoteConnectionRecovery.shouldRetry(JSONRPCTransportError.timedOut("initialize")))
  #expect(RemoteConnectionRecovery.shouldRetry(ForwirohConnectionError(
    stage: .peerDial, retryable: true, detail: "Dial timed out")))
  #expect(!RemoteConnectionRecovery.shouldRetry(ForwirohConnectionError(
    stage: .peerNotPaired, retryable: false, detail: "Peer not paired")))
  #expect(!RemoteConnectionRecovery.shouldRetry(ACPClientError.gatewayUnauthorized))
  #expect(!RemoteConnectionRecovery.shouldRetry(ACPClientError.sessionRestoreFailed("Chat missing")))
}

#if os(macOS) || os(Linux)
  @Test func forwirohWebSocketKeepsHTTP401DistinctFromTransportFailure() async throws {
    let server = Process()
    let ready = Pipe()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.standardOutput = ready
    server.arguments = ["-u", "-c", #"""
      import socket
      with socket.socket() as server:
          server.bind(('127.0.0.1', 0))
          server.listen()
          server.settimeout(10)
          print(server.getsockname()[1], flush=True)
          connection, _ = server.accept()
          with connection:
              connection.settimeout(10)
              request = b''
              while not request.endswith(b'\r\n\r\n'):
                  data = connection.recv(8192)
                  if not data:
                      raise RuntimeError('WebSocket request closed prematurely')
                  request += data
              connection.sendall(b'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n')
      """#]
    try server.run()
    defer {
      if server.isRunning { server.terminate() }
      server.waitUntilExit()
    }
    let port = try #require(Int(String(decoding: ready.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)))
    let transport = try ForwirohWebSocketTransport(
      url: #require(URL(string: "ws://127.0.0.1:\(port)/acp")), bearerToken: "fixture")
    defer { transport.close() }
    await #expect(throws: ACPClientError.gatewayUnauthorized) {
      try await transport.waitForUpgrade()
    }
  }
#endif

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
