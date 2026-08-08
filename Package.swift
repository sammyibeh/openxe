// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenXE",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "OpenXECore"),
        .executableTarget(name: "OpenXE", dependencies: ["OpenXECore"]),
        // Developer tool, never bundled: writes the fixtures
        // scripts/verify-font-batching.sh compares, from the live
        // FontProvisioning table (spec §5.3).
        .executableTarget(name: "openxe-dump-fontcmds", dependencies: ["OpenXECore"]),
        .testTarget(name: "OpenXECoreTests", dependencies: ["OpenXECore"]),
    ]
)
