import Foundation
import MaiACP
import MaiCore
import Testing

@Test func acpRemoteConnectionProfile() throws {
  let profile = try ACPRemoteConnection(
    name: "Worker", url: #require(URL(string: "wss://gateway.example/acp")),
    token: String(repeating: "a", count: 64), cwd: "/work/project")
  #expect(try ACPRemoteConnection.parse(profile.uri()) == profile)
  for address in [
    "https://gateway.example/acp", "ws://user:secret@gateway/acp", "ws://gateway/acp?token=secret",
  ] {
    #expect(throws: (any Error).self) {
      try ACPRemoteConnection(
        name: "Worker", url: #require(URL(string: address)), token: "token", cwd: "/work")
    }
  }
  #expect(throws: (any Error).self) {
    try ACPRemoteConnection.parse("pmai-tailcat://pair/anything")
  }
}

private actor WebSocketEvents {
  var text = ""
  var permissions = 0
  var updates: [JSONValue] = []
  var disconnections = 0
  func disconnect() { disconnections += 1 }
  func event(_ event: ProviderEvent) {
    if case .textDelta(let delta) = event { text += delta }
  }
  func update(_ update: JSONValue) { updates.append(update) }
  func approve(_ request: JSONValue) -> String? {
    permissions += 1
    return "allow_once"
  }
}

@Test("Remote ACP providers obey the runtime's live airplane setting")
func acpProviderAirplaneMode() async throws {
  let provider = ACPProvider(
    id: "remote", displayName: "Remote",
    configuration: .init(command: "Remote", webSocketURL: URL(string: "ws://127.0.0.1:1/acp")))
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  for policy in [InternetAccessPolicy(airplaneModeEnabled: true), .init(networkAvailable: false)] {
    await runtime.configureInternetAccess(policy)
    await #expect(throws: InternetAccessError.self) {
      _ = try await provider.complete(ProviderRequest(model: "remote", messages: [.user("hello")]))
    }
  }
}

@Test("An offline ACP client cannot connect, discover, pair, or send a prompt")
func acpClientAirplaneMode() async throws {
  let client = ACPClient(
    configuration: .init(command: "Remote", webSocketURL: URL(string: "ws://127.0.0.1:1/acp")))
  await client.configureInternetAccess(.init(airplaneModeEnabled: true))
  await #expect(throws: InternetAccessError.self) { _ = try await client.connect() }
  await #expect(throws: InternetAccessError.self) { _ = try await client.workspace() }
  await #expect(throws: InternetAccessError.self) {
    _ = try await client.requestPairing(clientID: "client", name: "Client")
  }
  await #expect(throws: InternetAccessError.self) { _ = try await client.prompt("hello") { _ in } }
  #expect(await client.isConnected == false)
}

#if os(macOS) || os(Linux)
  @Test("An idle ACP connection reports a worker disconnect")
  func acpClientIdleDisconnect() async throws {
    let events = WebSocketEvents()
    let script = """
      import json, sys, time
      for line in sys.stdin:
          request = json.loads(line)
          method = request.get('method')
          result = {'protocolVersion': 1} if method == 'initialize' else {'sessionId': 'idle'}
          print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
          if method == 'session/new':
              time.sleep(0.1)
              break
      """
    let client = ACPClient(
      configuration: .init(command: "/usr/bin/python3", arguments: ["-u", "-c", script]),
      onDisconnect: { await events.disconnect() })
    #expect(try await client.connect() == "idle")
    #expect(await client.isConnected)
    let deadline = ContinuousClock.now + .seconds(5)
    while await events.disconnections == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await events.disconnections == 1)
    #expect(await client.isConnected == false)
    await client.disconnect()
    #expect(await events.disconnections == 1)
  }
#endif

// The smoke script supplies a real gateway running a deterministic ACP agent.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PMAI_GATEWAY_TEST_URL"] != nil))
func acpWebSocketIntegration() async throws {
  let environment = ProcessInfo.processInfo.environment
  let events = WebSocketEvents()
  let configuration = ACPClient.Configuration(
    command: "fixture", promptTimeout: 10,
    remoteWorkingDirectory: environment["PMAI_GATEWAY_TEST_CWD"], readClientFiles: false,
    webSocketURL: URL(string: try #require(environment["PMAI_GATEWAY_TEST_URL"])),
    bearerToken: environment["PMAI_GATEWAY_TEST_TOKEN"])
  let client = ACPClient(
    configuration: configuration,
    onUpdate: { await events.update($0) }, onPermission: { await events.approve($0) })
  let workspace = try #require(try await client.workspace())
  #expect(workspace.sessions.map(\.sessionID) == ["fixture-session", "other-session"])
  #expect(workspace.folders.contains { $0.name == "Empty project" })
  #expect(workspace.folders.contains { $0.cwd.hasSuffix("/other") })
  let id = try await client.connect()
  #expect(id == "fixture-session")
  _ = try await client.prompt("hello") { await events.event($0) }
  #expect(await events.text == "reply")
  #expect(await events.permissions == 1)
  await client.disconnect()
  #expect(try await client.connect() == id)
  #expect(
    await events.updates.contains(where: {
      ACP.ContentBlock.text(from: $0.objectValue?["content"]) == "restored"
    }))
  do {
    _ = try await client.prompt("exit") { _ in }
    Issue.record("Agent exit should fail the pending prompt")
  } catch { /* expected */  }
  #expect(try await client.connect() == id)
  await client.close()

  let configured = ConfiguredProvider(
    id: "remote", kind: "acp",
    options: [
      "url": .string(try #require(environment["PMAI_GATEWAY_TEST_URL"])),
      "tokenEnv": .string("PMAI_GATEWAY_TEST_TOKEN"),
      "remoteCwd": .string(try #require(environment["PMAI_GATEWAY_TEST_CWD"])),
      "permission": .string("allow"),
    ])
  let provider = try ACPConfiguredProviderFactory().makeProvider(
    from: configured, environment: environment)
  let reply = try await provider.complete(
    ProviderRequest(model: "remote", messages: [.user("hello")])
  ) { _ in }
  #expect(reply.message.text == "reply")
  await provider.configureInternetAccess(.init(airplaneModeEnabled: true))
  await #expect(throws: InternetAccessError.self) {
    _ = try await provider.complete(ProviderRequest(model: "remote", messages: [.user("blocked")]))
  }
  await provider.configureInternetAccess(.init())
  let restored = try await provider.complete(
    ProviderRequest(model: "remote", messages: [.user("online again")]))
  #expect(restored.message.text == "reply")
  await (provider as? ACPProvider)?.shutdown()
}
