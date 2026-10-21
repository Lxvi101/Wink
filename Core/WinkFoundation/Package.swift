// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let foundationTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags(["-parse-as-library"]),
]

let package = Package(
    name: "WinkFoundation",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "WinkFoundation",
            targets: ["WinkFoundation"]),
        // Test-only support product. Production targets do not depend on or link this module.
        .library(
            name: "WinkFoundationTestSupport",
            targets: ["WinkFoundationTestSupport"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WinkFoundation",
            dependencies: [],
            swiftSettings: foundationTargetSettings),
        .target(
            name: "WinkFoundationTestSupport",
            dependencies: ["WinkFoundation"],
            swiftSettings: approachableConcurrencySettings),
        .testTarget(
            name: "WinkFoundationTests",
            dependencies: ["WinkFoundation", "WinkFoundationTestSupport"],
            swiftSettings: approachableConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
