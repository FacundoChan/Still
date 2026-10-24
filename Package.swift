// swift-tools-version: 6.2
import PackageDescription

// StillCore as a Swift package, for the iOS app (Still-iOS). The Mac app still builds the same sources as a
// framework from project.yml, so both apps render with one copy of the pipeline.
let package = Package(
    name: "StillCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "StillCore", targets: ["StillCore"]),
    ],
    targets: [
        .target(name: "StillCore", path: "StillCore"),
        // Finds the test videos through #filePath, so it runs on a Mac or a simulator, not on a device.
        .testTarget(name: "StillCoreTests", dependencies: ["StillCore"], path: "StillCoreTests"),
    ]
)
