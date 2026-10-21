// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let visualizerTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags(["-parse-as-library"]),
]

let testTargetSettings: [SwiftSetting] = approachableConcurrencySettings + [
    .enableExperimentalFeature("SwiftTesting"),
]

let package = Package(
    name: "WinkVisualizer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "WinkVisualizer",
            targets: ["WinkVisualizer"]),
    ],
    dependencies: [
        .package(path: "../WinkFoundation"),
        .package(path: "../WinkProtocols"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "WinkVisualizer",
            dependencies: [
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkProtocols", package: "WinkProtocols"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            swiftSettings: visualizerTargetSettings),
        .testTarget(
            name: "WinkVisualizerTests",
            dependencies: [
                "WinkVisualizer",
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkProtocols", package: "WinkProtocols"),
            ],
            swiftSettings: testTargetSettings),
    ],
    swiftLanguageModes: [.v6])
