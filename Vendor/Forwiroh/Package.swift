// swift-tools-version: 6.2
// pmai SDK pin: Forwiroh 0.1.1. Update with Artifacts/manifest.json to invalidate the manifest cache.
import PackageDescription
import Foundation

// Maintainers create these artifacts with scripts/package-swift.py. Consumers
// use the packaged release; no build plugin invokes Cargo or generates bindings.
struct Artifact: Decodable {
    let name: String
    let path: String?
    let url: String?
    let checksum: String?
}
let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Artifacts/manifest.json")
guard let data = try? Data(contentsOf: manifest),
      let artifacts = try? JSONDecoder().decode([Artifact].self, from: data), !artifacts.isEmpty else {
    fatalError("Missing Forwiroh binaries. Unpack a SwiftPM release, or see docs/swiftpm.md for maintainer builds.")
}
let binaries: [Target] = artifacts.map { artifact in
    if let url = artifact.url, let checksum = artifact.checksum {
        return .binaryTarget(name: artifact.name, url: url, checksum: checksum)
    }
    return .binaryTarget(name: artifact.name, path: artifact.path!)
}
let coreDependencies: [Target.Dependency] = artifacts.map { artifact in
    .target(name: artifact.name, condition: .when(platforms:
        artifact.name == "ForwirohApple" ? [.macOS, .iOS] : [.linux, .android]))
}
let package = Package(
    name: "Forwiroh",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Forwiroh", targets: ["Forwiroh"])],
    targets: binaries + [
        .target(
            name: "Forwiroh",
            dependencies: coreDependencies,
            linkerSettings: [
                .linkedFramework("Network", .when(platforms: [.macOS, .iOS])),
                .linkedFramework("Security", .when(platforms: [.macOS, .iOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS, .iOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS, .iOS])),
                .linkedLibrary("resolv", .when(platforms: [.macOS, .iOS])),
                .linkedLibrary("iconv", .when(platforms: [.macOS, .iOS])),
                .linkedLibrary("dl", .when(platforms: [.linux, .android])),
                .linkedLibrary("m", .when(platforms: [.linux, .android])),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("android", .when(platforms: [.android])),
                .linkedLibrary("log", .when(platforms: [.android])),
            ]),
        .testTarget(name: "ForwirohTests", dependencies: ["Forwiroh"]),
    ]
)
