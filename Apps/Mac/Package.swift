// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "Wink",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Wink",
            targets: ["Wink"]),
    ],
    dependencies: [
        .package(path: "../../Core/WinkCore"),
        .package(path: "../../Core/WinkUICore"),
        .package(path: "../../Tachikoma"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .target(
            name: "Wink",
            dependencies: [
                .product(name: "WinkCore", package: "WinkCore"),
                .product(name: "WinkUICore", package: "WinkUICore"),
                .product(name: "Tachikoma", package: "Tachikoma"),
                .product(name: "TachikomaAudio", package: "Tachikoma"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Wink",
            exclude: ["WinkApp.swift", "Info.plist", "Wink.entitlements", "Features/StatusBar/README.md"],
            resources: [
                .process("Assets.xcassets"),
            ],
            swiftSettings: approachableConcurrencySettings),
        .testTarget(
            name: "WinkTests",
            dependencies: ["Wink"],
            path: "WinkTests",
            exclude: ["README.md"],
            swiftSettings: approachableConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
