// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AttriKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AttriKitCore", targets: ["AttriKitCore"]),
        .library(name: "AttriKitTracking", targets: ["AttriKitTracking"]),
        .library(name: "AttriKitLinkToken", targets: ["AttriKitLinkToken"]),
    ],
    targets: [
        .target(
            name: "AttriKitCore",
            resources: [.process("Resources")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "AttriKitTracking",
            dependencies: ["AttriKitCore"],
            resources: [.process("Resources")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "AttriKitLinkToken",
            dependencies: ["AttriKitCore"],
            resources: [.process("Resources")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AttriKitCoreTests",
            dependencies: ["AttriKitCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AttriKitTrackingTests",
            dependencies: ["AttriKitCore", "AttriKitTracking"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AttriKitLinkTokenTests",
            dependencies: ["AttriKitCore", "AttriKitLinkToken"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
