import Foundation
import MaiCore

/// `/provider add acp NAME [COMMAND ARG ...]` or a remote WebSocket endpoint.
public enum ACPProviderCommand {
  public static func configuration(_ fields: [String]) throws -> ConfiguredProvider {
    guard let name = fields.first, !name.isEmpty else {
      throw JSONRPCError.invalidParams(
        "Usage: /provider add acp NAME [COMMAND ARG ... | --url URL --cwd DIR [--token-env ENV]]")
    }
    if fields.count == 1 {
      guard let known = ACPCatalog.agent(name) else {
        throw JSONRPCError.invalidParams(
          "Unknown ACP agent '\(name)'; supply its command and arguments")
      }
      return known.configuredProvider()
    }
    var options: [String: JSONValue] = [:]
    if fields[1] == "--url" {
      let flags = Array(fields.dropFirst())
      guard flags.count.isMultiple(of: 2) else {
        throw JSONRPCError.invalidParams("ACP options require values")
      }
      for index in stride(from: 0, to: flags.count, by: 2) {
        let key: String
        switch flags[index] {
        case "--url": key = "url"
        case "--cwd": key = "remoteCwd"
        case "--token-env": key = "tokenEnv"
        default: throw JSONRPCError.invalidParams("Unknown ACP option '\(flags[index])'")
        }
        options[key] = .string(flags[index + 1])
      }
    } else {
      options = [
        "command": .string(fields[1]), "args": .array(fields.dropFirst(2).map(JSONValue.string)),
      ]
    }
    let provider = ConfiguredProvider(
      id: name, kind: "acp", displayName: name, defaultModel: name, options: options)
    _ = try ACPConfiguredProviderFactory().makeProvider(from: provider, environment: [:])
    return provider
  }
}
