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
  func event(_ event: ProviderEvent) {
    if case .textDelta(let delta) = event { text += delta }
  }
  func update(_ update: JSONValue) { updates.append(update) }
  func approve(_ request: JSONValue) -> String? {
    permissions += 1
    return "allow_once"
  }
}

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
  await (provider as? ACPProvider)?.shutdown()
}
