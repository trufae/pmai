import Foundation
import MaiCore

func environmentValue(
  _ names: [String],
  in environment: [String: String]
) -> String? {
  names.lazy.compactMap { environment[$0] }.first { !$0.isEmpty }
}

/// Unlike the other ad-hoc settings, an explicitly exported empty API key is
/// meaningful: it suppresses lower-priority aliases for an ad-hoc connection.
/// `PMAI_API_KEY_FILE` names a file holding the key instead, so the secret
/// itself never sits in the environment; it excludes `PMAI_API_KEY`.
func environmentAPIKey(in environment: [String: String]) throws -> String? {
  let keyFile =
    environment["PMAI_API_KEY_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if !keyFile.isEmpty {
    guard environment["PMAI_API_KEY"] == nil else { throw CLIError.apiKeySourcesConflict }
    return try ConfiguredProvider.apiKey(fromFile: keyFile)
  }
  for name in ["PMAI_API_KEY", "MAI_API_KEY", "OPENAI_API_KEY"] {
    if let value = environment[name] { return value }
  }
  return nil
}

func environmentName(
  _ names: [String],
  in environment: [String: String]
) -> String? {
  names.first { environment[$0].map { !$0.isEmpty } ?? false }
}
