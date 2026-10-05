// swift-tools-version: 6.0
import PackageDescription

// The `/visual` workspace needs swift-tui, which only builds against Darwin
// and Glibc. Android already leaves it out through the platform condition;
// PMAI_NO_VISUAL=1 does the same for builds SwiftPM still calls Linux, such
// as the fully static musl release made with the Swift Static Linux SDK.
let visualEnabled = Context.environment["PMAI_NO_VISUAL"] == nil
var cliDependencies: [Target.Dependency] = [
  "MaiCore", "MaiMCP", "MaiOpenAI", "MaiPluginHost", "MaiStandardTools", "MaiVisionOCR",
  "MaiDocuments", "MaiMarkdown", "MaiACP", "MaiACPGateway",
]
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
  dependencies: [
    .package(url: "https://github.com/SwiftTUI/swift-tui", exact: "0.13.3"),
    .package(url: "https://github.com/apple/swift-nio", from: "2.81.0"),
  ],
  targets: [
    .target(name: "MaiCore"),
    .target(name: "MaiMarkdown"),
    .target(name: "MaiOpenAI", dependencies: ["MaiCore"]),
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
        "MaiVisual", "MaiDocuments", "MaiMarkdown", "MaiACP",
        .product(name: "SwiftTUIRuntime", package: "swift-tui"),
        .product(name: "SwiftTUICLI", package: "swift-tui"),
      ]),
  ])
