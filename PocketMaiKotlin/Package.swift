// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "PocketMaiKotlin",
  platforms: [.macOS(.v15)],
  products: [.library(name: "MaiKotlinBridge", type: .dynamic, targets: ["MaiKotlinBridge"])],
  dependencies: [
    .package(path: "../MaiCore"),
    .package(url: "https://github.com/swiftlang/swift-java.git",
      revision: "8a86a20f9fead2663e704f28daa34373fe4d3907"),
    .package(url: "https://github.com/MillerTechnologyPeru/swift-android-native.git",
      revision: "ebf3feff1b2b9d57a7996e0fb1da1b4d6bb8c36d"),
  ],
  targets: [
    .target(name: "MaiKotlinBridge", dependencies: [
      .product(name: "MaiMobile", package: "MaiCore"),
      .product(name: "MaiACP", package: "MaiCore"),
      .product(name: "SwiftJava", package: "swift-java"),
      .product(name: "AndroidLooper", package: "swift-android-native",
        condition: .when(platforms: [.android])),
    ], exclude: ["swift-java.config"], swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "max-page-size=16384"], .when(platforms: [.android])),
        .linkedLibrary("ssl", .when(platforms: [.android])),
        .linkedLibrary("crypto", .when(platforms: [.android])),
        .linkedLibrary("z", .when(platforms: [.android])),
      ], plugins: [.plugin(name: "JExtractSwiftPlugin", package: "swift-java")]),
  ]
)
