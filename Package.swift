// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "butterfly",
  platforms: [
    .macOS(.v26),
    .iOS(.v26),
  ],
  products: [
    .library(
      name: "Butterfly",
      targets: ["Butterfly", "WebSocketSystem"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-log.git", branch: "main"),
    .package(url: "https://github.com/zaneenders/git-commit-hash-plugin.git", from: "0.0.2"),
  ],
  targets: [
    .target(
      name: "Butterfly",
      dependencies: [
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
      ], swiftSettings: swiftSettings,
      plugins: [
        .plugin(name: "GitCommitHashPlugin", package: "git-commit-hash-plugin")
      ]
    ),
    .target(
      name: "WebSocketSystem",
      dependencies: [
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
      ], swiftSettings: swiftSettings,
      plugins: [
        .plugin(name: "GitCommitHashPlugin", package: "git-commit-hash-plugin")
      ]
    ),
    .testTarget(
      name: "ButterflyTests",
      dependencies: ["Butterfly"]
    ),
    .testTarget(
      name: "WebSocketSystemTests",
      dependencies: ["WebSocketSystem"]
    ),
  ]
)

let swiftSettings: [SwiftSetting] = [
  .strictMemorySafety(),
  .treatAllWarnings(as: .error),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableExperimentalFeature("Span"),
  .enableExperimentalFeature("LifetimeDependence"),
]
