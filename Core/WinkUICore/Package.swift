// swift-tools-version: 6.2
import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "WinkUICore",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "WinkUICore",
            targets: ["WinkUICore"]),
    ],
    dependencies: [
        .package(path: "../WinkCore"),
        .package(path: "../../AXorcist"),
    ],
    targets: [
        .target(
            name: "WinkUICore",
            dependencies: [
                .product(name: "WinkCore", package: "WinkCore"),
                .product(name: "AXorcist", package: "AXorcist"),
            ],
            swiftSettings: approachableConcurrencySettings),
        .testTarget(
            name: "WinkUITests",
            dependencies: ["WinkUICore"],
            swiftSettings: approachableConcurrencySettings),
    ])
