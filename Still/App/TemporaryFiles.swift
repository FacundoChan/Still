import Foundation

/// The app’s scratch folders inside its sandbox temporary directory.
///
/// Each window removes its own files as it goes; launch removes whatever a crash or forced quit left behind.
nonisolated enum TemporaryFiles {
    /// Exports render here before they are handed to Photos or moved into the user’s folder.
    static var exports: URL { root(named: "StillExport") }
    /// Reduced Live Photo renders and retimed preview sound.
    static var previews: URL { root(named: "StillPreview") }
    /// Copies of videos chosen with the Photos picker.
    static var imports: URL { root(named: "StillImports") }
    /// Videos dragged in from Photos.app, received as file promises.
    static var drops: URL { root(named: "StillDrops") }

    /// A new, empty folder for one item under `parent`.
    static func makeItemFolder(in parent: URL) throws -> URL {
        let folder = parent.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes the copy of a video the app made for itself, with its item folder. Leaves the user’s own files alone.
    static func removeImportedCopy(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard [imports, drops].contains(where: { $0.resolvingSymlinksInPath().path == parent }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Clears every scratch folder. Call only at launch, before any window can be using them.
    static func removeAll() {
        for folder in [exports, previews, imports, drops] {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func root(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
    }
}
