import Foundation
import Testing

/// Test media in `Fixtures/`. Synthetic files come from `Scripts/make-fixtures.sh`;
/// real files are iPhone recordings, kept out of the repository.
struct Fixture: Sendable, CustomTestStringConvertible {
    enum Kind: String, Sendable { case real, synthetic }

    let name: String
    let kind: Kind
    /// Pixel size the export should have after orientation and the 1920-pixel cap.
    let expectedSize: CGSize
    let hasAudio: Bool
    /// Where the three-second test selection starts, in source seconds.
    let selectionStart: Double

    var url: URL {
        Self.root.appending(path: "Fixtures/\(kind.rawValue)/\(name)")
    }

    var testDescription: String { name }

    /// The iPhone clips aren't in the repository (they carry location metadata), so tests that need them run
    /// only where they exist; CI runs the synthetic cases.
    var isAvailable: Bool { Self.isAvailable(url) }

    static func isAvailable(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Scratch output for one fixture, kept after the run so the files can be inspected.
    static func outputDirectory(for name: String) -> URL {
        // Colons (as in “9:16”) aren't allowed in uploaded CI artifacts.
        root.appending(path: "build/test-output/\(name.replacingOccurrences(of: ":", with: "-"))")
    }
}

extension Fixture {
    static let portrait = CGSize(width: 1080, height: 1920)
    static let landscape = CGSize(width: 1920, height: 1080)

    /// Landscape, portrait, rotated, silent, and HDR sources.
    static let goalA: [Fixture] = [
        Fixture(name: "landscape-sdr-30fps-6s.mov", kind: .synthetic, expectedSize: landscape, hasAudio: true, selectionStart: 1),
        Fixture(name: "silent-landscape-30fps-4s.mov", kind: .synthetic, expectedSize: landscape, hasAudio: false, selectionStart: 0.5),
        Fixture(name: "rotated-portrait-sdr-30fps-5s.mov", kind: .synthetic, expectedSize: portrait, hasAudio: true, selectionStart: 1),
        Fixture(name: "portrait-sdr-h264-30fps-4.8s.mov", kind: .real, expectedSize: portrait, hasAudio: true, selectionStart: 1),
        Fixture(name: "portrait-hdr-dolbyvision-60fps-3.3s.mov", kind: .real, expectedSize: portrait, hasAudio: true, selectionStart: 0.15),
        Fixture(name: "portrait-hdr-dolbyvision-59.94fps-5.1s.mov", kind: .real, expectedSize: portrait, hasAudio: true, selectionStart: 1),
    ]

    /// HDR sources: a synthetic HLG clip and the Dolby Vision iPhone clips where present.
    static let hdr: [Fixture] = [
        Fixture(name: "hdr-hlg-landscape-30fps-4s.mov", kind: .synthetic, expectedSize: landscape, hasAudio: true, selectionStart: 0.5),
        Fixture(name: "portrait-hdr-dolbyvision-60fps-3.3s.mov", kind: .real, expectedSize: portrait, hasAudio: true, selectionStart: 0.15),
        Fixture(name: "portrait-hdr-dolbyvision-59.94fps-5.1s.mov", kind: .real, expectedSize: portrait, hasAudio: true, selectionStart: 1),
    ]

    /// 4K sources, with their size at the 4K output resolution.
    static let uhd: [Fixture] = [
        Fixture(name: "uhd-landscape-30fps-4s.mov", kind: .synthetic, expectedSize: CGSize(width: 3840, height: 2160), hasAudio: true, selectionStart: 0.5),
        Fixture(name: "portrait-hdr-dolbyvision-59.94fps-5.1s.mov", kind: .real, expectedSize: CGSize(width: 2160, height: 3840), hasAudio: true, selectionStart: 1),
    ]
}
