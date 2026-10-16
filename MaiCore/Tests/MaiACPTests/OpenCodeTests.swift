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
      body = #"[{"id":"prj_test","canonical":"/work","name":"Project","sandboxes":["/work/tree"]}]"#
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
        #"{"data":[{"id":"msg_user","type":"user","text":"Hello","time":{"created":1000}},{"id":"msg_answer","type":"assistant","time":{"created":2000},"content":[{"type":"reasoning","text":"Thinking"},{"type":"text","text":"Hello back"},{"type":"tool","id":"call_1","name":"read","state":{"status":"completed","content":[{"type":"text","text":"File contents"}]}}]},{"id":"msg_idle","type":"idle","outcome":"succeeded"}]}"#
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
