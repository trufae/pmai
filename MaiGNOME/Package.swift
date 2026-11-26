// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MaiGNOME",
  products: [.executable(name: "pmai-gnome", targets: ["MaiGNOME"])],
  dependencies: [.package(path: "../MaiCore")],
  targets: [
    .systemLibrary(name: "CGNOME", pkgConfig: "libadwaita-1", providers: [
      .apt(["libgtk-4-dev", "libadwaita-1-dev"]),
      .yum(["gtk4-devel", "libadwaita-devel"]),
    ]),
    .executableTarget(name: "MaiGNOME", dependencies: [
      "CGNOME",
      .product(name: "MaiCore", package: "MaiCore"),
      .product(name: "MaiACP", package: "MaiCore"),
      .product(name: "MaiMarkdown", package: "MaiCore"),
      .product(name: "MaiDocuments", package: "MaiCore"),
    ]),
  ])
