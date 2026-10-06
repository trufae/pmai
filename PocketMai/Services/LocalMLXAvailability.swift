import Foundation

import MaiLocalProviders

typealias LocalMLXAvailability = MLXAvailability

extension MLXAvailability {
  static let requirements =
    "MLX requires an A14 Bionic or newer chip (iPhone 12 or later, or iPhone SE 3rd generation), "
    + "or an iPad with an A14 or newer A-series chip, or an M-series chip."

  static let providerSetupSuggestion =
    "Choose a configured provider or add one in Settings > Providers > Add Provider. "
    + "You can connect to an OpenAI-compatible service or to Ollama or llama.cpp running on a computer."

  var unavailabilityMessage: String? {
    switch self {
    case .available:
      return nil
    case .simulator:
      return "MLX inference is unavailable in the iOS Simulator. Use a supported physical device "
        + "or a Mac with Apple silicon using the Designed for iPad destination. "
        + Self.providerSetupSuggestion
    case .metalUnavailable:
      return "MLX cannot run because no Metal GPU is available. " + Self.providerSetupSuggestion
    case .unsupportedGPU(let name):
      return "MLX is unavailable on this device (\(name)). " + Self.requirements
        + " Older chips, including the A12 in iPhone XS, cannot run MLX. "
        + Self.providerSetupSuggestion
    }
  }

  var alternativeProviderSuggestion: String {
    isAvailable
      ? "Use MLX Local with a downloaded model or choose another configured provider."
      : Self.providerSetupSuggestion
  }

  func offlineGuidance(appleAvailable: Bool) -> String {
    var providers: [String] = []
    if appleAvailable { providers.append("Apple Intelligence") }
    if isAvailable { providers.append("MLX Local with a downloaded model") }
    guard !providers.isEmpty else {
      return "Airplane Mode is on. On-device inference is unavailable on this device. "
        + "Turn off Airplane Mode in Settings, then choose or add a provider."
    }
    return "Airplane Mode is on. Use " + providers.joined(separator: " or ") + "."
  }
}
