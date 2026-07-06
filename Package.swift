// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceVault",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "VoiceVaultCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "VoiceVault",
            dependencies: ["VoiceVaultCore"]
        ),
        .executableTarget(
            name: "vvspike",
            dependencies: ["VoiceVaultCore"],
            path: "Sources/vvspike"
        ),
        .testTarget(
            name: "VoiceVaultCoreTests",
            dependencies: ["VoiceVaultCore"]
        ),
    ]
)
