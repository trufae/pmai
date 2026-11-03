import Foundation

/// Configuration diagnostics must not copy credentials into shareable exports.
public enum DebugDiagnostics {
  public static func value<T: Encodable>(_ value: T) throws -> JSONValue {
    sanitize(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)))
  }

  public static func sanitize(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields):
      return .object(Dictionary(uniqueKeysWithValues: fields.map { key, value in
        (key, sensitive(key) ? .string("[redacted]") : sanitize(value))
      }))
    case .array(let values): return .array(values.map(sanitize))
    case .string(let text):
      guard var url = URLComponents(string: text),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
      else { return value }
      url.user = nil
      url.password = nil
      url.query = nil
      url.fragment = nil
      return .string(url.string ?? "[redacted URL]")
    default: return value
    }
  }

  private static func sensitive(_ key: String) -> Bool {
    let name = key.lowercased().filter(\.isLetter)
    return ["authorization", "proxyauthorization", "cookie", "setcookie", "headers",
      "headerenvironment", "environment", "env", "credentials"].contains(name)
      || ["apikey", "token", "password", "secret"].contains { name.hasSuffix($0) }
      || name.hasSuffix("command")
  }
}
