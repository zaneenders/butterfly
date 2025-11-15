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
  traits: [
    .trait(name: "SSL", description: "Enable SSL")  // TODO: remove this when we merge Butterfly and WebSocketSystem
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-log.git", branch: "main"),
    .package(url: "https://github.com/zaneenders/git-commit-hash-plugin.git", from: "0.0.2"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.21.0"),
    .package(url: "https://github.com/apple/swift-configuration", from: "0.2.0"),
    .package(url: "https://github.com/apple/swift-async-dns-resolver.git", from: "0.4.0"),
    .package(url: "https://github.com/apple/swift-system", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "Butterfly",
      dependencies: [
        .product(name: "NIO", package: "swift-nio"),
        .product(
          name: "NIOSSL", package: "swift-nio-ssl",
          condition: .when(traits: ["SSL"])),
        .product(name: "Logging", package: "swift-log"),
        .product(
          name: "Configuration", package: "swift-configuration",
          condition: .when(traits: ["SSL"])),
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
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "AsyncDNSResolver", package: "swift-async-dns-resolver"),
        .product(name: "SystemPackage", package: "swift-system"),
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
      dependencies: [
        "WebSocketSystem",
        .product(
          name: "Configuration", package: "swift-configuration",
          condition: .when(traits: ["SSL"])),
      ]
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
