// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInputCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "VoiceInputCore",
            targets: ["VoiceInputCore"]
        ),
        .executable(
            name: "VoiceInputCoreTestHarness",
            targets: ["VoiceInputCoreTestHarness"]
        ),
    ],
    targets: [
        .target(
            name: "VoiceInputCore",
            path: "Sources/VoiceInputCore"
        ),
        .executableTarget(
            name: "VoiceInputCoreTestHarness",
            dependencies: ["VoiceInputCore"],
            path: "Tests/VoiceInputCoreHarness"
        ),
    ]
)
