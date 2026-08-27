// swift-tools-version:5.9
//
// SwiftPM manifest for command-line builds (no Xcode required).
// The Xcode project (project.yml / Chat42.xcodeproj) is still the source
// of truth for IDE work; this manifest only drives `swift build` so that
// build.sh can assemble Chat42.app using just the Command Line Tools.
//
// Resources (Info.plist, Assets.xcassets, *.lproj, entitlements) are NOT
// declared here — they are copied into the .app bundle by build.sh, which
// also converts AppIcon.appiconset to AppIcon.icns via iconutil (a CLT tool).
//
// Compiler settings must stay in step with project.yml's `settings.base`, or the
// two build paths disagree about what compiles: strict concurrency was previously
// enabled only in Xcode, so a `swift build` could pass on code the IDE rejected.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "Chat42",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Chat42", targets: ["Chat42"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.1")
    ],
    targets: [
        .executableTarget(
            name: "Chat42",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples")
            ],
            path: "Chat42/Sources",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "Chat42Tests",
            dependencies: ["Chat42"],
            path: "Tests/Chat42Tests",
            swiftSettings: swiftSettings
        )
    ]
)
