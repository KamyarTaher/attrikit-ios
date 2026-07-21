// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AttrKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AttrKitCore", targets: ["AttrKitCore"]),
        .library(name: "AttrKitLinkToken", targets: ["AttrKitLinkToken"]),
    ],
    targets: [
        .target(
            name: "AttrKitCore",
            resources: [.process("Resources")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "AttrKitLinkToken",
            dependencies: ["AttrKitCore"],
            resources: [.process("Resources")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AttrKitCoreTests",
            dependencies: ["AttrKitCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AttrKitLinkTokenTests",
            dependencies: ["AttrKitCore", "AttrKitLinkToken"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
