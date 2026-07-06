// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenXE",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "OpenXECore"),
        .executableTarget(name: "OpenXE", dependencies: ["OpenXECore"]),
        .testTarget(name: "OpenXECoreTests", dependencies: ["OpenXECore"]),
    ]
)
