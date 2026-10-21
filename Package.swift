// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let protocolTargetSettings = approachableConcurrencySettings + [
    .defaultIsolation(MainActor.self),
]

let automationTargetSettings = approachableConcurrencySettings + [
    .enableExperimentalFeature("SwiftTesting"),
]

let package = Package(
    name: "Wink",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "WinkFoundation",
            targets: ["WinkFoundation"]),
        .library(
            name: "WinkProtocols",
            targets: ["WinkProtocols"]),
        .library(
            name: "WinkAutomationKit",
            targets: ["WinkAutomationKit"]),
        .library(
            name: "WinkBridge",
            targets: ["WinkBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/openclaw/AXorcist.git", exact: "0.2.2"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "WinkFoundation",
            path: "Core/WinkFoundation/Sources/WinkFoundation",
            swiftSettings: approachableConcurrencySettings),
        .target(
            name: "WinkProtocols",
            dependencies: [
                "WinkFoundation",
            ],
            path: "Core/WinkProtocols/Sources/WinkProtocols",
            swiftSettings: protocolTargetSettings),
        .target(
            name: "WinkAutomationKit",
            dependencies: [
                "WinkFoundation",
                "WinkProtocols",
                .product(name: "AXorcist", package: "AXorcist"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            path: "Core/WinkAutomationKit/Sources/WinkAutomationKit",
            exclude: ["Core/README.md"],
            swiftSettings: automationTargetSettings),
        .target(
            name: "WinkBridge",
            dependencies: [
                "WinkAutomationKit",
                "WinkFoundation",
            ],
            path: "Core/WinkCore/Sources/WinkBridge",
            swiftSettings: approachableConcurrencySettings,
            linkerSettings: [.linkedLibrary("bsm")]),
    ],
    swiftLanguageModes: [.v6])
