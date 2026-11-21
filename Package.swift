// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v26)],
    targets: [
        // Real-time audio code for per-app volume (C: no allocation, locks or ARC on audio threads).
        .target(
            name: "WorkbenchAudioRT",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        .target(name: "WorkbenchCore", dependencies: ["WorkbenchAudioRT"]),
        .executableTarget(
            name: "Workbench",
            dependencies: ["WorkbenchCore"]
        ),
        .testTarget(
            name: "WorkbenchCoreTests",
            dependencies: ["WorkbenchCore", "WorkbenchAudioRT"]
        ),
    ]
)
