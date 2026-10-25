// swift-tools-version: 6.2
import PackageDescription

// StillCore and StillEditor as a Swift package, for the iOS app (Still-iOS). The Mac app still builds the same
// sources as frameworks from project.yml, so both apps render and edit with one copy of the code.
let package = Package(
    name: "StillCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "StillCore", targets: ["StillCore"]),
        .library(name: "StillEditor", targets: ["StillEditor"]),
    ],
    targets: [
        .target(name: "StillCore", path: "StillCore"),
        // The editing session behind a window: undo, playback, previews and export. Main-actor by default, as
        // the Mac app's own code is.
        .target(
            name: "StillEditor",
            dependencies: ["StillCore"],
            path: "StillEditor",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Finds the test videos through #filePath, so it runs on a Mac or a simulator, not on a device.
        .testTarget(name: "StillCoreTests", dependencies: ["StillCore"], path: "StillCoreTests"),
    ]
)
