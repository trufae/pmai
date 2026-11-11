import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MaiACP
@testable import MaiCLI
import MaiCore
import NIOPosix
import Testing

#if os(macOS) || os(Linux)
private func hostingPort() async throws -> Int {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  do {
    let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(channel.localAddress?.port)
    try await channel.close().get()
    try await group.shutdownGracefully()
    return port
  } catch {
    try? await group.shutdownGracefully()
    throw error
  }
}

private func hostingFixture() throws -> (URL, URL, RemoteHosting) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-hosting-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let config = root.appendingPathComponent("config.json")
  try Data(#"{"providers":[{"id":"hello","kind":"hello"}],"defaultAgent":"main","agents":[{"id":"main","provider":"hello","model":"hello","instructions":""}]}"#.utf8).write(to: config)
  let worker = root.appendingPathComponent("worker")
  try Data("""
    #!/usr/bin/env python3
    import json, sys
    for line in sys.stdin:
        message = json.loads(line)
        print(json.dumps({'jsonrpc': '2.0', 'id': message['id'], 'result': {'ready': True}}), flush=True)
    """.utf8).write(to: worker)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
  return (root, config, RemoteHosting(home: AgentHome(rootURL: root.appendingPathComponent("home")), executable: worker.path))
}

// Prevents the app reporting a healthy HTTP server whose providers were never
// loaded, and verifies that Stop releases the port for the next Start.
@Test("App hosting serves configured OpenAI models and can stop and restart", .timeLimit(.minutes(1)))
func remoteHostingOpenAI() async throws {
  let (root, config, host) = try hostingFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  do {
    let port = try await hostingPort()
    let arguments = ["--protocol", "openai", "--port", String(port)]
    try await host.start(arguments: arguments, workingDirectory: root, configurationURL: config)
    let state = try await host.snapshot()
    #expect(state.running)
    #expect(state.pairingURI == nil)
    let endpoint = try #require(state.endpoint)
    var request = URLRequest(url: try #require(URL(string: endpoint + "/chat/completions")))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token = state.bearerToken { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    request.httpBody = Data(#"{"model":"agent:main","messages":[{"role":"user","content":"from the Mac app"}]}"#.utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("Hello from MaiCore: from the Mac app"))
    await host.stop()
    #expect(try await !host.snapshot().running)
    try await host.start(arguments: arguments, workingDirectory: root, configurationURL: config)
    #expect(try await host.snapshot().running)
    await host.stop()
  } catch { await host.stop(); throw error }
}

private func waitForHosting(_ host: RemoteHosting,
  matching predicate: (RemoteHostingSnapshot) -> Bool) async throws -> RemoteHostingSnapshot {
  let deadline = ContinuousClock.now + .seconds(15)
  repeat {
    let state = try await host.snapshot()
    if predicate(state) { return state }
    try await Task.sleep(for: .milliseconds(20))
  } while ContinuousClock.now < deadline
  throw JSONRPCError.internalError("The expected hosting state did not arrive")
}

// Prevents approval buttons granting the wrong request and Active indicators
// showing saved credentials as live sessions. Revocation must close the socket.
@Test("App hosting rejects and accepts clients, tracks activity and revokes access", .timeLimit(.minutes(1)))
func remoteHostingClients() async throws {
  let (root, config, host) = try hostingFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  do {
    let port = try await hostingPort()
    try await host.start(arguments: ["--protocol", "local", "--loopback", "--port", String(port), "--name", "openai"],
      workingDirectory: root, configurationURL: config)
    let state = try await host.snapshot()
    let uri = try #require(state.pairingURI)
    let profile = try ACPRemoteConnection.parse(uri)
    let pairing = JSONRPCPeer(transport: try ForwirohWebSocketTransport(url: profile.url, bearerToken: profile.token))
    await pairing.start()
    let rejected = Task {
      try await pairing.request("_pmai/pair", params: .object([
        "clientID": .string("rejected"), "name": .string("Rejected Client")]), timeout: 15)
    }
    let pending = try await waitForHosting(host) { !$0.requests.isEmpty }
    #expect(pending.requests.first?.name == "Rejected Client")
    try await host.resolvePairing(try #require(pending.requests.first?.id), allow: false)
    do { _ = try await rejected.value; Issue.record("Rejected pairing unexpectedly succeeded") }
    catch { #expect(error.localizedDescription.contains("rejected")) }
    await pairing.close()
    #expect(try await host.snapshot().clients.isEmpty)

    let acceptedPeer = JSONRPCPeer(transport: try ForwirohWebSocketTransport(url: profile.url, bearerToken: profile.token))
    await acceptedPeer.start()
    let accepted = Task {
      try await acceptedPeer.request("_pmai/pair", params: .object([
        "clientID": .string("accepted"), "name": .string("Accepted Client")]), timeout: 15)
    }
    let waiting = try await waitForHosting(host) { !$0.requests.isEmpty }
    try await host.resolvePairing(try #require(waiting.requests.first?.id), allow: true)
    let token = try #require(try await accepted.value.objectValue?["token"]?.stringValue)
    await acceptedPeer.close()
    #expect(try await host.snapshot().clients.first?.connections == 0)

    let transport = try ForwirohWebSocketTransport(url: profile.url, bearerToken: token)
    let client = JSONRPCPeer(transport: transport)
    await client.start()
    #expect(try await client.request("inspect", timeout: 15).objectValue?["ready"]?.boolValue == true)
    #expect(try await host.snapshot().clients.first?.connections == 1)
    try await host.revokeClient("accepted")
    let deadline = ContinuousClock.now + .seconds(15)
    while transport.isRunning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!transport.isRunning)
    #expect(try await host.snapshot().clients.isEmpty)
    await client.close()
    let cancelledPeer = JSONRPCPeer(transport: try ForwirohWebSocketTransport(url: profile.url, bearerToken: profile.token))
    await cancelledPeer.start()
    let cancelled = Task {
      try await cancelledPeer.request("_pmai/pair", params: .object([
        "clientID": .string("cancelled"), "name": .string("Cancelled Client")]), timeout: 15)
    }
    _ = try await waitForHosting(host) { !$0.requests.isEmpty }
    await host.stop()
    do { _ = try await cancelled.value; Issue.record("Stopping the host should cancel pending pairing") }
    catch { /* A rejected reply or a closed socket both end the pending request. */ }
    await cancelledPeer.close()
    let stopped = try await host.snapshot()
    #expect(!stopped.running && stopped.pairingURI == nil && stopped.requests.isEmpty)
  } catch { await host.stop(); throw error }
}
#endif
