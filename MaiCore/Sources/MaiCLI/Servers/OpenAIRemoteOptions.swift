import Foundation
import MaiACP
import MaiCore

struct OpenAIRemoteOptions: Equatable, Sendable {
  var host = "127.0.0.1"
  var port = 11435
  var allowTools = false

  init(_ arguments: [String]) throws {
    var seen = Set<String>()
    var loopback = false
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      guard seen.insert(flag).inserted else {
        throw JSONRPCError.invalidParams("Duplicate option \(flag)")
      }
      index += 1
      switch flag {
      case "--tools": allowTools = true
      case "--loopback": loopback = true
      case "--protocol", "--port", "--bind":
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
          throw JSONRPCError.invalidParams("\(flag) requires a value")
        }
        let value = arguments[index]
        index += 1
        switch flag {
        case "--protocol":
          guard value == "openai" else {
            throw JSONRPCError.invalidParams("Use --protocol openai")
          }
        case "--port":
          guard let port = Int(value), (1...65535).contains(port) else {
            throw JSONRPCError.invalidParams("Port must be between 1 and 65535")
          }
          self.port = port
        default:
          guard !value.isEmpty else { throw JSONRPCError.invalidParams("Bind address is empty") }
          host = value
        }
      default:
        throw JSONRPCError.invalidParams(
          "Usage: /remote serve --protocol openai [--port PORT] [--bind HOST] [--tools]"
        )
      }
    }
    if loopback, !Self.isLoopback(host) {
      throw JSONRPCError.invalidParams("--loopback cannot be combined with a LAN bind address")
    }
  }

  static func isLoopback(_ host: String) -> Bool {
    ["127.0.0.1", "::1", "localhost"].contains(host)
  }
}
