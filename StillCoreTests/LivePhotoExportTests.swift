import CoreMedia
import Foundation
import Testing
@testable import StillCore

/// Goal A inner loop: export each fixture and check the pair without touching the Photos library.
@Suite("Live Photo export", .serialized)
struct LivePhotoExportTests {
    @Test(arguments: Fixture.goalA.filter(\.isAvailable))
    func exportsRecognizedLivePhoto(_ fixture: Fixture) async throws {
        try #require(
            FileManager.default.fileExists(atPath: fixture.url.path),
            "Missing \(fixture.url.path). Run Scripts/make-fixtures.sh, or add the real clip."
        )
        let source = try await SourceMedia.load(fixture.url)
        let plan = EditPlan.centered(start: fixture.selectionStart, duration: 3)

        let directory = Fixture.outputDirectory(for: fixture.name)
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")

        let frame = plan.frameDuration.seconds
        #expect(pair.keyPhotoTime == plan.keyPhotoFrameTime)
        #expect(pair.pixelSize == fixture.expectedSize)
        #expect(pair.hasAudio == fixture.hasAudio)

        let inspection = try await LivePhotoInspector.inspect(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(inspection.identifiersMatch, "image \(String(describing: inspection.imageContentIdentifier)) vs movie \(String(describing: inspection.videoContentIdentifier))")
        #expect(inspection.imageContentIdentifier == pair.contentIdentifier)
        let stillImageTime = try #require(inspection.stillImageTime, "No still-image-time marker in the movie")
        #expect(abs(stillImageTime.seconds - plan.keyPhotoFrameTime.seconds) < 1e-3)
        #expect(abs(inspection.videoDuration.seconds - 3) <= frame)
        #expect(inspection.videoFrameCount == 90)
        #expect(inspection.videoCodec == kCMVideoCodecType_HEVC)
        #expect(inspection.videoPixelSize == fixture.expectedSize)
        #expect(inspection.imagePixelSize == fixture.expectedSize)
        #expect(inspection.hasAudio == fixture.hasAudio)

        let pairing = await LivePhotoInspector.checkPairing(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(pairing == .paired)
    }

    /// Negative control: the pairing check must reject an image and movie whose identifiers differ,
    /// otherwise a passing check proves nothing.
    @Test func pairingCheckRejectsMismatchedIdentifiers() async throws {
        let fixture = Fixture.goalA[0]
        let source = try await SourceMedia.load(fixture.url)
        let plan = EditPlan.centered(start: 1, duration: 3)
        let directory = Fixture.outputDirectory(for: "mismatch-check")
        try? FileManager.default.removeItem(at: directory)
        let first = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "First")
        let second = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "Second")
        #expect(first.contentIdentifier != second.contentIdentifier)

        let pairing = await LivePhotoInspector.checkPairing(imageURL: first.imageURL, videoURL: second.videoURL)
        #expect(pairing != .paired, "Photos paired files with different content identifiers")
    }

    @Test func refusesToOverwriteExistingFiles() async throws {
        let fixture = Fixture.goalA[0]
        let source = try await SourceMedia.load(fixture.url)
        let plan = EditPlan.centered(start: 1, duration: 3)
        let directory = Fixture.outputDirectory(for: "overwrite-check")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appending(path: "LivePhoto.MOV")
        try Data("keep me".utf8).write(to: existing)

        await #expect(throws: LivePhotoExportError.self) {
            try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")
        }
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "LivePhoto.JPG").path))
    }

    @Test func rejectsPlansOutsideTheProductRange() async throws {
        let fixture = Fixture.goalA[0]
        let source = try await SourceMedia.load(fixture.url)
        let directory = Fixture.outputDirectory(for: "invalid-plan")
        await #expect(throws: LivePhotoExportError.self) {
            try await LivePhotoExporter().export(.centered(start: 0, duration: 0.5), source: source, to: directory, baseName: "LivePhoto")
        }
    }
}
