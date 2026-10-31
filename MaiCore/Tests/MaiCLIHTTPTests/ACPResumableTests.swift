import Foundation
@testable import MaiACP
import MaiACPGateway
import MaiCore
import Testing

#if os(macOS) || os(Linux)
@Test("A lost remote socket preserves the worker, its turn and its pending approval", .timeLimit(.minutes(1)))
func acpResumableGateway() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-resume-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let token = String(repeating: "a", count: 64)
  let file = root.appendingPathComponent("token")
  try Data(token.utf8).write(to: file)
  let script = #"""
    import json, os, sys
    pending = None
    prompts = 0
    injected = None
    def send(value):
        print(json.dumps(dict(jsonrpc='2.0', **value)), flush=True)
    def state(running):
        send({'method': 'session/update', 'params': {'sessionId': 'fixture', 'update': {
            'sessionUpdate': '_pmai/session_state', 'running': running}}})
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get('method')
        result = {}
        if method == 'initialize':
            result = {'protocolVersion': 1, 'worker': os.getpid()}
        elif method == 'session/new':
            result = {'sessionId': 'fixture'}
        elif method == 'session/load':
            state(pending is not None)
        elif method == 'session/prompt':
            prompts += 1
            pending = message['id']
            state(True)
            send({'id': -1, 'method': 'session/request_permission', 'params': {
                'sessionId': 'fixture', 'toolCall': {'title': 'run_shell', 'rawInput': {'script': 'pwd'}},
                'options': [{'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'}]}})
            continue
        elif method == '_pmai/session/inject':
            injected = message
            send({'method': 'session/update', 'params': {'sessionId': 'fixture', 'update': {
                'sessionUpdate': '_pmai/session_state', 'injected': True}}})
            continue
        elif method == 'inspect':
            result = {'prompts': prompts, 'running': pending is not None}
        elif method == 'session/cancel':
            if pending is not None:
                send({'id': pending, 'result': {'stopReason': 'cancelled'}})
                pending = None
                state(False)
            continue
        elif method is None and message.get('id') == -1:
            send({'id': pending, 'result': {'stopReason': 'end_turn'}})
            if injected is not None:
                send({'id': injected['id'], 'result': {'text': injected['params']['text']}})
                injected = None
            pending = None
            state(False)
            continue
        send({'id': message['id'], 'result': result})
    """#
  let listening = AsyncStream<String>.makeStream()
  let serving = Task {
    try await ACPWebSocketGateway.serve(.init(
      port: 0, tokenFile: file, command: "/usr/bin/python3", arguments: ["-u", "-c", script],
      workingDirectory: root, resumable: true)) { listening.continuation.yield($0) }
  }
  defer { serving.cancel() }
  var addresses = listening.stream.makeAsyncIterator()
  let address = try #require(await addresses.next())
  let port = try #require(Int(address.split(separator: ":").last ?? ""))
  let url = try #require(URL(string: "ws://127.0.0.1:\(port)/acp"))
  let resumeID = UUID().uuidString
  let initialize: JSONValue = .object([
    "protocolVersion": .integer(1),
    "_meta": .object(["pmai": .object(["resumeId": .string(resumeID)])]),
  ])
  let firstPermission = AsyncStream<JSONValue>.makeStream()
  let firstTransport = try ForwirohWebSocketTransport(url: url, bearerToken: token)
  let first = JSONRPCPeer(transport: firstTransport, onRequest: { _, params in
    firstPermission.continuation.yield(params ?? .null)
    // Closing the peer cancels this handler, without sending a denial to the worker.
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  })
  await first.start()
  let before = try await first.request(ACP.Method.initialize, params: initialize, timeout: 15)
  _ = try await first.request(ACP.Method.sessionNew, timeout: 15)
  let turn = Task { try await first.request(ACP.Method.sessionPrompt, timeout: 20) }
  var firstRequests = firstPermission.stream.makeAsyncIterator()
  _ = try #require(await firstRequests.next())
  await first.close()
  _ = try? await turn.value

  let replayed = AsyncStream<JSONValue>.makeStream()
  let decisions = AsyncStream<JSONValue>.makeStream()
  let states = AsyncStream<Bool>.makeStream()
  let arrivals = AsyncStream<Bool>.makeStream()
  let second = JSONRPCPeer(transport: try ForwirohWebSocketTransport(url: url, bearerToken: token), onRequest: { _, params in
    replayed.continuation.yield(params ?? .null)
    for await decision in decisions.stream { return decision }
    throw CancellationError()
  }, onNotification: { _, params in
    if params?.objectValue?["update"]?.objectValue?["injected"]?.boolValue == true {
      arrivals.continuation.yield(true)
    }
    if let running = params?.objectValue?["update"]?.objectValue?["running"]?.boolValue {
      states.continuation.yield(running)
    }
  })
  await second.start()
  let after = try await second.request(ACP.Method.initialize, params: initialize, timeout: 15)
  #expect(before.objectValue?["worker"] == after.objectValue?["worker"])
  _ = try await second.request(ACP.Method.sessionLoad, timeout: 15)
  var restored = replayed.stream.makeAsyncIterator()
  let permission = try #require(await restored.next())
  #expect(permission.objectValue?["toolCall"]?.objectValue?["title"]?.stringValue == "run_shell")
  // Its local request ID is the same as the old connection's prompt ID.
  let injection = Task {
    try await second.request("_pmai/session/inject", params: .object(["text": .string("steer")]), timeout: 15)
  }
  // Use an explicit acknowledgement to ensure injection arrived before approval.
  var arrived = arrivals.stream.makeAsyncIterator()
  #expect(await arrived.next() == true)
  decisions.continuation.yield(.object(["outcome": .object([
    "outcome": .string("selected"), "optionId": .string("allow_once"),
  ])]))
  let injected = try await injection.value
  #expect(injected.objectValue?["text"]?.stringValue == "steer")
  var updates = states.stream.makeAsyncIterator()
  while let running = await updates.next() { if !running { break } }
  let inspected = try await second.request("inspect", timeout: 15)
  #expect(inspected.objectValue?["prompts"]?.intValue == 1)
  #expect(inspected.objectValue?["running"]?.boolValue == false)
  let stopped = Task { try await second.request(ACP.Method.sessionPrompt, timeout: 20) }
  _ = try #require(await restored.next())
  try second.notify(ACP.Method.sessionCancel, params: .object(["sessionId": .string("fixture")]))
  #expect(try await stopped.value.objectValue?["stopReason"]?.stringValue == "cancelled")
  let connected = try await second.request("inspect", timeout: 15)
  #expect(connected.objectValue?["running"]?.boolValue == false)
  await second.close()
  serving.cancel()
  _ = try? await serving.value
}
#endif
