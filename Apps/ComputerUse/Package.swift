// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinkComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "wink-cua", targets: ["WinkCUA"]),
    ],
    targets: [
        .executableTarget(
            name: "WinkCUA",
            path: "Sources/WinkCUA",
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
