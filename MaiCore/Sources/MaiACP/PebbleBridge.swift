import Crypto
import Foundation
import MaiCore
import Observation

public enum PebbleChatError: LocalizedError {
  case unavailable
  case message(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable: "PocketMai is unavailable."
    case .message(let message): message
    }
  }
}

/// PocketMai's phone-side protocol. The Pebble app relays requests over phone loopback.
@MainActor @Observable public final class PebbleBridge {
  public static let presetLimit = 8
  public private(set) var enabled: Bool
  public private(set) var listening = false
  public private(set) var error = ""
  public private(set) var pairingCode: String?
  public private(set) var pairing = false
  public var paired: Bool { token != nil }

  private let preferences: UserDefaults
  private var token: String?
  private var pendingToken: String?
  private var pairingExpiry: Date?
  @ObservationIgnored private var server: LoopbackJSONRPCServer?
  @ObservationIgnored private var lifecycle: Task<Void, Never>?
  @ObservationIgnored private var expiryTask: Task<Void, Never>?
  @ObservationIgnored private var turns: [(id: UUID, result: JSONValue)] = []
  @ObservationIgnored private var turnTask: Task<Void, Never>?
  @ObservationIgnored private var resetAfterTurn = false
  @ObservationIgnored private var presets: () -> [UserPrompt] = { [] }
  @ObservationIgnored private var submit: (String, String?) async throws -> String = { _, _ in "" }
  @ObservationIgnored private var newChat: () -> Void = {}

  public init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
    enabled = preferences.bool(forKey: "pebble.enabled")
    token = preferences.string(forKey: "pebble.token")
  }

  public func configure(presets: @escaping () -> [UserPrompt], newChat: @escaping () -> Void,
    submit: @escaping (String, String?) async throws -> String) {
    self.presets = presets
    self.newChat = newChat
    self.submit = submit
    updateListener()
  }

  public func setEnabled(_ value: Bool) {
    enabled = value
    preferences.set(value, forKey: "pebble.enabled")
    if !value { clearPairing() }
    updateListener()
  }

  public func beginPairing() {
    guard enabled, listening, !paired else { return }
    clearPairing()
    pairing = true
    pairingExpiry = Date().addingTimeInterval(120)
    expiryTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(120)) } catch { return }
      self?.clearPairing()
    }
  }

  public func approvePairing() {
    guard enabled, pairingIsCurrent, let pendingToken else { return }
    token = pendingToken
    preferences.set(pendingToken, forKey: "pebble.token")
    clearPairing()
  }

  public func unpair() {
    token = nil
    preferences.removeObject(forKey: "pebble.token")
    clearPairing()
    turns.removeAll()
    if turnTask == nil { newChat() } else { resetAfterTurn = true }
  }

  private var pairingIsCurrent: Bool { pairingExpiry.map { $0 > Date() } ?? false }

  private func clearPairing() {
    expiryTask?.cancel()
    expiryTask = nil
    pairingExpiry = nil
    pendingToken = nil
    pairingCode = nil
    pairing = false
  }

  private func updateListener() {
    guard lifecycle == nil else { return }
    lifecycle = Task { [self] in
      defer { lifecycle = nil }
      while enabled != (server != nil) {
        if let server {
          listening = false
          await server.close()
          self.server = nil
        } else {
          error = ""
          let server = LoopbackJSONRPCServer(port: 21739, path: "/pocketmai/pebble/v1", maxBodyBytes: 8192)
          do {
            _ = try await server.start { [weak self] request in
              try await self?.handle(request)
            }
            self.server = server
            listening = enabled
          } catch {
            await server.close()
            if enabled { self.error = "Could not start Pebble bridge. Turn it off and on to retry." }
            return
          }
        }
      }
    }
  }

  private func handle(_ request: JSONRPCMessage) throws -> JSONRPCMessage? {
    guard let id = request.id else { return nil }
    let result: JSONValue
    if !enabled || !listening {
      result = status("unavailable")
    } else {
      switch request.method {
      case "pair": result = pair()
      case "menu": result = status("unpaired")
      case "secure": result = try secure(request.params?.objectValue ?? [:])
      default: throw JSONRPCError.methodNotFound(request.method ?? "")
      }
    }
    return .response(id: id, result: result)
  }

  private func pair() -> JSONValue {
    guard !paired else { return status("alreadyPaired") }
    guard pairingIsCurrent else { return status("unpaired") }
    guard pendingToken == nil else { return status("pairingBusy") }
    let key = SymmetricKey(size: .bits256).withUnsafeBytes { Self.hex($0) }
    let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
    pendingToken = key
    pairingCode = code
    return .object(["status": .string("approval"), "token": .string(key), "code": .string(code)])
  }

  // A process occupying the loopback port cannot read paired prompts or forge replies.
  private func secure(_ envelope: [String: JSONValue]) throws -> JSONValue {
    let approved = token != nil
    guard let secret = token ?? (pairingIsCurrent ? pendingToken : nil),
      let keyData = Self.unhex(secret), keyData.count == 32,
      let sealed = envelope["data"]?.stringValue.flatMap(Self.unhex), sealed.first == 0,
      let box = try? ChaChaPoly.SealedBox(combined: sealed)
    else { return status("unpaired") }
    let key = SymmetricKey(data: keyData)
    guard let plain = try? ChaChaPoly.open(box, using: key),
      let input = try? JSONDecoder().decode([String: JSONValue].self, from: plain),
      let method = input["method"]?.stringValue
    else { return status("unpaired") }
    let result: JSONValue
    do {
      result = try approved ? command(method, params: input) : status("approval")
    } catch {
      result = .object(["status": .string("failure"), "text": .string(error.localizedDescription)])
    }
    let nonce = try ChaChaPoly.Nonce(data: [UInt8(1)] + (0..<11).map { _ in UInt8.random(in: .min ... .max) })
    let reply = try ChaChaPoly.seal(JSONEncoder().encode(result), using: key, nonce: nonce,
      authenticating: sealed.prefix(12))
    return .object(["data": .string(Self.hex(reply.combined))])
  }

  private func command(_ method: String, params: [String: JSONValue]) throws -> JSONValue {
    switch method {
    case "menu":
      return .object(["status": .string("ready"), "busy": .bool(turnTask != nil), "presets": .array(
        availablePresets.map { .object(["id": .string($0.id.uuidString),
          "name": .string(Self.limited($0.displayName, bytes: 72))]) })])
    case "new":
      guard turnTask == nil else { return status("busy") }
      newChat()
      return status("ready")
    case "turn", "status":
      guard let value = params["turn"]?.stringValue, let id = UUID(uuidString: value) else {
        throw JSONRPCError.invalidParams("Invalid Pebble turn ID")
      }
      if let previous = turns.first(where: { $0.id == id }) { return previous.result }
      guard method == "turn" else { return status("missing") }
      guard turnTask == nil else { return status("busy") }
      let text: String
      let title: String?
      if let presetID = params["preset"]?.stringValue {
        guard let preset = availablePresets.first(where: { $0.id.uuidString == presetID }) else {
          throw JSONRPCError.invalidParams("Prompt changed. Refresh prompts on your watch.")
        }
        text = preset.message(arguments: "")
        title = preset.displayName
      } else {
        text = (params["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 2048 else {
          throw JSONRPCError.invalidParams("Dictation must be between 1 and 2048 bytes")
        }
        title = nil
      }
      if turns.count == 8 { turns.removeFirst() }
      turns.append((id, status("thinking")))
      turnTask = Task {
        defer {
          turnTask = nil
          if resetAfterTurn { newChat(); resetAfterTurn = false }
        }
        let result: JSONValue
        do {
          let reply = try await submit(text, title)
          result = .object(["status": .string("reply"), "text": .string(Self.limited(reply, bytes: 1800))])
        } catch {
          result = .object(["status": .string("error"),
            "text": .string(Self.limited(error.localizedDescription, bytes: 240))])
        }
        if let index = turns.firstIndex(where: { $0.id == id }) { turns[index].result = result }
      }
      return status("thinking")
    default:
      throw JSONRPCError.methodNotFound(method)
    }
  }

  private var availablePresets: [UserPrompt] {
    Array(presets().lazy.filter { !$0.message(arguments: "").isEmpty }.prefix(Self.presetLimit))
  }

  private func status(_ name: String) -> JSONValue { .object(["status": .string(name)]) }

  private static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func unhex(_ string: String) -> Data? {
    var bytes = Data()
    var digits = string.utf8.makeIterator()
    let alphabet = Array("0123456789abcdef".utf8)
    while let high = digits.next() {
      guard let low = digits.next(), let a = alphabet.firstIndex(of: high),
        let b = alphabet.firstIndex(of: low) else { return nil }
      bytes.append(UInt8(a * 16 + b))
    }
    return bytes
  }

  private static func limited(_ text: String, bytes: Int) -> String {
    let text = text.replacingOccurrences(of: "\0", with: "")
    guard text.utf8.count > bytes else { return text }
    let utf8 = text.utf8
    var end = utf8.index(utf8.startIndex, offsetBy: bytes - 3)
    while utf8[end] & 0xC0 == 0x80 { utf8.formIndex(before: &end) }
    return String(decoding: utf8[..<end], as: UTF8.self) + "…"
  }
}
