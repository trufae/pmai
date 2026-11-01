// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The core profile omits executable and platform dependency graphs entirely;
// --filter only selects tests after SwiftPM has built every test target.
let testProfile = Context.environment["PMAI_TEST_PROFILE"]
let focusedTests = ["core", "chat", "documents", "voice", "mobile"].contains(testProfile ?? "")
let xmlPackage = Package.Dependency.package(
  url: "https://github.com/compnerd/xylem", revision: "9881c95ce3a139f4ccfa584676201516c2a5751d")
let cliDependencies: [Target.Dependency] = [
  "MaiCore", "MaiMCP", "MaiOpenAI", "MaiPluginHost", "MaiStandardTools", "MaiVisionOCR",
  "CMaiTerminal", "MaiVoice",
  "MaiDocuments", "MaiMarkdown", "MaiACP", "MaiACPGateway", "MaiLocalProviders",
  .product(name: "Crypto", package: "swift-crypto"),
]
var localProviderDependencies: [Target.Dependency] = ["MaiCore"]
var localProviderSwiftSettings: [SwiftSetting] = []
var packageDependencies: [Package.Dependency] = [
  .package(url: "https://github.com/apple/swift-crypto", from: "4.5.2"),
  .package(url: "https://github.com/apple/swift-nio", from: "2.81.0"),
  xmlPackage,
  .package(
    name: "Forwiroh", path: Context.environment["PMAI_FORWIROH_PATH"] ?? "../Vendor/Forwiroh"),
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
  if !focusedTests && Context.environment["PMAI_NO_MLX"] == nil {
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
      .product(name: "HFAPI", package: "swift-hf-api", condition: .when(platforms: mlxPlatforms)),
      .product(name: "Tokenizers", package: "swift-tokenizers", condition: .when(platforms: mlxPlatforms)),
    ]
  }
#endif
let package = Package(
  name: "MaiCore",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "MaiCore", targets: ["MaiCore"]),
    .library(name: "MaiVoice", targets: ["MaiVoice"]),
    .library(name: "MaiOpenAI", targets: ["MaiOpenAI"]),
    .library(name: "MaiLocalProviders", targets: ["MaiLocalProviders"]),
    .library(name: "MaiChat", targets: ["MaiChat"]),
    .library(name: "MaiMobile", targets: ["MaiMobile"]),
    .library(name: "MaiMCP", targets: ["MaiMCP"]),
    .library(name: "MaiStandardTools", targets: ["MaiStandardTools"]),
    .library(name: "MaiVisionOCR", targets: ["MaiVisionOCR"]),
    .library(name: "MaiPluginSDK", targets: ["MaiPluginSDK"]),
    .library(name: "MaiPluginHost", targets: ["MaiPluginHost"]),
    .library(name: "MaiDocuments", targets: ["MaiDocuments"]),
    .library(name: "MaiMarkdown", targets: ["MaiMarkdown"]),
    .library(name: "MaiACP", targets: ["MaiACP"]),
    .library(name: "MaiFixturePlugin", type: .dynamic, targets: ["MaiFixturePlugin"]),
    .executable(name: "pmai", targets: ["MaiCLI"]),
  ],
  dependencies: packageDependencies,
  targets: [
    .target(name: "CMaiTerminal"),
    .target(name: "MaiCore"),
    .target(name: "MaiVoice", dependencies: ["MaiCore", "MaiOpenAI"]),
    .target(name: "MaiMarkdown"),
    .target(name: "MaiOpenAI", dependencies: [
      "MaiCore", .product(name: "Crypto", package: "swift-crypto"),
      .product(name: "CryptoExtras", package: "swift-crypto"),
    ]),
    .target(name: "MaiLocalProviders", dependencies: localProviderDependencies, swiftSettings: localProviderSwiftSettings),
    .target(name: "MaiChat", dependencies: ["MaiCore", "MaiOpenAI"]),
    .target(name: "MaiMobile", dependencies: ["MaiCore", "MaiChat", "MaiOpenAI", "MaiMCP", "MaiACP", "MaiStandardTools", "MaiDocuments"]),
    .testTarget(name: "MaiMobileTests", dependencies: ["MaiMobile", "MaiCore", "MaiACP", "MaiStandardTools"]),
    .target(name: "MaiACP", dependencies: ["MaiCore", "MaiStandardTools",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
        .product(
          name: "Forwiroh", package: "Forwiroh",
          condition: .when(platforms: [.macOS, .iOS, .linux, .android])),
      ]),
    .target(name: "MaiACPGateway", dependencies: [
      "MaiACP", "MaiCore",
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOPosix", package: "swift-nio"),
      .product(name: "NIOHTTP1", package: "swift-nio"),
      .product(name: "NIOWebSocket", package: "swift-nio"),
    ]),
    .target(name: "MaiMCP", dependencies: ["MaiCore"]),
    .target(name: "MaiStandardTools", dependencies: ["MaiCore", "MaiDocuments", "MaiVisionOCR"]),
    .target(name: "MaiVisionOCR", dependencies: ["MaiCore"]),
    .target(name: "MaiDocuments", dependencies: [
      "MaiCore", "MaiMarkdown",
      .product(name: "SAXParser", package: "xylem", condition: .when(platforms: [.linux, .android, .windows])),
      .product(name: "XMLCore", package: "xylem", condition: .when(platforms: [.linux, .android, .windows])),
    ]),
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
    .executableTarget(
      name: "MaiCLI",
      dependencies: cliDependencies,
      path: "Sources/mai",
      exclude: ["VoiceInfo.plist"],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Sources/mai/VoiceInfo.plist").path], .when(platforms: [.macOS])),
        .linkedLibrary("ssl", .when(platforms: [.android])),
        .linkedLibrary("crypto", .when(platforms: [.android])),
        .linkedLibrary("z", .when(platforms: [.android])),
      ]),
    .testTarget(name: "MaiVoiceTests", dependencies: ["MaiVoice", "MaiCore"]),
    .testTarget(
      name: "MaiChatTests",
      dependencies: ["MaiChat", "MaiCore"]),
    .testTarget(
      name: "MaiCoreTests",
      dependencies: ["MaiCore", "MaiTestSupport"]),
    .target(name: "MaiTestSupport", dependencies: ["MaiCore"], path: "Tests/Support"),
    .testTarget(name: "MaiOpenAITests", dependencies: ["MaiCore", "MaiOpenAI", "MaiTestSupport"]),
    .testTarget(name: "MaiMCPTests", dependencies: ["MaiCore", "MaiMCP", "MaiTestSupport"]),
    .testTarget(name: "MaiStandardToolsTests", dependencies: ["MaiCore", "MaiStandardTools"]),
    .testTarget(name: "MaiDocumentsTests", dependencies: ["MaiCore", "MaiDocuments", "MaiMarkdown"]),
    .testTarget(name: "MaiMarkdownTests", dependencies: ["MaiMarkdown"]),
    .testTarget(name: "MaiACPTests", dependencies: ["MaiCore", "MaiACP", "MaiStandardTools", "MaiTestSupport"]),
    .testTarget(name: "MaiCLIHTTPTests", dependencies: ["MaiCLI", "MaiCore", "MaiACP", "MaiACPGateway"]),
    .testTarget(name: "MaiLocalProvidersTests", dependencies: ["MaiCore", "MaiLocalProviders"]),
    .testTarget(name: "MaiPluginTests", dependencies: [
      "MaiCore", "MaiMCP", "MaiPluginHost", "MaiStandardTools", "MaiVisionOCR",
    ]),
  ])

if focusedTests {
  let names = testProfile == "core" ? ["MaiCore", "MaiCoreTests", "MaiTestSupport"]
    : testProfile == "mobile" ? ["MaiCore", "MaiChat", "MaiOpenAI", "MaiMCP", "MaiACP", "MaiStandardTools", "MaiDocuments", "MaiMarkdown", "MaiVisionOCR", "MaiMobile", "MaiMobileTests"]
    : testProfile == "voice" ? ["MaiCore", "MaiVoice", "MaiOpenAI", "MaiVoiceTests"]
    : testProfile == "documents" ? ["MaiCore", "MaiMarkdown", "MaiDocuments", "MaiDocumentsTests"]
    : ["MaiCore", "MaiOpenAI", "MaiChat", "MaiChatTests"]
  package.products = package.products.filter { names.contains($0.name) }
  package.dependencies = testProfile == "mobile" ? packageDependencies : testProfile == "core" ? []
    : testProfile == "documents" ? [xmlPackage] : Array(packageDependencies.prefix(1))
  package.targets = package.targets.filter { names.contains($0.name) }
}
