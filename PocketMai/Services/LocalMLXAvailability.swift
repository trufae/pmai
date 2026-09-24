import Foundation
import Metal

/// Check Metal without initializing MLX: unsupported GPUs can abort inside its runtime.
enum LocalMLXAvailability: Equatable, Sendable {
  case available
  case simulator
  case metalUnavailable
  case unsupportedGPU(String)

  static let current: Self = {
    #if targetEnvironment(simulator)
      return .simulator
    #else
      let device = MTLCreateSystemDefaultDevice()
      return evaluate(
        isSimulator: false, gpuName: device?.name,
        supportsApple7: device?.supportsFamily(.apple7) == true)
    #endif
  }()

  static func evaluate(isSimulator: Bool, gpuName: String?, supportsApple7: Bool) -> Self {
    if isSimulator { return .simulator }
    guard let gpuName else { return .metalUnavailable }
    // MLX's SIMD-group matrix operations require Apple GPU family 7 (A14/M1) or later.
    // https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
    return supportsApple7 ? .available : .unsupportedGPU(gpuName)
  }

  var isAvailable: Bool { self == .available }

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
