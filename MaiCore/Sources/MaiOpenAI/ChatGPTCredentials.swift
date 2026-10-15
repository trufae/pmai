import Crypto
import Foundation
import MaiCore

#if canImport(Security)
  import Security
#endif
#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// A registration belongs to one provider/account. Tokens never enter MaiConfiguration.
public struct ChatGPTCredentials: Codable, Sendable {
  public var clientID: String
  public var subject: String?
  public var email: String?
  public var accessToken: String?
  public var refreshToken: String?
  public var idToken: String?
  public var expiresAt: Date?
  public var scopes: [String]

  public init(clientID: String) {
    self.clientID = clientID
    scopes = []
  }

  public var isSignedIn: Bool { accessToken != nil && scopes.contains("chatgpt.tokens.use.direct") }
  public var label: String { "\(email ?? subject ?? "ChatGPT") · \(clientID)" }
}

/// iOS uses device-local Keychain items. CLI files are atomic and owner-only.
public struct ChatGPTCredentialStore: Sendable {
  public let directory: URL
  public let providerID: String
  var key: String {
    Data(SHA256.hash(data: Data(providerID.utf8))).map { String(format: "%02x", $0) }.joined()
  }
  var file: URL { directory.appendingPathComponent(key + ".json") }
  var identity: String { directory.path + "/" + key }

  public init(
    providerID: String, directory: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.providerID = providerID
    self.directory =
      directory
      ?? URL(
        fileURLWithPath:
          AgentHome.expandUserPath(environment["PMAI_HOME"] ?? "~/.pmai", environment: environment)
      )
      .appendingPathComponent("chatgpt", isDirectory: true)
  }

  public func load() throws -> ChatGPTCredentials? {
    guard let data = try read(key) else { return nil }
    return try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
  }

  func save(_ credentials: ChatGPTCredentials) throws {
    try write(JSONEncoder().encode(credentials), name: key)
  }

  func hostID() throws -> String {
    if let data = try read("host"), let value = String(data: data, encoding: .utf8) { return value }
    let value = "urn:uuid:" + UUID().uuidString.lowercased()
    try write(Data(value.utf8), name: "host")
    return value
  }

  private func read(_ name: String) throws -> Data? {
    #if os(iOS)
      var query = keychainQuery(name)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = result as? Data else {
        throw ChatGPTError.credentialsUnavailable
      }
      return data
    #else
      let url = directory.appendingPathComponent(name + ".json")
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try Data(contentsOf: url)
    #endif
  }

  private func write(_ data: Data, name: String) throws {
    #if os(iOS)
      let query = keychainQuery(name)
      let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
      if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
          throw ChatGPTError.credentialsUnavailable
        }
      } else if status != errSecSuccess {
        throw ChatGPTError.credentialsUnavailable
      }
    #elseif os(Windows)
      throw ChatGPTError.message("ChatGPT credential storage requires a POSIX host or iOS.")
    #else
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      // Set the mode on the temporary inode before publishing it, including replacement writes.
      let temporary = directory.appendingPathComponent(".\(UUID().uuidString)")
      guard
        FileManager.default.createFile(
          atPath: temporary.path, contents: data,
          attributes: [.posixPermissions: 0o600])
      else { throw ChatGPTError.credentialsUnavailable }
      defer { try? FileManager.default.removeItem(at: temporary) }
      guard rename(temporary.path, directory.appendingPathComponent(name + ".json").path) == 0
      else {
        throw ChatGPTError.credentialsUnavailable
      }
    #endif
  }

  #if os(iOS)
    private func keychainQuery(_ name: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.trufae.mai.chatgpt",
        kSecAttrAccount as String: name,
      ]
    }
  #endif

  /// Prevent separate REPLs from racing rotating refresh tokens.
  func lock() async throws -> ChatGPTCredentialLock {
    #if os(iOS)
      return ChatGPTCredentialLock()
    #elseif os(Windows)
      throw ChatGPTError.message("ChatGPT credential locking requires a POSIX host or iOS.")
    #else
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let descriptor = open(
        directory.appendingPathComponent("credentials.lock").path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw ChatGPTError.credentialsUnavailable }
      let lock = ChatGPTCredentialLock(descriptor: descriptor)
      let deadline = Date().addingTimeInterval(60)
      while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        try Task.checkCancellation()
        guard Date() < deadline else { throw ChatGPTError.credentialsUnavailable }
        try await Task.sleep(for: .milliseconds(100))
      }
      return lock
    #endif
  }
}

final class ChatGPTCredentialLock: @unchecked Sendable {
  #if os(iOS) || os(Windows)
    init() {}
  #else
    let descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
  #endif
}

public enum ChatGPTError: LocalizedError {
  case message(String)
  case credentialsUnavailable
  case signInRequired
  public var errorDescription: String? {
    switch self {
    case .message(let message): message
    case .credentialsUnavailable: "ChatGPT credentials could not be read or saved."
    case .signInRequired:
      "Sign in with ChatGPT for this provider first (/provider login ID in the CLI)."
    }
  }
}

extension Data {
  var chatGPTBase64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  init?(chatGPTBase64URL value: String) {
    let raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    self.init(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4))
  }
}
