// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The `/visual` workspace needs swift-tui, which only builds against Darwin
// and Glibc. Android already leaves it out through the platform condition;
// PMAI_NO_VISUAL=1 does the same for builds SwiftPM still calls Linux, such
// as the fully static musl release made with the Swift Static Linux SDK.
let visualEnabled = Context.environment["PMAI_NO_VISUAL"] == nil
var cliDependencies: [Target.Dependency] = [
  "MaiCore", "MaiMCP", "MaiOpenAI", "MaiPluginHost", "MaiStandardTools", "MaiVisionOCR",
  "MaiDocuments", "MaiMarkdown", "MaiACP", "MaiACPGateway", "MaiLocalProviders",
]
var localProviderDependencies: [Target.Dependency] = ["MaiCore"]
var localProviderSwiftSettings: [SwiftSetting] = []
var packageDependencies: [Package.Dependency] = [
  .package(url: "https://github.com/SwiftTUI/swift-tui", exact: "0.13.3"),
  .package(url: "https://github.com/apple/swift-nio", from: "2.81.0"),
]
#if os(macOS)
  // Optional Foundation Models APIs follow the SDK, including when using a newer Swift toolchain.
  let sdkVersionProcess = Process()
  let sdkVersionOutput = Pipe()
  sdkVersionProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  sdkVersionProcess.arguments = ["--sdk", Context.environment["SDKROOT"] ?? "macosx", "--show-sdk-version"]
  sdkVersionProcess.standardOutput = sdkVersionOutput
  sdkVersionProcess.standardError = FileHandle.nullDevice
  if (try? sdkVersionProcess.run()) != nil {
    let version = String(decoding: sdkVersionOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
    sdkVersionProcess.waitUntilExit()
    if let major = version.first {
      if major > 26 || major == 26 && (version.dropFirst().first ?? 0) >= 4 {
        localProviderSwiftSettings.append(.define("PMAI_FOUNDATION_MODELS_26_4"))
      }
      if major >= 27 { localProviderSwiftSettings.append(.define("PMAI_FOUNDATION_MODELS_27")) }
    }
  }
  if Context.environment["PMAI_NO_MLX"] == nil {
    var mlxPlatforms: [Platform] = [.iOS]
    #if arch(arm64)
      mlxPlatforms.append(.macOS)
    #endif
    packageDependencies += [
      .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
      .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
      .package(url: "https://github.com/DePasqualeOrg/swift-hf-api-mlx", exact: "0.2.0"),
      .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers-mlx", exact: "0.3.0"),
      // These adapters use the Swift APIs shipped by PocketMai, before the Rust API migration.
      .package(url: "https://github.com/DePasqualeOrg/swift-hf-api", exact: "0.3.2"),
      .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers", exact: "0.5.0"),
    ]
    localProviderDependencies += [
      .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: mlxPlatforms)),
      .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: mlxPlatforms)),
      .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: mlxPlatforms)),
      .product(name: "MLXLMHFAPI", package: "swift-hf-api-mlx", condition: .when(platforms: mlxPlatforms)),
      .product(name: "MLXLMTokenizers", package: "swift-tokenizers-mlx", condition: .when(platforms: mlxPlatforms)),
    ]
  }
#endif
var cliSwiftSettings: [SwiftSetting] = []
if visualEnabled {
  cliDependencies.append(.target(name: "MaiVisual", condition: .when(platforms: [.macOS, .linux])))
  cliSwiftSettings.append(.define("PMAI_HAS_VISUAL", .when(platforms: [.macOS, .linux])))
}

let package = Package(
  name: "MaiCore",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "MaiCore", targets: ["MaiCore"]),
    .library(name: "MaiOpenAI", targets: ["MaiOpenAI"]),
    .library(name: "MaiLocalProviders", targets: ["MaiLocalProviders"]),
    .library(name: "MaiChat", targets: ["MaiChat"]),
    .library(name: "MaiMCP", targets: ["MaiMCP"]),
    .library(name: "MaiStandardTools", targets: ["MaiStandardTools"]),
    .library(name: "MaiVisionOCR", targets: ["MaiVisionOCR"]),
    .library(name: "MaiPluginSDK", targets: ["MaiPluginSDK"]),
    .library(name: "MaiPluginHost", targets: ["MaiPluginHost"]),
    .library(name: "MaiVisual", targets: ["MaiVisual"]),
    .library(name: "MaiDocuments", targets: ["MaiDocuments"]),
    .library(name: "MaiMarkdown", targets: ["MaiMarkdown"]),
    .library(name: "MaiACP", targets: ["MaiACP"]),
    .library(name: "MaiFixturePlugin", type: .dynamic, targets: ["MaiFixturePlugin"]),
    .executable(name: "pmai", targets: ["MaiCLI"]),
  ],
  dependencies: packageDependencies,
  targets: [
    .target(name: "MaiCore"),
    .target(name: "MaiMarkdown"),
    .target(name: "MaiOpenAI", dependencies: ["MaiCore"]),
    .target(name: "MaiLocalProviders", dependencies: localProviderDependencies, swiftSettings: localProviderSwiftSettings),
    .target(name: "MaiChat", dependencies: ["MaiCore", "MaiOpenAI"]),
    .target(name: "MaiACP", dependencies: ["MaiCore"]),
    .target(name: "MaiACPGateway", dependencies: [
      "MaiACP", "MaiCore",
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOPosix", package: "swift-nio"),
      .product(name: "NIOHTTP1", package: "swift-nio"),
      .product(name: "NIOWebSocket", package: "swift-nio"),
    ]),
    .target(name: "MaiMCP", dependencies: ["MaiCore"]),
    .target(name: "MaiStandardTools", dependencies: ["MaiCore", "MaiDocuments"]),
    .target(name: "MaiVisionOCR", dependencies: ["MaiCore"]),
    .target(name: "MaiDocuments", dependencies: ["MaiCore", "MaiMarkdown"]),
    .target(
      name: "CMaiPluginABI",
      publicHeadersPath: "include"),
    .target(
      name: "MaiPluginSDK",
      dependencies: ["CMaiPluginABI"]),
    .target(
      name: "MaiPluginHost",
      dependencies: ["MaiCore", "MaiPluginSDK", "CMaiPluginABI"]),
    .target(
      name: "MaiFixturePlugin",
      dependencies: ["MaiPluginSDK", "CMaiPluginABI"]),
    .target(
      name: "MaiVisual",
      dependencies: [
        "MaiCore", "MaiMarkdown",
        .product(name: "SwiftTUIRuntime", package: "swift-tui"),
        .product(name: "SwiftTUICLI", package: "swift-tui"),
      ]),
    .executableTarget(
      name: "MaiCLI",
      dependencies: cliDependencies,
      path: "Sources/mai",
      swiftSettings: cliSwiftSettings,
      linkerSettings: [
        .linkedLibrary("ssl", .when(platforms: [.android])),
        .linkedLibrary("crypto", .when(platforms: [.android])),
        .linkedLibrary("z", .when(platforms: [.android])),
      ]),
    .testTarget(
      name: "MaiChatTests",
      dependencies: ["MaiChat", "MaiCore"]),
    .testTarget(
      name: "MaiCoreTests",
      dependencies: [
        "MaiCore", "MaiMCP", "MaiOpenAI", "MaiPluginHost", "MaiStandardTools", "MaiVisionOCR",
        "MaiVisual", "MaiDocuments", "MaiMarkdown", "MaiACP", "MaiLocalProviders",
        .product(name: "SwiftTUIRuntime", package: "swift-tui"),
        .product(name: "SwiftTUICLI", package: "swift-tui"),
      ]),
  ])
