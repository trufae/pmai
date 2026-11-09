import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MaiACP
import MaiCore
import Testing

@Test("Pebble requires pairing approval and submits retried turns once", .timeLimit(.minutes(1)))
@MainActor func pebblePairingAndTurnRetry() async throws {
  let suite = UUID().uuidString
  let preferences = try #require(UserDefaults(suiteName: suite))
  let bridge = PebbleBridge(preferences: preferences)
  let preset = UserPrompt(name: "Summarize", text: "Give a short summary.")
  var submitted: [String] = []
  bridge.configure(presets: { [preset] }, newChat: {}) { text, _ in
    submitted.append(text)
    return "Réponse courte"
  }
  bridge.setEnabled(true)
  defer {
    bridge.setEnabled(false)
    preferences.removePersistentDomain(forName: suite)
  }
  let deadline = ContinuousClock.now + .seconds(5)
  while !bridge.listening && bridge.error.isEmpty && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(bridge.listening)

  func send(_ method: String, params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:21739/pocketmai/pebble/v1")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 3
    request.httpBody = try JSONEncoder().encode(JSONRPCMessage.request(id: 1, method: method, params: .object(params)))
    let (data, _) = try await URLSession.shared.data(for: request)
    let response = try JSONDecoder().decode(JSONRPCMessage.self, from: data)
    return try #require(response.result?.objectValue)
  }

  func dataFromHex(_ hex: String) throws -> Data {
    let digits = Array(hex)
    try #require(digits.count.isMultiple(of: 2))
    return try Data(stride(from: 0, to: digits.count, by: 2).map { index in
      try #require(UInt8(String(digits[index...index + 1]), radix: 16))
    })
  }

  #expect(try await send("pair")["status"] == .string("unpaired"))
  bridge.beginPairing()
  let pairing = try await send("pair")
  let token = try #require(pairing["token"]?.stringValue)
  #expect(pairing["code"]?.stringValue == bridge.pairingCode)
  let key = SymmetricKey(data: try dataFromHex(token))
  var counter: UInt8 = 0
  func secure(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
    counter += 1
    let nonce = Data(Array(repeating: UInt8(0), count: 11) + [counter])
    let input = try JSONEncoder().encode(params.merging(["method": .string(method)]) { _, method in method })
    let sealed = try ChaChaPoly.seal(input, using: key, nonce: ChaChaPoly.Nonce(data: nonce))
    let response = try await send("secure", params: ["data": .string(sealed.combined.map { String(format: "%02x", $0) }.joined())])
    guard let hex = response["data"]?.stringValue else { return response }
    let box = try ChaChaPoly.SealedBox(combined: dataFromHex(hex))
    return try JSONDecoder().decode([String: JSONValue].self,
      from: ChaChaPoly.open(box, using: key, authenticating: nonce))
  }

  let turn: [String: JSONValue] = ["turn": .string(UUID().uuidString), "preset": .string(preset.id.uuidString)]
  #expect(try await secure("turn", turn)["status"] == .string("approval"))
  #expect(submitted.isEmpty)
  bridge.approvePairing()
  #expect(try await secure("menu")["status"] == .string("ready"))
  #expect(try await secure("turn", turn)["status"] == .string("thinking"))
  let replyDeadline = ContinuousClock.now + .seconds(5)
  var reply = try await secure("turn", turn)
  while reply["status"] == .string("thinking") && ContinuousClock.now < replyDeadline {
    try await Task.sleep(for: .milliseconds(20))
    reply = try await secure("turn", turn)
  }
  #expect(reply["text"] == .string("Réponse courte"))
  #expect(submitted == [preset.text])
  bridge.unpair()
  #expect(try await secure("turn", turn)["status"] == .string("unpaired"))
}
