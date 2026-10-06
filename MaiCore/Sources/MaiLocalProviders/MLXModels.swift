import Foundation

#if canImport(Metal)
  import Metal
#endif

public enum MLXModels {
  public static let defaultModelID = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit"
  public static let presets = [
    defaultModelID,
    "mlx-community/LFM2-350M-MLX", "mlx-community/LFM2-2.6B-4bit",
    "mlx-community/Qwen2.5-0.5B-Instruct-4bit", "Irfanuruchi/SmolLM2-135M-Instruct-MLX-4bit",
    "mlx-community/Qwen2.5-1.5B-Instruct-4bit", "Irfanuruchi/SmolLM2-360M-Instruct-MLX-4bit",
    "mlx-community/Llama-3.2-1B-Instruct-4bit", "mlx-community/MiniCPM5-1B-4bit",
    "mlx-community/Qwen3-0.6B-4bit", "mlx-community/Qwen3-1.7B-4bit",
    "mlx-community/Qwen3.5-0.8B-4bit", "mlx-community/Qwen3.5-2B-4bit",
    "mlx-community/gemma-3-1b-it-4bit", "mlx-community/Jan-v3-4B-base-instruct-4bit",
  ]

  public static func isValid(_ repoID: String) -> Bool {
    let components = repoID.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    return components.count == 2 && components.allSatisfy {
      let component = String($0)
      return !component.isEmpty && component.count <= 96
        && component.rangeOfCharacter(from: allowed.inverted) == nil
        && !component.hasPrefix(".") && !component.hasPrefix("-")
        && !component.hasSuffix(".") && !component.hasSuffix("-")
        && !component.contains("..") && !component.contains("--")
    }
  }
}

/// Check Metal without initializing MLX: unsupported GPUs can abort inside its runtime.
public enum MLXAvailability: Equatable, Sendable {
  case available
  case simulator
  case metalUnavailable
  case unsupportedGPU(String)

  public static let current: Self = {
    #if targetEnvironment(simulator)
      return .simulator
    #elseif canImport(Metal)
      let device = MTLCreateSystemDefaultDevice()
      return evaluate(
        isSimulator: false, gpuName: device?.name,
        supportsApple7: device?.supportsFamily(.apple7) == true)
    #else
      return .metalUnavailable
    #endif
  }()

  public static func evaluate(isSimulator: Bool, gpuName: String?, supportsApple7: Bool) -> Self {
    if isSimulator { return .simulator }
    guard let gpuName else { return .metalUnavailable }
    return supportsApple7 ? .available : .unsupportedGPU(gpuName)
  }

  public var isAvailable: Bool { self == .available }

  public var unavailableReason: String? {
    switch self {
    case .available: nil
    case .simulator: "MLX inference is unavailable in the iOS Simulator. Use a supported physical device or an Apple silicon Mac."
    case .metalUnavailable: "MLX requires an available Metal GPU on Apple silicon."
    case .unsupportedGPU(let name): "MLX cannot run on \(name). It requires an M-series Mac or an A14 or newer iPhone/iPad."
    }
  }
}
