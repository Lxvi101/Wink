// swift-tools-version: 6.2
import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "WinkTestHost",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "WinkTestHost",
            targets: ["WinkTestHost"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "WinkTestHost",
            path: ".",
            sources: ["TestHostApp.swift", "ContentView.swift"],
            swiftSettings: approachableConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
