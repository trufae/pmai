import Crypto
import CryptoExtras
import Foundation
import MaiCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct ChatGPTSignIn: Sendable {
  public let authorizationURL: URL
  public let state: String
  let nonce: String
  let verifier: String
  let redirectURI: URL
  let registration: ChatGPTCredentials?
  let createdAt: Date
  let storeIdentity: String
}

/// The same OAuth implementation serves the CLI browser and iOS authentication session.
public actor ChatGPTAuth {
  public static let shared = ChatGPTAuth()
  static let issuer = "https://auth.openai.com"
  static let resource = "https://api.openai.com/v1"
  static let scopes =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  private let session: URLSession
  private var refreshes: [String: Task<String, Error>] = [:]
  private var pending: Set<String> = []
  private var operations: Set<String> = []

  public init(session: URLSession = .shared) { self.session = session }

  // Actor methods can interleave while awaiting HTTP. In particular, a refresh
  // must not save rotating credentials after another task has signed out.
  private func acquire(_ store: ChatGPTCredentialStore) async throws {
    while operations.contains(store.identity) {
      try await Task.sleep(for: .milliseconds(50))
    }
    try Task.checkCancellation()
    operations.insert(store.identity)
  }

  public func beginSignIn(
    store: ChatGPTCredentialStore, redirectURI: URL,
    useIDTokenHint: Bool = true
  ) async throws -> ChatGPTSignIn {
    try await acquire(store)
    defer { operations.remove(store.identity) }
    guard redirectURI.scheme == "http", redirectURI.host == "127.0.0.1",
      redirectURI.path == "/auth/callback", redirectURI.query == nil, redirectURI.fragment == nil
    else {
      throw ChatGPTError.message(
        "ChatGPT sign-in requires an HTTP callback at 127.0.0.1/auth/callback.")
    }
    let lock = try await store.lock()
    defer { withExtendedLifetime(lock) {} }
    let registration = try store.load()
    let state = Self.random()
    let nonce = Self.random()
    let verifier = Self.random()
    var values = [
      "client_id": registration?.clientID ?? "dynamic_agent_client",
      "ext_agent_host_id": try store.hostID(),
      "response_type": "code", "redirect_uri": redirectURI.absoluteString,
      "scope": Self.scopes, "resource": Self.resource, "state": state, "nonce": nonce,
      "code_challenge_method": "S256",
      "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).chatGPTBase64URL,
    ]
    if registration == nil { values["agent_name_hint"] = "pmai" }
    if useIDTokenHint { values["id_token_hint"] = registration?.idToken }
    values["login_hint"] = registration?.email
    var url = URLComponents(string: Self.issuer + "/api/accounts/authorize")!
    url.queryItems = values.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
    pending.insert(state)
    return ChatGPTSignIn(
      authorizationURL: url.url!, state: state, nonce: nonce, verifier: verifier,
      redirectURI: redirectURI, registration: registration, createdAt: Date(),
      storeIdentity: store.identity)
  }

  public func cancelSignIn(_ attempt: ChatGPTSignIn) { pending.remove(attempt.state) }

  public func finishSignIn(
    _ attempt: ChatGPTSignIn, callback: URL,
    store: ChatGPTCredentialStore
  ) async throws -> ChatGPTCredentials {
    try await acquire(store)
    defer { operations.remove(store.identity) }
    guard pending.remove(attempt.state) != nil, attempt.storeIdentity == store.identity,
      Date().timeIntervalSince(attempt.createdAt) < 600,
      callback.scheme == attempt.redirectURI.scheme, callback.host == attempt.redirectURI.host,
      callback.port == attempt.redirectURI.port, callback.path == attempt.redirectURI.path,
      let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
    else {
      throw ChatGPTError.message("ChatGPT sign-in expired or could not be verified. Try again.")
    }
    let items = components.queryItems ?? []
    guard Set(items.map(\.name)).count == items.count,
      items.first(where: { $0.name == "state" })?.value == attempt.state
    else { throw ChatGPTError.message("ChatGPT sign-in state did not match.") }
    let values = Dictionary(
      uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
    if values["error"] != nil {
      throw ChatGPTError.message(
        "ChatGPT sign-in was declined. Enable plan usage when signing in to continue.")
    }
    guard let code = values["code"], !code.isEmpty else {
      throw ChatGPTError.message("ChatGPT returned no authorization code.")
    }
    let clientID = values["client_id"] ?? attempt.registration?.clientID ?? ""
    guard !clientID.isEmpty, clientID != "dynamic_agent_client",
      attempt.registration == nil || clientID == attempt.registration?.clientID
    else { throw ChatGPTError.message("ChatGPT returned an invalid account registration.") }
    let lock = try await store.lock()
    defer { withExtendedLifetime(lock) {} }
    // Retain an issued registration if code redemption fails, without activating it.
    var credentials = attempt.registration ?? ChatGPTCredentials(clientID: clientID)
    if attempt.registration == nil { try store.save(credentials) }
    let root = try await tokenRequest([
      "grant_type": "authorization_code", "client_id": clientID, "code": code,
      "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI.absoluteString,
      "resource": Self.resource,
    ])
    guard let idToken = root["id_token"]?.stringValue else {
      throw ChatGPTError.message("ChatGPT returned no identity token.")
    }
    let identity = try await verifyIdentity(idToken, clientID: clientID, nonce: attempt.nonce)
    guard credentials.subject == nil || credentials.subject == identity["sub"]?.stringValue else {
      throw ChatGPTError.message(
        "The signed-in ChatGPT account differs from this provider's account. Add another ChatGPT provider to use it."
      )
    }
    credentials.subject = identity["sub"]?.stringValue
    credentials.email = identity["email"]?.stringValue
    credentials.idToken = idToken
    try update(&credentials, from: root, preservingScopes: false)
    try store.save(credentials)
    return credentials
  }

  public func accessToken(store: ChatGPTCredentialStore) async throws -> String {
    if let task = refreshes[store.identity] { return try await task.value }
    let task = Task { try await self.refreshedToken(store: store) }
    refreshes[store.identity] = task
    defer { refreshes[store.identity] = nil }
    return try await task.value
  }

  private func refreshedToken(store: ChatGPTCredentialStore) async throws -> String {
    try await acquire(store)
    defer { operations.remove(store.identity) }
    let lock = try await store.lock()
    defer { withExtendedLifetime(lock) {} }
    guard var credentials = try store.load(), credentials.isSignedIn else {
      throw ChatGPTError.signInRequired
    }
    if let token = credentials.accessToken,
      (credentials.expiresAt ?? .distantPast).timeIntervalSinceNow > 60
    {
      return token
    }
    guard let refresh = credentials.refreshToken else { throw ChatGPTError.signInRequired }
    let root = try await tokenRequest([
      "grant_type": "refresh_token", "client_id": credentials.clientID,
      "refresh_token": refresh, "resource": Self.resource,
    ])
    try update(&credentials, from: root, preservingScopes: true)
    // A refresh may return a new ID token. Retain the validated original hint instead
    // of trusting unverified replacement identity claims from a refresh response.
    try store.save(credentials)
    return credentials.accessToken!
  }

  /// Returns false if remote revocation could not be confirmed. Local tokens are always cleared.
  public func signOut(store: ChatGPTCredentialStore) async throws -> Bool {
    if let refresh = refreshes[store.identity] { _ = try? await refresh.value }
    try await acquire(store)
    defer { operations.remove(store.identity) }
    let lock = try await store.lock()
    defer { withExtendedLifetime(lock) {} }
    guard var credentials = try store.load() else { return true }
    var revoked = credentials.refreshToken == nil
    if let token = credentials.refreshToken {
      do {
        let discovery = try await json(
          URL(string: Self.issuer + "/.well-known/openid-configuration")!)
        guard let raw = discovery["revocation_endpoint"]?.stringValue,
          let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com"
        else { throw ChatGPTError.message("Invalid ChatGPT revocation endpoint.") }
        for attempt in 0..<3 {
          do {
            let (data, response) = try await sendForm(
              url,
              values: [
                "token": token, "token_type_hint": "refresh_token",
                "client_id": credentials.clientID,
              ])
            _ = data
            revoked = (response as? HTTPURLResponse)?.statusCode == 200
            if revoked || ((response as? HTTPURLResponse)?.statusCode ?? 500) < 500 { break }
          } catch { if attempt == 2 { break } }
          try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
        }
      } catch { revoked = false }
    }
    credentials.accessToken = nil
    credentials.refreshToken = nil
    credentials.idToken = nil
    credentials.expiresAt = nil
    credentials.scopes = []
    try store.save(credentials)
    return revoked
  }

  private func update(
    _ credentials: inout ChatGPTCredentials, from root: [String: JSONValue], preservingScopes: Bool
  ) throws {
    guard let access = root["access_token"]?.stringValue, !access.isEmpty,
      root["token_type"]?.stringValue?.lowercased() == "bearer",
      let seconds = root["expires_in"]?.numberValue, seconds.isFinite, seconds > 0
    else {
      throw ChatGPTError.message("ChatGPT returned an incomplete token grant. Sign in again.")
    }
    let scope =
      root["scope"]?.stringValue
      ?? (preservingScopes ? credentials.scopes.joined(separator: " ") : "")
    let scopes = scope.split(separator: " ").map(String.init)
    guard scopes.contains("chatgpt.tokens.use.direct") else {
      throw ChatGPTError.message(
        "ChatGPT plan usage was not authorized. Sign in again and enable plan usage.")
    }
    credentials.accessToken = access
    credentials.refreshToken = root["refresh_token"]?.stringValue ?? credentials.refreshToken
    credentials.expiresAt = Date().addingTimeInterval(seconds)
    credentials.scopes = scopes
  }

  private func tokenRequest(_ values: [String: String]) async throws -> [String: JSONValue] {
    let (data, response) = try await sendForm(
      URL(string: Self.issuer + "/api/accounts/oauth/token")!, values: values)
    guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
    else {
      // Do not echo an identity provider's response or authorization URLs, which may contain secrets.
      throw ChatGPTError.message(
        "ChatGPT authorization could not be renewed or completed. Sign in again.")
    }
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
  }

  private func sendForm(_ url: URL, values: [String: String]) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var form = URLComponents()
    form.queryItems = values.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
    request.httpBody = Data(
      (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    return try await session.data(
      for: request, delegate: ProviderRedirectDelegate(originalRequest: request))
  }

  private func json(_ url: URL) async throws -> [String: JSONValue] {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    let (data, response) = try await session.data(
      for: request, delegate: ProviderRedirectDelegate(originalRequest: request))
    guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
    else {
      throw ChatGPTError.message(
        "ChatGPT identity verification is unavailable. Try signing in again.")
    }
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
  }

  private func verifyIdentity(_ token: String, clientID: String, nonce: String) async throws
    -> [String: JSONValue]
  {
    let keys = try await json(URL(string: Self.issuer + "/.well-known/jwks.json")!)
    return try Self.verifyIdentity(token, keys: keys, clientID: clientID, nonce: nonce)
  }

  static func verifyIdentity(
    _ token: String, keys: [String: JSONValue], clientID: String,
    nonce: String, now: Date = Date()
  ) throws -> [String: JSONValue] {
    func invalid() -> ChatGPTError {
      .message("ChatGPT identity could not be verified. Try signing in again.")
    }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, let headerData = Data(chatGPTBase64URL: parts[0]),
      let bodyData = Data(chatGPTBase64URL: parts[1]),
      let signature = Data(chatGPTBase64URL: parts[2]),
      let header = try? JSONDecoder().decode([String: JSONValue].self, from: headerData),
      header["alg"]?.stringValue == "RS256", let kid = header["kid"]?.stringValue,
      let jwk = keys["keys"]?.arrayValue?.compactMap(\.objectValue).first(where: {
        $0["kid"]?.stringValue == kid && $0["kty"]?.stringValue == "RSA"
          && ($0["use"] == nil || $0["use"]?.stringValue == "sig")
          && ($0["alg"] == nil || $0["alg"]?.stringValue == "RS256")
      }), let n = jwk["n"]?.stringValue.flatMap({ Data(chatGPTBase64URL: $0) }),
      let e = jwk["e"]?.stringValue.flatMap({ Data(chatGPTBase64URL: $0) }),
      let key = try? _RSA.Signing.PublicKey(n: n, e: e),
      key.isValidSignature(
        .init(rawRepresentation: signature), for: Data((parts[0] + "." + parts[1]).utf8),
        padding: .insecurePKCS1v1_5),
      let claims = try? JSONDecoder().decode([String: JSONValue].self, from: bodyData),
      claims["iss"]?.stringValue == issuer,
      claims["aud"]?.stringValue == clientID
        || claims["aud"]?.arrayValue?.contains(.string(clientID)) == true,
      let expiry = claims["exp"]?.numberValue, expiry > now.timeIntervalSince1970 - 5,
      let issued = claims["iat"]?.numberValue, issued <= now.timeIntervalSince1970 + 5,
      claims["nonce"]?.stringValue == nonce, let subject = claims["sub"]?.stringValue,
      !subject.isEmpty
    else { throw invalid() }
    if let notBefore = claims["nbf"]?.numberValue, notBefore > now.timeIntervalSince1970 + 5 {
      throw invalid()
    }
    if let audience = claims["aud"]?.arrayValue, audience.count > 1,
      claims["azp"]?.stringValue != clientID
    {
      throw invalid()
    }
    return claims
  }

  private static func random() -> String {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }).chatGPTBase64URL
  }
}
