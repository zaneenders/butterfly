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
    traits: [
        .trait(name: "SSL", description: "Enable SSL")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", branch: "main"),
        .package(url: "https://github.com/zaneenders/git-commit-hash-plugin.git", from: "0.0.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.21.0"),
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
