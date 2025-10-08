// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "butterfly",
    products: [
        .library(
            name: "Butterfly",
            targets: ["Butterfly"]
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
            ], swiftSettings: swiftSettings,
            plugins: [
                .plugin(name: "GitCommitHashPlugin", package: "git-commit-hash-plugin")
            ]
        ),
        .testTarget(
            name: "ButterflyTests",
            dependencies: ["Butterfly"]
        ),
    ]
)

let swiftSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableExperimentalFeature("Span"),
    .enableExperimentalFeature("LifetimeDependence"),
]
