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
  targets: [
    .binaryTarget(
      name: "LibGhostty",
      path: "Vendor/LibGhostty.xcframework"
    ),
    .target(
      name: "FeatherCore"
    ),
    .executableTarget(
      name: "Feather",
      dependencies: [
        "FeatherCore",
        "LibGhostty",
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Carbon"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreText"),
        .linkedFramework("IOSurface"),
        .linkedFramework("Metal"),
        .linkedFramework("SwiftUI"),
        .linkedLibrary("c++"),
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
        "LibGhostty",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
