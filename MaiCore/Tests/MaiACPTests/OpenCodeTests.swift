import Foundation
import MaiCore
import Testing

@testable import MaiACP
@testable import MaiTestSupport

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test("OpenCode pairing accepts printed links and the actual multi-address QR payload")
func openCodePairingFormats() throws {
  let origin = "https://random.route.opentunnel.xyz"
  let link = try OpenCodePairingLink.parse(" \n\(origin)/auth/connect/abc_DEF-123 \n")
  #expect(link.urls.map(\.absoluteString) == [origin])
  #expect(link.code == "abc_DEF-123")
  let qr = try OpenCodePairingLink.parse(
    """
    {"code":"abc_DEF-123","urls":["\(origin)","http://192.168.1.2:49374","\(origin)"]}
    """)
  #expect(qr.urls.map(\.absoluteString) == [origin, "http://192.168.1.2:49374"])
  #expect(qr.code == link.code)
  let local = try OpenCodePairingLink.parse("http://[::1]:49374/auth/connect/local")
  #expect(local.urls.first?.port == 49374)
  #expect(throws: JSONRPCError.self) {
    try ACPRemoteConnection.parse(origin + "/auth/connect/code")
  }
}

@Test(
  "Malformed OpenCode links cannot become credential-bearing requests",
  arguments: [
    "https://server.example/auth/connect/", "https://server.example/auth/connect/code/extra",
    "wss://server.example/auth/connect/code", "https://user:pass@server.example/auth/connect/code",
    "https://server.example/auth/connect/code?redirect=elsewhere",
    "https://server.example/auth/connect/code#secret",
    "https://server.example/auth/connect/%2F", "https://server.example/auth/connect/..",
    "https://server.example", "{\"code\":\"abc\",\"urls\":[]}",
    "{\"code\":\"abc\",\"urls\":[\"file:///tmp/server\"]}",
    "{\"code\":\"abc\",\"urls\":[\"https://valid.example\",\"wss://invalid.example\"]}",
  ])
func openCodeInvalidPairing(_ text: String) {
  #expect(throws: (any Error).self) { try OpenCodePairingLink.parse(text) }
}

private func openCodeTestConfiguration() -> URLSessionConfiguration {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubURLProtocol.self]
  return configuration
}

@Test(
  "Pairing redeems JSON once, falls back to reachable URLs, and uses Basic session authentication")
func openCodePairingRedemption() async throws {
  let unreachable = "unreachable.opencode.test"
  let host = "pairing.opencode.test"
  let methods = MethodRecorder()
  StubURLProtocol.install(forHost: unreachable) { _ in throw URLError(.cannotConnectToHost) }
  StubURLProtocol.install(forHost: host) { request in
    methods.record(request.url!.path)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    if request.url?.path == "/auth/connect/test-code" {
      #expect(request.httpMethod == "GET")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      return try httpResponse(
        request, contentType: "application/json", body: #"{"token":"session-secret"}"#)
    }
    #expect(
      request.value(forHTTPHeaderField: "Authorization") == "Basic "
        + Data("opencode:session-secret".utf8).base64EncodedString())
    return try httpResponse(
      request, contentType: "application/json", body: #"{"version":"2.0.30"}"#)
  }
  defer {
    StubURLProtocol.reset(host: host)
    StubURLProtocol.reset(host: unreachable)
  }
  let link = try OpenCodePairingLink.parse(
    """
    {"code":"test-code","urls":["https://\(unreachable)","https://\(host)"]}
    """)
  let connection = try await link.redeem(configuration: openCodeTestConfiguration())
  #expect(connection.url.host == host)
  #expect(connection.token == "session-secret")
  #expect(connection.cwd.isEmpty)
  let http = OpenCodeHTTP(
    url: connection.url, token: connection.token, configuration: openCodeTestConfiguration())
  defer { http.close() }
  _ = try await http.request(["api", "info"])
  #expect(methods.methods == ["/auth/connect/test-code", "/api/info"])
}

@Test("Expired OpenCode invitations explain how to generate a replacement")
func openCodeExpiredPairing() async throws {
  let host = "expired.opencode.test"
  StubURLProtocol.install(forHost: host) { request in
    try httpResponse(request, status: 401, contentType: "application/json", body: "{}")
  }
  defer { StubURLProtocol.reset(host: host) }
  let link = try OpenCodePairingLink.parse("https://\(host)/auth/connect/used-code")
  do {
    _ = try await link.redeem(configuration: openCodeTestConfiguration())
    Issue.record("A used invitation must not pair")
  } catch {
    #expect(error.localizedDescription.contains("expired or was already used"))
    #expect(error.localizedDescription.contains("opencode pair --remote"))
  }
}

private actor OpenCodeUpdates {
  var values: [JSONValue] = []
  var permissions = 0
  func append(_ value: JSONValue) { values.append(value) }
  func askedPermission() { permissions += 1 }
}

@Test(
  "OpenCode turn failures preserve the connection; host authentication and network failures do not",
  arguments: ["provider", "unauthorized", "network"])
func openCodePromptFailureRecovery(_ scenario: String) async throws {
  let host = "failure-\(scenario).opencode.test"
  let methods = MethodRecorder()
  let promptPath = "/api/session/session/prompt"
  StubURLProtocol.install(forHost: host) { request in
    let path = request.url!.path
    methods.record(path)
    let attempts = methods.methods.filter { $0 == promptPath }.count
    let body: String
    switch path {
    case promptPath:
      if scenario == "network" { throw URLError(.networkConnectionLost) }
      if scenario == "unauthorized" {
        return try httpResponse(request, status: 401, contentType: "application/json", body: "{}")
      }
      body = "{}"
    case "/api/session/session/message", "/api/session/session/context":
      body = attempts == 0 ? #"{"data":[]}"# : attempts == 1
        ? #"{"data":[{"id":"failed","type":"idle","outcome":"failed","error":{"message":"This API key has expired."}}]}"#
        : #"{"data":[{"id":"failed","type":"idle","outcome":"failed","error":{"message":"This API key has expired."}},{"id":"done","type":"idle","outcome":"succeeded"}]}"#
    case "/api/experimental/session/session/wait":
      body = "{}"
    case "/api/session/session/permission":
      body = #"{"data":[]}"#
    case "/api/session/session":
      body = #"{"data":{"location":{"directory":"/work"},"model":{"id":"model","providerID":"provider"}}}"#
    case "/api/model":
      body = #"{"data":[{"id":"model","providerID":"provider"}]}"#
    case "/api/agent":
      body = #"{"data":[]}"#
    default:
      Issue.record("Unexpected request: \(path)")
      throw URLError(.unsupportedURL)
    }
    return try httpResponse(request, contentType: "application/json", body: body)
  }
  defer { StubURLProtocol.reset(host: host) }
  let client = OpenCodeClient(
    connection: try .init(url: #require(URL(string: "https://\(host)")), token: "test"),
    sessionID: "session", configuration: openCodeTestConfiguration())
  _ = try await client.connect()
  do {
    _ = try await client.prompt("First attempt") { _ in }
    Issue.record("The first prompt must fail")
  } catch {
    if scenario == "provider" {
      #expect(error is OpenCodeClient.SessionFailure)
      #expect(error.localizedDescription == "This API key has expired.")
    } else if scenario == "unauthorized" {
      #expect(error.localizedDescription.contains("Pair this host again"))
    }
  }
  #expect(methods.methods.filter { $0 == promptPath }.count == 1)
  #expect(await client.isConnected == (scenario == "provider"))
  if scenario == "provider" {
    #expect(try await client.configurationOptions().contains { $0.id == "model" })
    #expect(try await client.prompt("Try again", emit: { _ in }) == .stop)
    #expect(await client.isConnected)
    #expect(methods.methods.filter { $0 == promptPath }.count == 2)
  }
  await client.disconnect()
}

@Test(
  "OpenCode rewinds server history before retrying, resets from the first event, and handles failures",
  arguments: ["retry", "reset", "stale", "staged", "stageFailure", "commitFailure", "cancel"])
func openCodeHistoryRewind(_ scenario: String) async throws {
  let host = "rewind-\(scenario.lowercased()).opencode.test"
  let methods = MethodRecorder()
  let updates = OpenCodeUpdates()
  let stageRelease = DispatchSemaphore(value: 0)
  let boundary = scenario == "reset" ? "msg_setup" : "msg_second"
  let original =
    #"{"data":[{"id":"msg_setup","type":"synthetic"},{"id":"msg_first","type":"user","text":"First"},{"id":"msg_second","type":"user","text":"Second"},{"id":"msg_answer","type":"assistant","content":[{"type":"text","text":"Old answer"}]}]}"#
  StubURLProtocol.install(forHost: host) { request in
    let method = request.httpMethod ?? "GET"
    let path = request.url!.path
    methods.record(method + " " + path)
    var status = 200
    let body: String
    switch (method, path) {
    case ("GET", "/api/session/ses_test"):
      let pending =
        scenario == "staged"
        || ((scenario == "commitFailure" || scenario == "cancel")
          && methods.methods.contains("POST /api/session/ses_test/revert/stage"))
      body =
        pending
        ? #"{"data":{"revert":{"messageID":"msg_second","files":[]}}}"# : #"{"data":{}}"#
    case ("GET", "/api/session/ses_test/message"), ("GET", "/api/session/ses_test/context"):
      if methods.methods.contains("POST /api/session/ses_test/prompt") {
        body =
          #"{"data":[{"id":"msg_new","type":"user","text":"Second"},{"id":"msg_idle","type":"idle","outcome":"succeeded"}]}"#
      } else if methods.methods.contains("POST /api/session/ses_test/revert/commit")
        && scenario != "commitFailure"
      {
        body =
          scenario == "reset"
          ? #"{"data":[]}"#
          : #"{"data":[{"id":"msg_setup","type":"synthetic"},{"id":"msg_first","type":"user","text":"First"}]}"#
      } else {
        body = original
      }
    case ("POST", "/api/session/ses_test/revert/stage"):
      let input = try JSONDecoder().decode(JSONValue.self, from: requestBodyData(request))
      #expect(input == .object(["messageID": .string(boundary), "files": .bool(false)]))
      if scenario == "cancel" { _ = stageRelease.wait(timeout: .now() + 5) }
      status = scenario == "stageFailure" ? 409 : 200
      body = "{}"
    case ("POST", "/api/session/ses_test/revert/commit"):
      status = scenario == "commitFailure" ? 500 : 200
      body = ""
    case ("DELETE", "/api/session/ses_test/revert"):
      #expect(scenario == "commitFailure" || scenario == "cancel")
      body = ""
    case ("POST", "/api/session/ses_test/prompt"):
      let input = try JSONDecoder().decode(JSONValue.self, from: requestBodyData(request))
      #expect(input.objectValue?["text"]?.stringValue == "Second")
      body = #"{"data":{"id":"msg_new"}}"#
    case ("POST", "/api/experimental/session/ses_test/wait"):
      body = ""
    case ("GET", "/api/session/ses_test/permission"):
      body = #"{"data":[]}"#
    default:
      Issue.record("Unexpected request: \(method) \(path)")
      body = "{}"
    }
    return try httpResponse(request, status: status, contentType: "application/json", body: body)
  }
  defer { StubURLProtocol.reset(host: host) }
  let client = OpenCodeClient(
    connection: try .init(
      url: #require(URL(string: "https://\(host)")), token: "test", cwd: "/work"),
    sessionID: "ses_test", configuration: openCodeTestConfiguration(),
    onUpdate: { await updates.append($0) })
  #expect(client.supportsHistoryRewind)
  _ = try await client.connect()
  let succeeds = scenario == "retry" || scenario == "reset"
  do {
    if scenario == "cancel" {
      let task = Task { try await client.rewind(to: boundary) }
      for _ in 0..<500 {
        if methods.methods.contains("POST /api/session/ses_test/revert/stage") { break }
        try await Task.sleep(for: .milliseconds(1))
      }
      #expect(methods.methods.contains("POST /api/session/ses_test/revert/stage"))
      task.cancel()
      await client.disconnect()
      stageRelease.signal()
      try await task.value
    } else {
      try await client.rewind(
        to: scenario == "reset" ? nil : scenario == "stale" ? "missing" : boundary)
    }
    #expect(succeeds)
    let snapshot = await updates.values.last?.objectValue?["messages"]?.arrayValue ?? []
    #expect(
      snapshot.compactMap { $0.objectValue?["text"]?.stringValue }
        == (scenario == "reset" ? [] : ["First"]))
    _ = try await client.prompt("Second") { _ in }
  } catch {
    #expect(!succeeds)
  }
  let mutations = methods.methods.filter { !$0.hasPrefix("GET ") }
  if succeeds {
    #expect(
      mutations.prefix(3) == [
        "POST /api/session/ses_test/revert/stage", "POST /api/session/ses_test/revert/commit",
        "POST /api/session/ses_test/prompt",
      ])
  } else {
    #expect(!mutations.contains("POST /api/session/ses_test/prompt"))
    if scenario == "stale" || scenario == "staged" { #expect(mutations.isEmpty) }
    if scenario == "stageFailure" { #expect(mutations.count == 1) }
    if scenario == "commitFailure" || scenario == "cancel" {
      #expect(mutations.last == "DELETE /api/session/ses_test/revert")
    }
    if scenario == "cancel" { #expect(mutations.count == 2) }
  }
  await client.disconnect()
}

@Test("ACP exposes resubmission without claiming to support history rewind")
func acpHistoryRewindUnsupported() async {
  let client: any RemoteSessionClient = ACPClient(configuration: .init(command: "unused"))
  #expect(!client.supportsHistoryRewind)
  await #expect(throws: JSONRPCError.self) { try await client.rewind(to: "message") }
}

@Test("OpenCode v2 discovers paged sessions, restores history, sends prompts and manages chats")
func openCodeNativeSessions() async throws {
  let host = "sessions.opencode.test"
  let methods = MethodRecorder()
  let updates = OpenCodeUpdates()
  StubURLProtocol.install(forHost: host) { request in
    let path = request.url!.path
    let method = request.httpMethod ?? "GET"
    methods.record(method + " " + path)
    #expect(
      request.value(forHTTPHeaderField: "Authorization") == "Basic "
        + Data("opencode:session-secret".utf8).base64EncodedString())
    var body: String
    switch (method, path) {
    case ("GET", "/api/project"):
      body =
        #"[{"id":"prj_test","canonical":"/work","name":"Project","time":{"updated":3000},"sandboxes":["/work/tree"]}]"#
    case ("GET", "/api/session"):
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
      if query?.contains(where: { $0.name == "cursor" && $0.value == "next-page" }) == true {
        body =
          #"{"data":[{"id":"ses_other","title":"Other","location":{"directory":"/other"},"time":{"updated":2000}}],"cursor":{}}"#
      } else {
        body =
          #"{"data":[{"id":"ses_existing","title":"Existing","location":{"directory":"/work"},"time":{"updated":1000}}],"cursor":{"next":"next-page"}}"#
      }
    case ("POST", "/api/session"):
      let input = try JSONDecoder().decode(JSONValue.self, from: requestBodyData(request))
      #expect(input.objectValue?["location"]?.objectValue?["directory"]?.stringValue == "/work")
      body = #"{"data":{"id":"ses_new"}}"#
    case ("GET", "/api/session/ses_new/context"), ("GET", "/api/session/ses_new/message"),
      ("GET", "/api/session/ses_existing/message"):
      body =
        #"{"data":[{"id":"msg_user","type":"user","text":"Hello","time":{"created":1000}},{"id":"msg_answer","type":"assistant","time":{"created":2000},"content":[{"type":"reasoning","text":"Thinking"},{"type":"text","text":"Hello back"},{"type":"tool","id":"call_1","name":"read","state":{"status":"completed","input":{"path":"README.md"},"content":[{"type":"text","text":"File contents"}]}}]},{"id":"msg_idle","type":"idle","outcome":"succeeded"}]}"#
    case ("POST", "/api/session/ses_new/prompt"):
      let input = try JSONDecoder().decode(JSONValue.self, from: requestBodyData(request))
      #expect(input.objectValue?["text"]?.stringValue == "Hello")
      body = #"{"data":{"id":"msg_user"}}"#
    case ("POST", "/api/experimental/session/ses_new/wait"):
      body = ""
    case ("GET", "/api/session/ses_new/permission"):
      body = #"{"data":[]}"#
    case ("PATCH", "/api/session/ses_new"):
      let input = try JSONDecoder().decode(JSONValue.self, from: requestBodyData(request))
      #expect(input.objectValue?["title"]?.stringValue == "Renamed")
      body = ""
    case ("DELETE", "/api/session/ses_new"):
      body = ""
    default:
      Issue.record("Unexpected request: \(method) \(path)")
      throw URLError(.badURL)
    }
    return try httpResponse(request, contentType: "application/json", body: body)
  }
  defer { StubURLProtocol.reset(host: host) }
  let connection = try OpenCodeConnection(
    url: URL(string: "https://\(host)")!, token: "session-secret", cwd: "/work")
  let client = OpenCodeClient(
    connection: connection, configuration: openCodeTestConfiguration(),
    onUpdate: { await updates.append($0) })
  let workspace = try #require(try await client.workspace())
  #expect(workspace.folders.map(\.cwd) == ["/work", "/work/tree", "/other"])
  #expect(
    workspace.folders.map(\.updatedAt) == [
      Date(timeIntervalSince1970: 3), Date(timeIntervalSince1970: 3), nil,
    ])
  #expect(workspace.sessions.map(\.sessionID) == ["ses_existing", "ses_other"])
  #expect(workspace.sessions.first?.updatedAt == Date(timeIntervalSince1970: 1))
  #expect(workspace.canManageSessions == true)
  #expect(try await client.connect() == "ses_new")
  #expect(try await client.prompt("Hello", emit: { _ in }) == .stop)
  let snapshot = try #require(await updates.values.last?.objectValue?["messages"]?.arrayValue)
  #expect(
    snapshot.compactMap { $0.objectValue?["role"]?.stringValue } == [
      "user", "thought", "assistant", "tool",
    ])
  #expect(snapshot.last?.objectValue?["text"]?.stringValue == "read\nFile contents")
  var transcript: [ACPConversationMessage] = []
  ACPConversationTranscript.apply(try #require(await updates.values.last), to: &transcript)
  let cached = try JSONDecoder().decode(
    [ACPConversationMessage].self, from: JSONEncoder().encode(transcript))
  #expect(cached.last?.toolName == "read")
  #expect(cached.last?.toolInput == .object(["path": .string("README.md")]))
  try await client.manageSession("ses_new", cwd: "/work", title: "Renamed")
  try await client.manageSession("ses_new", cwd: "/work", title: nil)
  await client.disconnect()
  #expect(await !client.isConnected)
  let restored = OpenCodeClient(
    connection: connection, sessionID: "ses_existing", configuration: openCodeTestConfiguration())
  #expect(try await restored.connect() == "ses_existing")
  await restored.disconnect()
  #expect(methods.methods.filter { $0 == "POST /api/session" }.count == 1)
  #expect(methods.methods.filter { $0 == "POST /api/session/ses_new/prompt" }.count == 1)
}

@Test("OpenCode restores the first prompt across opaque history pages, including an empty final page")
func openCodePagedHistory() async throws {
  let host = "history.opencode.test"
  let updates = OpenCodeUpdates()
  StubURLProtocol.install(forHost: host) { request in
    #expect(request.url?.path == "/api/session/session/message")
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let cursor = query.first { $0.name == "cursor" }?.value
    #expect(query.contains { $0.name == "order" } == (cursor == nil))
    let body: String
    if cursor == nil {
      #expect(query.first { $0.name == "order" }?.value == "asc")
      body = #"{"data":[{"id":"first","type":"user","text":"First prompt"}],"cursor":{"next":"opaque+/="}}"#
    } else if cursor == "opaque+/=" {
      body = #"{"data":[{"id":"second","type":"assistant","content":[{"type":"text","text":"Answer"}]}],"cursor":{"next":"end"}}"#
    } else {
      #expect(cursor == "end")
      body = #"{"data":[],"cursor":{}}"#
    }
    return try httpResponse(request, contentType: "application/json", body: body)
  }
  defer { StubURLProtocol.reset(host: host) }
  let client = OpenCodeClient(
    connection: try .init(url: #require(URL(string: "https://\(host)")), token: "test"),
    sessionID: "session", configuration: openCodeTestConfiguration(),
    onUpdate: { await updates.append($0) })
  _ = try await client.connect()
  var transcript: [ACPConversationMessage] = []
  ACPConversationTranscript.apply(try #require(await updates.values.last), to: &transcript)
  #expect(transcript.map(\.text) == ["First prompt", "Answer"])
  #expect(transcript.map(\.remoteID) == ["first", "second:0"])
  await client.disconnect()
}

#if os(macOS) || os(Linux)
  @Test(
    "OpenCode HTTP pairing, permissions, completion and cancellation work over a real socket",
    arguments: [false, true])
  func openCodeHTTPIntegration(cancel: Bool) async throws {
    let script = #"""
      import base64, json, threading
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      done = threading.Event()
      state = dict(paired=False, prompts=0, replies=0, interrupts=0)
      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *args): pass
          def send(self, value, status=200):
              data = json.dumps(value).encode()
              self.send_response(status)
              self.send_header('Content-Type', 'application/json')
              self.send_header('Content-Length', str(len(data)))
              self.end_headers()
              self.wfile.write(data)
          def do_GET(self):
              path = self.path.split('?')[0]
              if path == '/auth/connect/redirect':
                  self.send_response(302)
                  self.send_header('Location', '/auth/connect/valid')
                  self.end_headers()
                  return
              if path == '/auth/connect/valid':
                  assert self.headers['Accept'] == 'application/json'
                  if state['paired']: return self.send({}, 401)
                  state['paired'] = True
                  return self.send(dict(token='fixture-session'))
              assert self.headers['Authorization'] == 'Basic ' + base64.b64encode(b'opencode:fixture-session').decode()
              if path == '/stats': return self.send(state)
              if path.endswith('/permission'):
                  return self.send(dict(data=[] if done.is_set() else [dict(id='per_1', action='read', resources=['/work/file'])]))
              if path.endswith('/context') or path.endswith('/message'):
                  messages = [] if not state['prompts'] else [dict(id='msg_1', type='user', text='Read'), dict(id='msg_2', type='assistant', content=[dict(type='text', text='Finished' if done.is_set() else 'Reading')])]
                  if done.is_set(): messages.append(dict(id='msg_3', type='idle', outcome='succeeded'))
                  return self.send(dict(data=messages, cursor={}))
              self.send({}, 404)
          def do_POST(self):
              assert self.headers['Authorization'] == 'Basic ' + base64.b64encode(b'opencode:fixture-session').decode()
              body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
              if self.path.endswith('/prompt'):
                  assert json.loads(body) == dict(text='Read')
                  state['prompts'] += 1
                  return self.send(dict(data=dict(id='msg_1')))
              if self.path.endswith('/wait'):
                  return self.send({}, 200 if done.wait(5) else 500)
              if self.path.endswith('/permission/per_1/reply'):
                  assert json.loads(body) == dict(decision='once')
                  state['replies'] += 1
                  done.set()
                  return self.send({})
              if self.path.endswith('/interrupt'):
                  state['interrupts'] += 1
                  done.set()
                  return self.send(dict(interrupted=True))
              self.send({}, 404)
      server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
      print(server.server_port, flush=True)
      server.serve_forever()
      """#
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", "-c", script]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      process.terminate()
      process.waitUntilExit()
    }
    let port = try #require(
      Int(
        String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    let base = "http://127.0.0.1:\(port)"
    // A redirect must not silently consume the one-time link.
    await #expect(throws: JSONRPCError.self) {
      try await OpenCodePairingLink.parse(base + "/auth/connect/redirect").redeem()
    }
    let connection = try await OpenCodePairingLink.parse(base + "/auth/connect/valid").redeem()
    let updates = OpenCodeUpdates()
    let client = OpenCodeClient(
      connection: connection, sessionID: "ses_test",
      onUpdate: { await updates.append($0) },
      onPermission: { request in
        #expect(request.objectValue?["toolCall"]?.objectValue?["title"]?.stringValue == "read")
        await updates.askedPermission()
        if cancel { try await Task.sleep(for: .seconds(10)) }
        return "once"
      })
    _ = try await client.connect()
    let prompt = Task { try await client.prompt("Read", emit: { _ in }) }
    if cancel {
      let deadline = ContinuousClock.now + .seconds(5)
      while await updates.permissions == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      prompt.cancel()
      await #expect(throws: CancellationError.self) { try await prompt.value }
    } else {
      #expect(try await prompt.value == .stop)
      let messages = await updates.values.last?.objectValue?["messages"]?.arrayValue
      #expect(messages?.last?.objectValue?["text"]?.stringValue == "Finished")
    }
    #expect(await updates.permissions == 1)
    let http = OpenCodeHTTP(url: connection.url, token: connection.token)
    defer { http.close() }
    let stats = try await http.request(["stats"])
    #expect(stats.objectValue?["prompts"]?.numberValue == 1)
    #expect(stats.objectValue?["replies"]?.numberValue == (cancel ? 0 : 1))
    #expect(stats.objectValue?["interrupts"]?.numberValue == (cancel ? 1 : 0))
    await client.disconnect()
  }
#endif

@Test(
  "OpenCode settings use project catalogs and persist native model, variant and agent references")
func openCodeSessionSettings() async throws {
  let host = "settings.opencode.test"
  let state = OpenCodeSettingsFixture()
  StubURLProtocol.install(forHost: host) { request in try state.respond(request) }
  defer { StubURLProtocol.reset(host: host) }
  let client = OpenCodeClient(
    connection: try .init(
      name: "Fixture", url: URL(string: "https://\(host)")!, token: "secret", cwd: "/wrong"),
    sessionID: "session", configuration: openCodeTestConfiguration())
  _ = try await client.connect()
  let initial = try await client.configurationOptions()
  #expect(initial.first(where: { $0.id == "provider" })?.currentValue == .string("one"))
  #expect(initial.first(where: { $0.id == "agent" })?.choices.map(\.id) == ["build", "plan"])
  let changed = try await client.setConfigurationOption(id: "provider", value: .string("two"))
  #expect(changed.first(where: { $0.id == "model" })?.currentValue == .string("alias"))
  #expect(changed.first(where: { $0.id == "variant" })?.choices.map(\.id) == ["", "high"])
  let high = try await client.setConfigurationOption(id: "variant", value: .string("high"))
  #expect(high.first(where: { $0.id == "variant" })?.currentValue == .string("high"))
  let unchanged = try await client.setConfigurationOption(id: "model", value: .string("alias"))
  #expect(unchanged.first(where: { $0.id == "variant" })?.currentValue == .string("high"))
  let reset = try await client.setConfigurationOption(id: "variant", value: .string(""))
  #expect(reset.first(where: { $0.id == "variant" })?.currentValue == .string(""))
  let planned = try await client.setConfigurationOption(id: "agent", value: .string("plan"))
  #expect(planned.first(where: { $0.id == "agent" })?.currentValue == .string("plan"))
  await #expect(throws: JSONRPCError.self) {
    _ = try await client.setConfigurationOption(id: "model", value: .string("underlying-id"))
  }
  await client.disconnect()
}

private final class OpenCodeSettingsFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var model: JSONValue?
  private var agent = "build"

  func respond(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
    lock.lock()
    defer { lock.unlock() }
    let path = request.url!.path
    var result: JSONValue = .object([:])
    if path == "/api/session/session/message" {
      result = .object(["data": .array([])])
    } else if path == "/api/session/session/model" || path == "/api/session/session/agent" {
      #expect(request.httpMethod == "POST")
      let body = try JSONDecoder().decode(JSONValue.self, from: requestBodyData(request))
        .objectValue!
      if let value = body["model"] {
        model = value
        #expect(value.objectValue?["id"]?.stringValue == "alias")
        #expect(value.objectValue?["providerID"]?.stringValue == "two")
        #expect(Set(value.objectValue!.keys).isSubset(of: ["id", "providerID", "variant"]))
      }
      if let value = body["agent"]?.stringValue { agent = value }
    } else if path == "/api/session/session" {
      var info: [String: JSONValue] = [
        "location": .object(["directory": .string("/project with spaces")]),
        "agent": .string(agent),
      ]
      info["model"] = model
      result = .object(["data": .object(info)])
    } else {
      #expect(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [
          URLQueryItem(name: "location[directory]", value: "/project with spaces")
        ])
      let defaultModel = JSONValue.object([
        "id": .string("a"), "providerID": .string("one"), "name": .string("A"),
      ])
      if path == "/api/model/default" {
        result = .object(["data": defaultModel])
      } else if path == "/api/model" {
        result = .object([
          "data": .array([
            defaultModel,
            .object([
              "id": .string("alias"), "modelID": .string("underlying-id"),
              "providerID": .string("two"),
              "name": .string("Second"), "enabled": .bool(true),
              "variants": .array([.object(["id": .string("high")])]),
            ]),
            .object([
              "id": .string("disabled"), "providerID": .string("two"), "enabled": .bool(false),
            ]),
          ])
        ])
      } else if path == "/api/agent" {
        result = .object([
          "data": .array([
            .object(["id": .string("build"), "name": .string("Build"), "mode": .string("primary")]),
            .object(["id": .string("plan"), "name": .string("Plan"), "mode": .string("primary")]),
            .object(["id": .string("internal"), "mode": .string("subagent")]),
            .object(["id": .string("hidden"), "hidden": .bool(true)]),
          ])
        ])
      } else {
        Issue.record("Unexpected request: \(path)")
      }
    }
    return (
      HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!, try JSONEncoder().encode(result)
    )
  }
}
