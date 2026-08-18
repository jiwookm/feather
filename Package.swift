// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Feather",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "Feather", targets: ["Feather"]),
    .library(name: "FeatherCore", targets: ["FeatherCore"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/jiwookm/GhosttyKit.git",
      revision: "ea2889264d3586dab2482e17e093e34a77d1b027"
    )
  ],
  targets: [
    .target(
      name: "FeatherCore"
    ),
    .executableTarget(
      name: "Feather",
      dependencies: [
        "FeatherCore",
        .product(name: "GhosttyKit", package: "GhosttyKit"),
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("SwiftUI"),
      ]
    ),
    .testTarget(
      name: "FeatherCoreTests",
      dependencies: ["FeatherCore"]
    ),
    .testTarget(
      name: "FeatherTests",
      dependencies: [
        "Feather",
        .product(name: "GhosttyKit", package: "GhosttyKit"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
