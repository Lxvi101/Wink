// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinkComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "wink-cua", targets: ["WinkCUA"]),
        .library(name: "WinkWorkflowKit", targets: ["WinkWorkflowKit"]),
    ],
    targets: [
        // Foundation-only workflow/feedback core: models, validation, selector resolution over normalized
        // observations, the deterministic runner, compiler, private storage. No AppKit/AX, no WinkCore.
        .target(
            name: "WinkWorkflowKit",
            path: "Sources/WinkWorkflowKit",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "WinkCUA",
            dependencies: ["WinkWorkflowKit"],
            path: "Sources/WinkCUA",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "WinkWorkflowKitTests",
            dependencies: ["WinkWorkflowKit"],
            path: "Tests/WinkWorkflowKitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
