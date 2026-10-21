// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PeekabooComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "peekaboo-cua", targets: ["PeekabooCUA"]),
    ],
    targets: [
        .executableTarget(
            name: "PeekabooCUA",
            path: "Sources/PeekabooCUA",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
