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
      url: "https://github.com/briannadoubt/GhosttyKit.git",
      revision: "f3756807a61a42dba3dc1d866a1fd865f1ddfe21"
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
