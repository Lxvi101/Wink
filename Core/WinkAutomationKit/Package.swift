// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableExperimentalFeature("SwiftTesting"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let kitTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags(["-parse-as-library"]),
]

let package = Package(
    name: "WinkAutomationKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "WinkAutomationKit",
            targets: ["WinkAutomationKit"]),
        // Test-only support product. Production targets do not depend on or link this module.
        .library(
            name: "WinkAutomationKitTestSupport",
            targets: ["WinkAutomationKitTestSupport"]),
    ],
    dependencies: [
        .package(path: "../WinkFoundation"),
        .package(path: "../WinkProtocols"),
        .package(path: "../../AXorcist"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "WinkAutomationKit",
            dependencies: [
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkProtocols", package: "WinkProtocols"),
                .product(name: "AXorcist", package: "AXorcist"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            exclude: ["Core/README.md"],
            swiftSettings: kitTargetSettings),
        .target(
            name: "WinkAutomationKitTestSupport",
            dependencies: [
                "WinkAutomationKit",
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkFoundationTestSupport", package: "WinkFoundation"),
            ],
            swiftSettings: approachableConcurrencySettings),
        .target(
            name: "DescriptorForkTestSupport",
            path: "Tests/Support/DescriptorForkTestSupport",
            publicHeadersPath: "include"),
        .executableTarget(
            name: "HostWindowCloseFixture",
            dependencies: ["WinkAutomationKit"],
            path: "Tests/Support/HostWindowCloseFixture",
            swiftSettings: approachableConcurrencySettings),
        .testTarget(
            name: "WinkAutomationKitTests",
            dependencies: [
                "WinkAutomationKit",
                "WinkAutomationKitTestSupport",
                "DescriptorForkTestSupport",
                "HostWindowCloseFixture",
                .product(name: "WinkFoundationTestSupport", package: "WinkFoundation"),
            ],
            path: "Tests/WinkAutomationKitTests",
            swiftSettings: approachableConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
