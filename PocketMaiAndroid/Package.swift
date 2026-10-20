// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "PocketMaiAndroid",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "PocketMaiPortableUI", targets: ["PocketMaiPortableUI"]),
    // The reusable AndroidSwiftUI host loads this name without an app subclass.
    .library(name: "SwiftAndroidApp", type: .dynamic, targets: ["SwiftAndroidApp"]),
  ],
  dependencies: [
    .package(path: "../MaiCore"),
    .package(url: "https://github.com/PureSwift/Android.git", branch: "master"),
    .package(url: "https://github.com/swiftlang/swift-java.git", branch: "main"),
    // bootstrap.sh pins the framework. Its nested local package requires a
    // checkout rather than a remote SwiftPM dependency.
    .package(path: ".deps/AndroidSwiftUI"),
    .package(path: ".deps/AndroidSwiftUI/SwiftUICore"),
  ],
  targets: [
    .target(
      name: "PocketMaiPortableUI",
      dependencies: [
        .product(name: "MaiChat", package: "MaiCore"),
        .product(name: "MaiACP", package: "MaiCore"),
        .product(name: "MaiCore", package: "MaiCore"),
        .product(name: "MaiMarkdown", package: "MaiCore"),
        .product(
          name: "SwiftUICore", package: "SwiftUICore",
          condition: .when(platforms: [.macOS, .linux, .android])),
      ]),
    .target(
      name: "SwiftAndroidApp",
      dependencies: [
        "PocketMaiPortableUI",
        .product(
          name: "AndroidContent", package: "Android", condition: .when(platforms: [.android])),
        .product(name: "SwiftJava", package: "swift-java", condition: .when(platforms: [.android])),
        .product(name: "MaiChat", package: "MaiCore"),
        .product(name: "MaiACP", package: "MaiCore"),
        .product(
          name: "AndroidSwiftUI", package: "AndroidSwiftUI", condition: .when(platforms: [.android])
        ),
      ],
      linkerSettings: [
        .linkedLibrary("ssl", .when(platforms: [.android])),
        .linkedLibrary("crypto", .when(platforms: [.android])),
        .linkedLibrary("z", .when(platforms: [.android])),
      ]),
    .testTarget(
      name: "PocketMaiPortableUITests",
      dependencies: [
        "PocketMaiPortableUI", .product(name: "MaiChat", package: "MaiCore"),
        .product(name: "SwiftUICore", package: "SwiftUICore"),
      ]),
  ],
  swiftLanguageModes: [.v6]
)
