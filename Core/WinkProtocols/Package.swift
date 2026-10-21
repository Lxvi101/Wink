// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(MainActor.self),
]

let protocolTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=50",
        "-Xfrontend", "-warn-long-expression-type-checking=50",
    ], .when(configuration: .debug)),
]

let package = Package(
    name: "WinkProtocols",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "WinkProtocols",
            targets: ["WinkProtocols"]),
    ],
    dependencies: [
        .package(path: "../WinkFoundation"),
    ],
    targets: [
        .target(
            name: "WinkProtocols",
            dependencies: [
                "WinkFoundation",
            ],
            swiftSettings: protocolTargetSettings),
        .testTarget(
            name: "WinkProtocolsTests",
            dependencies: ["WinkProtocols"],
            path: "Tests/WinkProtocolsTests",
            swiftSettings: approachableConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
