import CryptoExtras
import Foundation
import Testing

@testable import MaiCore
@testable import MaiOpenAI
@testable import MaiTestSupport

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if !os(Windows)
  @Suite(.serialized)
  struct ChatGPTTests {
    func temporaryStore(_ name: String = "chatgpt") -> ChatGPTCredentialStore {
      .init(
        providerID: name,
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func signedInStore() throws -> ChatGPTCredentialStore {
      let store = temporaryStore()
      var account = ChatGPTCredentials(clientID: "oaiapp_test")
      account.accessToken = "subscription-token"
      account.expiresAt = Date().addingTimeInterval(3600)
      account.scopes = ["chatgpt.tokens.use.direct"]
      try store.save(account)
      return store
    }

    @Test func registrationUsesDynamicClientAndStableHost() async throws {
      let store = temporaryStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      let auth = ChatGPTAuth(session: stubSession())
      let uri = try #require(URL(string: "http://127.0.0.1:54321/auth/callback"))
      let first = try await auth.beginSignIn(store: store, redirectURI: uri)
      let second = try await auth.beginSignIn(store: store, redirectURI: uri)
      let query = try #require(
        URLComponents(url: first.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
      let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
      #expect(values["client_id"] == "dynamic_agent_client")
      #expect(values["agent_name_hint"] == "pmai")
      #expect(values["resource"] == "https://api.openai.com/v1")
      #expect(values["scope"]?.contains("chatgpt.tokens.use.direct") == true)
      #expect(values["ext_agent_host_id"] == (try store.hostID()))
      #expect(first.state != second.state)
      #expect(first.nonce != second.nonce)
      #expect(first.verifier != second.verifier)
      #expect(first.verifier.count >= 43)
      await #expect(throws: ChatGPTError.self) {
        try await auth.finishSignIn(
          first,
          callback: URL(
            string: uri.absoluteString + "?state=wrong&code=secret&client_id=oaiapp_test")!,
          store: store)
      }
      #expect(try store.load() == nil)
    }

    @Test func returningRegistrationReusesClientAfterLogout() async throws {
      let store = temporaryStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      var saved = ChatGPTCredentials(clientID: "oaiapp_saved")
      saved.subject = "subject"
      saved.email = "test@example.test"
      try store.save(saved)
      let auth = ChatGPTAuth(session: stubSession())
      let attempt = try await auth.beginSignIn(
        store: store,
        redirectURI: URL(string: "http://127.0.0.1:54321/auth/callback")!)
      #expect(attempt.authorizationURL.query?.contains("oaiapp_saved") == true)
      #expect(attempt.authorizationURL.query?.contains("agent_name_hint") == false)
      #expect(try await auth.signOut(store: store))
      #expect(try store.load()?.clientID == "oaiapp_saved")
      #expect(try store.load()?.subject == "subject")
      let mode =
        try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
      #expect(mode == 0o600)
    }

    @Test func verifiesSignatureAndEveryIdentityBoundary() throws {
      let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
      let numbers = try key.publicKey.getKeyPrimitives()
      let jwks: [String: JSONValue] = [
        "keys": .array([
          .object([
            "kid": .string("test"), "kty": .string("RSA"), "alg": .string("RS256"),
            "n": .string(numbers.modulus.chatGPTBase64URL),
            "e": .string(numbers.publicExponent.chatGPTBase64URL),
          ])
        ])
      ]
      let now = Date()
      let claims: [String: JSONValue] = [
        "iss": .string(ChatGPTAuth.issuer), "sub": .string("user"),
        "aud": .string("oaiapp_test"), "nonce": .string("nonce"),
        "iat": .number(now.timeIntervalSince1970), "exp": .number(now.timeIntervalSince1970 + 3600),
      ]
      func token(_ claims: [String: JSONValue], algorithm: String = "RS256") throws -> String {
        let header = try JSONEncoder().encode(["kid": "test", "alg": algorithm]).chatGPTBase64URL
        let payload = try JSONEncoder().encode(claims).chatGPTBase64URL
        let signed = header + "." + payload
        return signed + "."
          + (try key.signature(for: Data(signed.utf8), padding: .insecurePKCS1v1_5))
          .rawRepresentation
          .chatGPTBase64URL
      }
      let valid = try token(claims)
      #expect(
        try ChatGPTAuth.verifyIdentity(valid, keys: jwks, clientID: "oaiapp_test", nonce: "nonce")[
          "sub"] == .string("user"))
      for (field, value) in [
        "iss": JSONValue.string("https://attacker.test"), "aud": .string("other"),
        "nonce": .string("other"), "exp": .integer(0), "sub": .string(""),
      ] {
        var bad = claims
        bad[field] = value
        #expect(throws: ChatGPTError.self) {
          try ChatGPTAuth.verifyIdentity(
            token(bad), keys: jwks, clientID: "oaiapp_test", nonce: "nonce")
        }
      }
      #expect(throws: ChatGPTError.self) {
        try ChatGPTAuth.verifyIdentity(
          token(claims, algorithm: "none"), keys: jwks, clientID: "oaiapp_test", nonce: "nonce")
      }
      let tampered = String(valid.dropLast(20)) + String(repeating: "A", count: 20)
      #expect(throws: ChatGPTError.self) {
        try ChatGPTAuth.verifyIdentity(
          tampered, keys: jwks, clientID: "oaiapp_test", nonce: "nonce")
      }
    }

    @Test func refreshRotatesTokensOnceForConcurrentRequests() async throws {
      let store = temporaryStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      var credentials = ChatGPTCredentials(clientID: "oaiapp_saved")
      credentials.accessToken = "expired"
      credentials.refreshToken = "old+refresh"
      credentials.expiresAt = .distantPast
      credentials.scopes = ["chatgpt.tokens.use.direct"]
      try store.save(credentials)
      let recorder = URLRequestRecorder()
      let calls = MethodRecorder()
      StubURLProtocol.install(forHost: "auth.openai.com") { request in
        let body = try requestBodyData(request)
        recorder.record(request, body: body)
        calls.record("refresh")
        #expect(String(decoding: body, as: UTF8.self).contains("old%2Brefresh"))
        #expect(String(decoding: body, as: UTF8.self).contains("client_id=oaiapp_saved"))
        return try httpResponse(
          request, contentType: "application/json",
          body:
            #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"scope":"chatgpt.tokens.use.direct"}"#
        )
      }
      defer { StubURLProtocol.reset(host: "auth.openai.com") }
      let auth = ChatGPTAuth(session: stubSession())
      async let first = auth.accessToken(store: store)
      async let second = auth.accessToken(store: store)
      let tokens = try await [first, second]
      #expect(tokens == ["new-access", "new-access"])
      #expect(try store.load()?.refreshToken == "new-refresh")
      #expect(calls.methods.count == 1)
    }

    @Test func requestReplaysToolsAndOmitsUnsupportedBillingRouteFields() throws {
      let tool = ToolDefinition(
        name: "files::read", description: "Read", inputSchema: objectSchema(required: ["path"]))
      let request = ProviderRequest(
        model: "model",
        messages: [
          .system("Instructions"), .user("Read"),
          .init(
            role: .assistant,
            content: [
              .toolCall(
                .init(id: "call-1", name: tool.name, arguments: .object(["path": .string("a")])))
            ]),
          .init(role: .tool, content: [.toolResult(.init(callID: "call-1", text: "File content"))]),
        ], tools: [tool],
        options: .init(
          temperature: 0.5, maxOutputTokens: 10,
          additional: ["previous_response_id": .string("old"), "temperature": .integer(1)]),
        stream: false)
      let body = try ChatGPTProvider.body(request, resolver: .init(tools: request.tools))
        .objectValue!
      #expect(body["store"] == .bool(false))
      #expect(body["stream"] == .bool(true))
      #expect(body["temperature"] == nil)
      #expect(body["max_output_tokens"] == nil)
      #expect(body["previous_response_id"] == nil)
      #expect(body["input"]?.arrayValue?.first?["role"] == .string("developer"))
      #expect(
        body["input"]?.arrayValue?.contains(where: { $0["type"] == .string("function_call_output") }
        )
          == true)
      #expect(body["tools"]?.arrayValue?.first?["type"] == .string("namespace"))
    }

    @Test func requestReplaysImageHistoryWithAssistantOutputText() throws {
      let image = ImageContent(source: .data(Data([1, 2, 3])), mimeType: "image/png")
      let request = ProviderRequest(
        model: "gpt-5.6-luna",
        messages: [
          .system("Describe pictures"),
          .init(role: .user, content: [.text("What is this?"), .image(image)]),
          .init(
            role: .assistant,
            content: [
              .text("A red square"),
              .file(
                .init(name: "description.txt", mimeType: "text/plain", text: "Image description")),
              .resource(.init(uri: "resource:description", text: "Resource description")),
            ]),
          .user("What color was it?"),
        ])
      let body = try ChatGPTProvider.body(request, resolver: .init(tools: []))
      let input = try #require(body["input"]?.arrayValue)
      #expect(input.map { $0["role"]?.stringValue } == ["developer", "user", "assistant", "user"])
      #expect(input[0]["content"]?.arrayValue?.first?["type"] == .string("input_text"))
      #expect(
        input[1]["content"]?.arrayValue == [
          .object(["type": .string("input_text"), "text": .string("What is this?")]),
          .object([
            "type": .string("input_image"), "image_url": .string("data:image/png;base64,AQID"),
          ]),
        ])
      let assistantContent = try #require(input[2]["content"]?.arrayValue)
      #expect(
        assistantContent.map { $0["type"]?.stringValue } == [
          "output_text", "output_text", "output_text",
        ])
      #expect(
        assistantContent.map { $0["text"]?.stringValue } == [
          "A red square", "Image description", "Resource description",
        ])
      #expect(input[3]["content"]?.arrayValue?.first?["type"] == .string("input_text"))
    }

    @Test func streamRequiresCompletedAndPreservesToolsAndUsage() async throws {
      let tool = ToolDefinition(
        name: "files::read", description: "Read", inputSchema: objectSchema(required: []))
      var parser = ChatGPTResponseStream(resolver: .init(tools: [tool]))
      let events = ChatGPTEventRecorder()
      _ = try await parser.feed(#"{"type":"response.output_text.delta","delta":"Hello"}"#) {
        await events.append($0)
      }
      let response = try await parser.feed(
        #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","call_id":"c1","name":"files_read","arguments":"{}"}],"usage":{"input_tokens":4,"output_tokens":2,"input_tokens_details":{"cached_tokens":1}}}}"#
      ) { await events.append($0) }
      #expect(response?.message.toolCalls.first?.name == "files::read")
      #expect(response?.stopReason == .toolCall)
      #expect(response?.usage?.cachedTokens == 1)
      await #expect(throws: ChatGPTError.self) {
        try await parser.feed(
          #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#
        ) { _ in }
      }
      await #expect(throws: ChatGPTError.self) {
        try await parser.feed(#"{"type":"response.incomplete"}"#) { _ in }
      }
    }

    @Test func cyberPolicyPreservesHTTPAndStreamingDiagnostics() async throws {
      let payload =
        #"{"code":"cyber_policy","message":"Flagged for possible cybersecurity risk.","param":"input"}"#
      let url = try #require(URL(string: "https://api.openai.com/v1/responses"))
      let response = try #require(
        HTTPURLResponse(
          url: url, statusCode: 403, httpVersion: nil, headerFields: ["x-request-id": "req-http"]))
      let expected = ProviderPolicyError(
        code: "cyber_policy", message: "Flagged for possible cybersecurity risk.",
        statusCode: 403, requestID: "req-http", parameter: "input")
      #expect(throws: expected) {
        try ChatGPTProvider.validate(response, data: Data("{\"error\":\(payload)}".utf8))
      }
      for event in [
        "{\"type\":\"error\",\"error\":\(payload)}",
        "{\"type\":\"response.failed\",\"response\":{\"error\":\(payload)}}",
        #"{"type":"error","code":"cyber_policy"}"#,
      ] {
        var parser = ChatGPTResponseStream(
          resolver: .init(tools: []), requestID: "req-stream", statusCode: 200)
        _ = try await parser.feed(#"{"type":"response.output_text.delta","delta":"Partial"}"#) {
          _ in
        }
        do {
          _ = try await parser.feed(event) { _ in }
          Issue.record("Expected a policy rejection")
        } catch let error as ProviderPolicyError {
          #expect(error.code == "cyber_policy")
          #expect(error.requestID == "req-stream")
          #expect(error.statusCode == 200)
          #expect(error.localizedDescription.contains("code: cyber_policy"))
        }
      }
      let ordinary = ChatGPTProvider.failure(
        .object([
          "code": .string("server_error"), "message": .string("Details mention cyber_policy"),
        ]))
      #expect(ordinary is ChatGPTError)
      #expect(!(ordinary is ProviderPolicyError))
    }

    @Test func callbackRejectsWrongStateAndCanBeCancelled() async throws {
      let listener = try ChatGPTCallbackListener()
      #expect(listener.redirectURI.host == "127.0.0.1")
      let waiting = Task { try await listener.callback(state: "expected", timeout: 3) }
      let invalid = URL(string: listener.redirectURI.absoluteString + "?state=wrong&code=no")!
      let (_, response) = try await URLSession.shared.data(from: invalid)
      #expect((response as? HTTPURLResponse)?.statusCode == 400)
      listener.cancel()
      await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func callbackCompletesOnlyForThePendingAttempt() async throws {
      let listener = try ChatGPTCallbackListener()
      let waiting = Task { try await listener.callback(state: "expected", timeout: 3) }
      let valid = URL(
        string: listener.redirectURI.absoluteString
          + "?state=expected&code=code&client_id=oaiapp_test")!
      let (_, response) = try await URLSession.shared.data(from: valid)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      #expect(try await waiting.value == valid)
    }

    @Test func signInValidatesIdentityAndGrantBeforeSavingTokens() async throws {
      let store = temporaryStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      let auth = ChatGPTAuth(session: stubSession())
      let attempt = try await auth.beginSignIn(
        store: store,
        redirectURI: URL(string: "http://127.0.0.1:54321/auth/callback")!)
      let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
      let numbers = try key.publicKey.getKeyPrimitives()
      let claims: [String: JSONValue] = [
        "iss": .string(ChatGPTAuth.issuer), "sub": .string("user"),
        "aud": .string("oaiapp_test"), "nonce": .string(attempt.nonce),
        "email": .string("user@example.test"),
        "iat": .number(Date().timeIntervalSince1970),
        "exp": .number(Date().timeIntervalSince1970 + 3600),
      ]
      let signed =
        try JSONEncoder().encode(["kid": "test", "alg": "RS256"]).chatGPTBase64URL
        + "." + JSONEncoder().encode(claims).chatGPTBase64URL
      let token =
        signed + "."
        + (try key.signature(for: Data(signed.utf8), padding: .insecurePKCS1v1_5)).rawRepresentation
        .chatGPTBase64URL
      StubURLProtocol.install(forHost: "auth.openai.com") { request in
        let body: JSONValue
        if request.url?.path == "/.well-known/jwks.json" {
          body = .object([
            "keys": .array([
              .object([
                "kid": .string("test"), "kty": .string("RSA"),
                "n": .string(numbers.modulus.chatGPTBase64URL),
                "e": .string(numbers.publicExponent.chatGPTBase64URL),
              ])
            ])
          ])
        } else {
          let sent = String(decoding: try requestBodyData(request), as: UTF8.self)
          #expect(sent.contains("client_id=oaiapp_test"))
          #expect(sent.contains("code_verifier="))
          #expect(sent.contains("resource="))
          body = .object([
            "id_token": .string(token), "access_token": .string("access"),
            "refresh_token": .string("refresh"), "token_type": .string("Bearer"),
            "expires_in": .integer(3600), "scope": .string(ChatGPTAuth.scopes),
          ])
        }
        return try httpResponse(
          request, contentType: "application/json", body: body.compactJSONString)
      }
      defer { StubURLProtocol.reset(host: "auth.openai.com") }
      let callback = URL(
        string: attempt.redirectURI.absoluteString
          + "?state=\(attempt.state)&code=code&client_id=oaiapp_test")!
      let account = try await auth.finishSignIn(attempt, callback: callback, store: store)
      #expect(account.isSignedIn)
      #expect(account.subject == "user")
      #expect(try store.load()?.idToken == token)
      await #expect(throws: ChatGPTError.self) {
        try await auth.finishSignIn(attempt, callback: callback, store: store)
      }
    }

    @Test(arguments: ["\n\n", "\n\ndata: [DONE]\n\n"])
    func providerUsesSubscriptionTokenAndRejectsTruncatedStreams(ending: String) async throws {
      let store = try signedInStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      let recorder = URLRequestRecorder()
      StubURLProtocol.install(forHost: "api.openai.com") { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-token")
        if request.url?.path == "/v1/models" {
          return try httpResponse(
            request, contentType: "application/json",
            body:
              #"{"models":[{"slug":"available","display_name":"Available","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}"#
          )
        }
        #expect(request.url?.path == "/v1/responses")
        recorder.record(request, body: try requestBodyData(request))
        return try httpResponse(
          request, contentType: "text/event-stream",
          body:
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}" + ending)
      }
      defer { StubURLProtocol.reset(host: "api.openai.com") }
      let provider = ChatGPTProvider(
        id: "chatgpt", store: store, auth: ChatGPTAuth(session: stubSession()),
        session: stubSession()
      )
      #expect(try await provider.availableModels().map(\.id) == ["available"])
      await #expect(throws: ChatGPTError.self) {
        try await provider.complete(
          .init(model: "available", messages: [.user("Hi")], stream: false))
      }
      let body = try jsonObject(try #require(recorder.body))
      #expect(body["store"] as? Bool == false)
      #expect(body["stream"] as? Bool == true)
    }

    @Test(arguments: ["\n", "\r\n", "\r"], [true, false])
    func providerConsumesSeparateResponseEvents(newline: String, stream: Bool) async throws {
      let store = try signedInStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      StubURLProtocol.install(forHost: "api.openai.com") { request in
        try httpResponse(
          request, contentType: "text/event-stream; charset=utf-8",
          body: [
            ": keepalive", "",
            "event: response.created",
            #"data: {"type":"response.created","response":{"status":"in_progress"}}"#, "",
            "event: response.output_text.delta",
            #"data: {"type":"response.output_text.delta","delta":"Hello 👋"}"#, "",
            "event: response.completed",
            #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello 👋"}]}],"usage":{"input_tokens":4,"output_tokens":2}}}"#,
            "", "data: [DONE]", "", "",
          ].joined(separator: newline))
      }
      defer { StubURLProtocol.reset(host: "api.openai.com") }
      let provider = ChatGPTProvider(
        id: "chatgpt", store: store, auth: ChatGPTAuth(session: stubSession()),
        session: stubSession())
      let events = ChatGPTEventRecorder()
      let response = try await provider.complete(
        .init(model: "gpt-5.6-luna", messages: [.user("Hi")], stream: stream)
      ) { await events.append($0) }
      #expect(response.message.text == "Hello 👋")
      #expect(response.usage?.inputTokens == 4)
      #expect(response.stopReason == .stop)
      let received = await events.events
      let text = received.compactMap { event -> String? in
        if case .textDelta(let text) = event { return text }
        return nil
      }.joined()
      #expect(text == (stream ? "Hello 👋" : ""))
      #expect(
        received.contains {
          if case .usage = $0 { return true }
          return false
        })
    }

    @Test(arguments: [
      (200, nil, #"{"detail":"Direct routing is unavailable"}"#, "Direct routing is unavailable"),
      (200, nil, "<html>Bad gateway</html>", "no response events"),
      (200, nil, "", "no response events"),
      (
        200, nil,
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n",
        "stream ended before response.completed"
      ),
      (
        200, nil,
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"App limit reached\"}}}\n\n",
        "App limit reached"
      ),
      (
        403, "application/json", #"{"detail":"Region is not supported"}"#, "Region is not supported"
      ),
      (
        401, "application/json", #"{"detail":"Direct permission was not accepted"}"#,
        "Direct permission"
      ),
      (
        400, "application/json",
        #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools","message":"Unsupported tool"}}"#,
        "parameter: tools"
      ),
      (
        429, "application/json",
        #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"App limit reached"}}"#,
        "https://chatgpt.com/settings/usage"
      ),
      (
        503, "application/json", #"{"error":{"code":"subscription_sharing_usage_unavailable"}}"#,
        "Try again later"
      ),
      (502, "text/html", "<html>Bad gateway</html>", "HTTP 502"),
      (200, "application/json", #"{"output":[]}"#, "expected text/event-stream"),
      (200, "text/event-stream", "data: not-json\n\n", "malformed JSON"),
      (200, "text/event-stream", "data: {}\n\n", "missing type"),
      (
        200, "text/event-stream",
        "data: {\"type\":\"response.created\"}\n\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"App limit reached\"}}}\n\n",
        "App limit reached"
      ),
      (
        200, "text/event-stream",
        "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n",
        "max_output_tokens"
      ),
    ])
    func providerReportsActionableErrors(
      status: Int, contentType: String?, body: String, expected: String
    ) async throws {
      let store = try signedInStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      StubURLProtocol.install(forHost: "api.openai.com") { request in
        try httpResponse(
          request, status: status, contentType: contentType, body: body,
          headers: ["x-request-id": "req-test"])
      }
      defer { StubURLProtocol.reset(host: "api.openai.com") }
      let provider = ChatGPTProvider(id: "chatgpt", store: store, session: stubSession())
      do {
        _ = try await provider.complete(.init(model: "model", messages: [.user("Hi")]))
        Issue.record("Expected request to fail")
      } catch let error as ChatGPTError {
        #expect(error.localizedDescription.contains(expected))
        #expect(error.localizedDescription.contains("req-test"))
        if status != 200 { #expect(error.localizedDescription.contains("HTTP \(status)")) }
      }
      #expect(try store.load()?.isSignedIn == true)
    }

    @Test(arguments: [true, false])
    func providerAcceptsCompletedStreamWithoutContentType(stream: Bool) async throws {
      let store = try signedInStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      StubURLProtocol.install(forHost: "api.openai.com") { request in
        try httpResponse(
          request, contentType: nil,
          body: "\u{FEFF}: keepalive\r\n\r\n"
            + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 👋\"}\r\n\r\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello 👋\"}]}]}}"
        )
      }
      defer { StubURLProtocol.reset(host: "api.openai.com") }
      let provider = ChatGPTProvider(id: "chatgpt", store: store, session: stubSession())
      let events = ChatGPTEventRecorder()
      let response = try await provider.complete(
        .init(model: "gpt-5.6-luna", messages: [.user("Hi")], stream: stream)
      ) { await events.append($0) }
      #expect(response.message.text == "Hello 👋")
      #expect(response.stopReason == .stop)
      #expect(await events.events == (stream ? [.textDelta("Hello 👋")] : []))
    }

    @Test(arguments: [true, false])
    func providerStreamsAndReplaysToolReasoning(emptyTerminalOutput: Bool) async throws {
      let store = try signedInStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      let tool = ToolDefinition(
        name: "files::read", description: "Read", inputSchema: objectSchema(required: ["path"]))
      let output =
        #"[{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[{"type":"summary_text","text":"Read file"}]},{"type":"function_call","id":"fc_1","call_id":"call_1","namespace":"pmai","name":"files_read","arguments":"{\"path\":\"a\"}"}]"#
      let items = try #require(
        JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)).arrayValue)
      let recorder = URLRequestRecorder()
      StubURLProtocol.install(forHost: "api.openai.com") { request in
        recorder.record(request, body: try requestBodyData(request))
        return try httpResponse(
          request, contentType: emptyTerminalOutput ? nil : "text/event-stream",
          body: [
            #"{"type":"response.created"}"#,
            #"{"type":"response.reasoning_summary_text.delta","delta":"Read file"}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_1","namespace":"pmai","name":"files_read"}}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"path\":"}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"\"a\"}"}"#,
            "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":\(items[0].compactJSONString)}",
            "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":\(items[1].compactJSONString)}",
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":\(emptyTerminalOutput ? "[]" : output)}}",
          ].map { "data: " + $0 + "\n\n" }.joined())
      }
      defer { StubURLProtocol.reset(host: "api.openai.com") }
      let provider = ChatGPTProvider(id: "chatgpt", store: store, session: stubSession())
      let events = ChatGPTEventRecorder()
      let response = try await provider.complete(
        .init(model: "model", messages: [.user("Read a")], tools: [tool])
      ) { await events.append($0) }
      #expect(response.stopReason == .toolCall)
      #expect(response.message.reasoning == "Read file")
      #expect(response.message.toolCalls.first?.name == "files::read")
      #expect(response.message.toolCalls.first?.arguments == .object(["path": .string("a")]))
      #expect(response.message.toolCalls.count == 1)
      let received = await events.events
      #expect(received.contains(.reasoningDelta("Read file")))
      let arguments = received.compactMap { event -> String? in
        if case .toolCallDelta(let delta) = event { return delta.argumentsFragment }
        return nil
      }.joined()
      #expect(arguments == #"{"path":"a"}"#)

      // iOS reconstructs messages without providerState. The call-ID cache
      // must still supply encrypted reasoning before the next tool turn.
      var reconstructed = response.message
      reconstructed.providerState = nil
      let result = AgentMessage(
        role: .tool, content: [.toolResult(.init(callID: "call_1", text: "File content"))])
      _ = try await provider.complete(
        .init(model: "model", messages: [.user("Read a"), reconstructed, result], tools: [tool]))
      let replay = try JSONDecoder().decode(JSONValue.self, from: #require(recorder.body))
      let input = try #require(replay["input"]?.arrayValue)
      #expect(
        input.map { $0["type"]?.stringValue } == [
          "message", "reasoning", "function_call", "function_call_output",
        ])
      #expect(input[1]["encrypted_content"] == .string("opaque"))
      #expect(input[2]["call_id"] == input[3]["call_id"])
      #expect(input[2]["namespace"] == .string("pmai"))
    }

    @Test func streamKeepsCommentaryAndCompletedCallsInOutputOrder() async throws {
      let tool = ToolDefinition(
        name: "files_read", description: "Read", inputSchema: objectSchema(required: []))
      var parser = ChatGPTResponseStream(resolver: .init(tools: [tool]))
      let events = ChatGPTEventRecorder()
      for event in [
        #"{"type":"response.output_text.delta","delta":"I will read the files."}"#,
        #"{"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","call_id":"second","name":"files_read","arguments":"{}"}}"#,
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","channel":"commentary","content":[{"type":"output_text","text":"I will read the files."}]}}"#,
        #"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","call_id":"first","name":"files_read","arguments":"{}"}}"#,
      ] {
        #expect(try await parser.feed(event) { await events.append($0) } == nil)
      }
      let response = try #require(
        try await parser.feed(
          #"{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":100,"output_tokens":20}}}"#
        ) { await events.append($0) })
      #expect(response.stopReason == .toolCall)
      #expect(response.message.text == "I will read the files.")
      #expect(response.message.toolCalls.map(\.id) == ["first", "second"])
      #expect(response.usage?.totalTokens == 120)
    }

    @Test func providerRejectsCompletedItemWithoutCompletedResponse() async throws {
      let store = try signedInStore()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      StubURLProtocol.install(forHost: "api.openai.com") { request in
        try httpResponse(
          request, contentType: nil,
          body:
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call\",\"name\":\"files_read\",\"arguments\":\"{}\"}}\n\n"
        )
      }
      defer { StubURLProtocol.reset(host: "api.openai.com") }
      let provider = ChatGPTProvider(id: "chatgpt", store: store, session: stubSession())
      await #expect(throws: ChatGPTError.self) {
        try await provider.complete(.init(model: "gpt-6.1-sol", messages: [.user("Read a file")]))
      }
    }

    @Test func streamEmitsRefusalsWithoutDuplicatingFinalText() async throws {
      var parser = ChatGPTResponseStream(resolver: .init(tools: []))
      let events = ChatGPTEventRecorder()
      _ = try await parser.feed(
        #"{"type":"response.refusal.delta","delta":"I cannot help with that."}"#
      ) { await events.append($0) }
      let response = try await parser.feed(
        #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"I cannot help with that."}]}]}}"#
      ) { await events.append($0) }
      #expect(response?.message.text == "I cannot help with that.")
      #expect(await events.events == [.textDelta("I cannot help with that.")])
    }
  }

  private actor ChatGPTEventRecorder {
    var events: [ProviderEvent] = []
    func append(_ event: ProviderEvent) { events.append(event) }
  }
#endif
