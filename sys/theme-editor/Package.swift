// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ThemeEditor",
  products: [.executable(name: "ThemeEditor", targets: ["ThemeEditor"])],
  targets: [
    .executableTarget(name: "ThemeEditor", path: ".", exclude: ["Tests", "README.md"],
      sources: ["ThemeEditor.swift", "ThemeEditorUI.swift", "ThemePreview.swift"]),
    .testTarget(name: "ThemeEditorTests", dependencies: ["ThemeEditor"], path: "Tests",
      exclude: ["terminal-smoke.py"]),
  ])
