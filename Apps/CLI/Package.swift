// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let infoPlistPath = ProcessInfo.processInfo.environment["WINK_CLI_INFO_PLIST_PATH"] ??
    packageDirectory.appendingPathComponent("Sources/Resources/Info.plist").path

let concurrencyBaseSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableExperimentalFeature("RetroactiveConformances"),
]

let cliConcurrencySettings = concurrencyBaseSettings + [
    .defaultIsolation(MainActor.self),
]

let swiftTestingSettings = cliConcurrencySettings + [
    .enableExperimentalFeature("SwiftTesting"),
]

let includeAutomationTests = ProcessInfo.processInfo.environment["WINK_INCLUDE_AUTOMATION_TESTS"] == "true"

var targets: [Target] = [
    .target(
        name: "WinkCLI",
        dependencies: [
            .product(name: "Commander", package: "Commander"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Spinner", package: "Spinner"),
            .product(name: "TauTUI", package: "TauTUI"),
            .product(name: "WinkCore", package: "WinkCore"),
            .product(name: "WinkBridge", package: "WinkCore"),
            .product(name: "WinkVisualizer", package: "WinkVisualizer"),
            .product(name: "Tachikoma", package: "Tachikoma"),
            .product(name: "TachikomaMCP", package: "Tachikoma"),
            .product(name: "Swiftdansi", package: "Swiftdansi"),
        ],
        path: "Sources/WinkCLI",
        swiftSettings: cliConcurrencySettings),
    .executableTarget(
        name: "WinkExec",
        dependencies: [
            "WinkCLI",
        ],
        path: "Sources/WinkExec",
        swiftSettings: cliConcurrencySettings,
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", infoPlistPath,
                // Ensure LC_UUID is generated for macOS 26 compatibility
                "-Xlinker", "-random_uuid",
            ]),
        ]),
    .executableTarget(
        name: "WinkCertificationController",
        dependencies: [
            .product(name: "WinkBridge", package: "WinkCore"),
            .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
            .product(name: "WinkFoundation", package: "WinkFoundation"),
        ],
        path: "Sources/WinkCertificationController",
        swiftSettings: concurrencyBaseSettings,
        linkerSettings: [
            .linkedFramework("Security"),
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", infoPlistPath,
                "-Xlinker", "-random_uuid",
            ]),
        ]),
    .testTarget(
        name: "CoreCLITests",
        dependencies: [
            "WinkCLI",
            .product(name: "WinkAgentRuntimeTestSupport", package: "WinkCore"),
            .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
            .product(name: "WinkBridgeTestSupport", package: "WinkCore"),
            .product(name: "WinkAutomationKitTestSupport", package: "WinkAutomationKit"),
            .product(name: "WinkFoundation", package: "WinkFoundation"),
            .product(name: "WinkFoundationTestSupport", package: "WinkFoundation"),
            .product(name: "WinkAutomation", package: "WinkCore"),
            .product(name: "WinkAgentRuntime", package: "WinkCore"),
            .product(name: "WinkBridge", package: "WinkCore"),
            .product(name: "WinkCore", package: "WinkCore"),
        ],
        path: "Tests/CoreCLITests",
        resources: [
            .copy("Fixtures"),
        ],
        swiftSettings: swiftTestingSettings),
    .testTarget(
        name: "CLIRuntimeTests",
        dependencies: [
            "WinkCLI",
            .product(name: "WinkBridgeTestSupport", package: "WinkCore"),
            .product(name: "WinkFoundation", package: "WinkFoundation"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ],
        path: "Tests/CLIRuntimeTests",
        swiftSettings: swiftTestingSettings),
    .testTarget(
        name: "CertificationControllerTests",
        dependencies: [
            "WinkCertificationController",
            .product(name: "WinkAutomationKit", package: "WinkAutomationKit"),
            .product(name: "WinkFoundation", package: "WinkFoundation"),
        ],
        path: "Tests/CertificationControllerTests",
        swiftSettings: swiftTestingSettings),
]

if includeAutomationTests {
    targets.append(
        .testTarget(
            name: "CLIAutomationTests",
            dependencies: [
                "WinkCLI",
                .product(name: "WinkAutomationKitTestSupport", package: "WinkAutomationKit"),
                .product(name: "WinkFoundation", package: "WinkFoundation"),
                .product(name: "WinkFoundationTestSupport", package: "WinkFoundation"),
                .product(name: "WinkCore", package: "WinkCore"),
                .product(name: "WinkAgentRuntime", package: "WinkCore"),
                .product(name: "WinkAutomation", package: "WinkCore"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Swiftdansi", package: "Swiftdansi"),
            ],
            path: "Tests/CLIAutomationTests",
            resources: [
                .process("__snapshots__"),
            ],
            swiftSettings: swiftTestingSettings)
    )
}



// Xcode derives intermediate paths from the package and executable product names.
// Keep this project distinct from Wink.xcodeproj even on case-insensitive volumes.
let package = Package(
    name: "WinkCLIPackage",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "wink",
            targets: ["WinkExec"]),
        .executable(
            name: "wink-certification-controller",
            targets: ["WinkCertificationController"]),
    ],
    dependencies: [
        .package(path: "../../Commander"),
        // Pin swift-sdk#276's capability decoder until it is included in a tagged SDK.
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            revision: "f7077e0d5cd57e0b2a497862017aa94ee344252f"),
        .package(url: "https://github.com/dominicegginton/Spinner", from: "2.2.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
        .package(path: "../../TauTUI"),
        .package(path: "../../Core/WinkFoundation"),
        .package(path: "../../Core/WinkAutomationKit"),
        .package(path: "../../Core/WinkVisualizer"),
        .package(path: "../../Core/WinkCore"),
        .package(path: "../../Tachikoma"),
        .package(path: "../../Swiftdansi"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6])
