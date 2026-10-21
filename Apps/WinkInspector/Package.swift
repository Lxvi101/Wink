// swift-tools-version: 6.2
import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "WinkInspector",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "WinkInspector",
            targets: ["WinkInspector"]),
    ],
    dependencies: [
        .package(path: "../../AXorcist"),
        .package(path: "../../Core/WinkCore"),
        .package(path: "../../Core/WinkUICore"),
    ],
    targets: [
        .executableTarget(
            name: "WinkInspector",
            dependencies: [
                .product(name: "AXorcist", package: "AXorcist"),
                .product(name: "WinkCore", package: "WinkCore"),
                .product(name: "WinkUICore", package: "WinkUICore"),
            ],
            path: "Inspector",
            exclude: ["Info.plist", "WinkInspector.entitlements", "AppIcon.icon-source"],
            resources: [
                .process("Assets.xcassets"),
            ],
            swiftSettings: approachableConcurrencySettings),
        .testTarget(
            name: "WinkInspectorTests",
            dependencies: ["WinkInspector"],
            path: "Tests/WinkInspectorTests",
            swiftSettings: approachableConcurrencySettings),
    ])
