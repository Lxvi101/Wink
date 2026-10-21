// swift-tools-version: 6.2

import Foundation
import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let coreTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags(["-parse-as-library"]),
]

let includeAutomationTests = ProcessInfo.processInfo.environment["WINK_INCLUDE_AUTOMATION_TESTS"] == "true"
let testTargetSettings: [SwiftSetting] = {
    var base = approachableConcurrencySettings + [.enableExperimentalFeature("SwiftTesting")]
    if includeAutomationTests {
        base.append(.define("WINK_INCLUDE_AUTOMATION_TESTS"))
    }
    return base
}()

let package = Package(
    name: "WinkCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "WinkAutomation",
            targets: ["WinkAutomation"]),
        .library(
            name: "WinkAgentRuntime",
            targets: ["WinkAgentRuntime"]),
        .library(
            name: "WinkBridge",
            targets: ["WinkBridge"]),
        // Test-only support products. Production targets do not depend on or link these modules.
        .library(
            name: "WinkBridgeTestSupport",
            targets: ["WinkBridgeTestSupport"]),
        .library(
            name: "WinkAgentRuntimeTestSupport",
            targets: ["WinkAgentRuntimeTestSupport"]),
        .library(
            name: "WinkCore",
            targets: ["WinkCore"]),
    ],
    dependencies: [
        .package(path: "../WinkAutomationKit"),
        .package(path: "../WinkFoundation"),
        .package(path: "../WinkProtocols"),
        .package(path: "../WinkExternalDependencies"),
        .package(path: "../WinkVisualizer"),
        .package(path: "../../Tachikoma"),
        // Pin swift-sdk#276's capability decoder until it is included in a tagged SDK.
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            revision: "f7077e0d5cd57e0b2a497862017aa94ee344252f"),
        .package(url: "https://github.com/apple/swift-configuration", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "WinkAutomation",
            dependencies: [
                .product(name: "WinkVisualizer", package: "WinkVisualizer"),
                .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkProtocols", package: "WinkProtocols"),
                .product(name: "WinkExternalDependencies", package: "WinkExternalDependencies"),
                .product(name: "Tachikoma", package: "Tachikoma"),
                .product(name: "TachikomaAudio", package: "Tachikoma"),
                .product(name: "TachikomaMCP", package: "Tachikoma"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            path: "Sources/WinkAutomation",
            exclude: [
                "Services/README.md",
            ],
            swiftSettings: coreTargetSettings),
        .target(
            name: "WinkAgentRuntimeTestSupport",
            dependencies: [
                "WinkAgentRuntime",
                "WinkAutomation",
                "WinkCore",
                .product(name: "WinkFoundationTestSupport", package: "WinkFoundation"),
                .product(name: "Tachikoma", package: "Tachikoma"),
            ],
            path: "Sources/WinkAgentRuntimeTestSupport",
            swiftSettings: approachableConcurrencySettings),
        .testTarget(
            name: "WinkAutomationTests",
            dependencies: [
                "WinkAutomation",
                "WinkCore",
                "WinkBridgeTestSupport",
                .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
                .product(name: "WinkFoundation", package: "WinkFoundation"),
            ],
            path: "Tests/WinkAutomationTests",
            swiftSettings: testTargetSettings),
        .target(
            name: "WinkBridge",
            dependencies: [
                .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
                .product(name: "WinkFoundation", package: "WinkFoundation"),
            ],
            path: "Sources/WinkBridge",
            swiftSettings: coreTargetSettings,
            linkerSettings: [.linkedLibrary("bsm")]),
        .testTarget(
            name: "WinkBridgeTests",
            dependencies: [
                "WinkBridge",
                "WinkBridgeTestSupport",
                .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
                .product(name: "WinkFoundation", package: "WinkFoundation"),
            ],
            path: "Tests/WinkBridgeTests",
            swiftSettings: testTargetSettings),
        .target(
            name: "WinkBridgeTestSupport",
            dependencies: [
                .target(name: "WinkBridge"),
                .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
                .product(name: "WinkAutomationKitTestSupport", package: "WinkAutomationKit"),
                .product(name: "WinkFoundation", package: "WinkFoundation"),
            ],
            path: "Sources/WinkBridgeTestSupport",
            swiftSettings: approachableConcurrencySettings),
        .target(
            name: "WinkAgentRuntime",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .target(name: "WinkAutomation"),
                .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
                .product(name: "WinkVisualizer", package: "WinkVisualizer"),
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkProtocols", package: "WinkProtocols"),
                .product(name: "WinkExternalDependencies", package: "WinkExternalDependencies"),
                .product(name: "Tachikoma", package: "Tachikoma"),
                .product(name: "TachikomaMCP", package: "Tachikoma"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            path: "Sources/WinkAgentRuntime",
            exclude: [
                "Agent/Tools/README.md",
            ],
            swiftSettings: coreTargetSettings),
        .testTarget(
            name: "WinkAgentRuntimeTests",
            dependencies: [
                "WinkAgentRuntime",
                "WinkAgentRuntimeTestSupport",
                "WinkCore",
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkFoundationTestSupport", package: "WinkFoundation"),
                .product(name: "WinkAutomationKitTestSupport", package: "WinkAutomationKit"),
            ],
            path: "Tests/WinkAgentRuntimeTests",
            swiftSettings: testTargetSettings),
        .target(
            name: "WinkCore",
            dependencies: [
                .target(name: "WinkAutomation"),
                .target(name: "WinkAgentRuntime"),
                .target(name: "WinkBridge"),
                .product(name: "WinkVisualizer", package: "WinkVisualizer"),
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkProtocols", package: "WinkProtocols"),
                .product(name: "WinkExternalDependencies", package: "WinkExternalDependencies"),
                .product(name: "Tachikoma", package: "Tachikoma"),
                .product(name: "TachikomaMCP", package: "Tachikoma"),
                .product(name: "TachikomaAudio", package: "Tachikoma"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            exclude: [
                "README.md",
            ],
            swiftSettings: coreTargetSettings),
        .testTarget(
            name: "WinkTests",
            dependencies: [
                "WinkCore",
                "WinkAgentRuntimeTestSupport",
                "WinkAutomation",
                "WinkAgentRuntime",
                .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
                .product(name: "WinkVisualizer", package: "WinkVisualizer"),
                "WinkFoundation",
                .product(name: "WinkFoundationTestSupport", package: "WinkFoundation"),
                "WinkProtocols",
                "WinkBridgeTestSupport",
                .product(name: "WinkAutomationKitTestSupport", package: "WinkAutomationKit"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: testTargetSettings),
    ],
    swiftLanguageModes: [.v6])
