import Foundation
import Synchronization
import Testing
@testable import StillCore

/// Cancelled or failed exports leave nothing that looks like a finished Live Photo,
/// and progress moves through the documented stages.
@Suite("Export recovery", .serialized)
struct ExportRecoveryTests {
    private static let fixture = Fixture.goalA[0]

    /// Five seconds of output at 0.5×: long enough to cancel partway through.
    private static let slowPlan = EditPlan.centered(start: 0.5, duration: 2.5, speed: 0.5)

    @Test func reportsStagesInOrder() async throws {
        let source = try await SourceMedia.load(Self.fixture.url)
        let directory = Fixture.outputDirectory(for: "recovery/stages")
        try? FileManager.default.removeItem(at: directory)
        let stages = Mutex<[LivePhotoExportStage]>([])

        let pair = try await LivePhotoExporter().export(
            .centered(start: 1, duration: 3), source: source, to: directory, baseName: "LivePhoto",
            verifiesPairing: true
        ) { stage in stages.withLock { $0.append(stage) } }

        let reported = stages.withLock { $0 }
        #expect(reported.first == .preparing)
        #expect(reported.last == .creatingLivePhoto)
        let fractions = reported.compactMap { stage -> Double? in
            if case let .rendering(value) = stage { value } else { nil }
        }
        #expect(!fractions.isEmpty)
        #expect(fractions == fractions.sorted(), "Rendering progress went backwards")
        #expect(fractions.last == 1)
        #expect(FileManager.default.fileExists(atPath: pair.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: pair.videoURL.path))
    }

    @Test func cancellingMidRenderRemovesEverything() async throws {
        let source = try await SourceMedia.load(Self.fixture.url)
        let plan = Self.slowPlan
        let directory = Fixture.outputDirectory(for: "recovery/cancel-mid-render")
        try? FileManager.default.removeItem(at: directory)

        let rendered = Mutex(0.0)
        let task = Task {
            try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto") { stage in
                if case let .rendering(fraction) = stage { rendered.withLock { $0 = fraction } }
            }
        }
        // Cancel a third of the way through, while the movie is partly written.
        while rendered.withLock({ $0 }) < 1.0 / 3 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let movieExisted = FileManager.default.fileExists(atPath: directory.appending(path: "LivePhoto.MOV").path)
        let cancelledAt = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let latency = ContinuousClock.now - cancelledAt
        #expect(rendered.withLock { $0 } < 1, "Rendering kept going after Cancel")
        #expect(latency < .milliseconds(300), "Cancelling took \(latency)")
        #expect(movieExisted, "Nothing had been written yet, so the cleanup went untested")
        #expect(!FileManager.default.fileExists(atPath: directory.path), "Cancelled export left \(directory.lastPathComponent)")
    }

    @Test func cancellingBeforeRenderingRemovesEverything() async throws {
        let source = try await SourceMedia.load(Self.fixture.url)
        let directory = Fixture.outputDirectory(for: "recovery/cancel-early")
        try? FileManager.default.removeItem(at: directory)

        let task = Task {
            try await LivePhotoExporter().export(.centered(start: 1, duration: 3), source: source, to: directory, baseName: "LivePhoto")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func keepsADirectoryItDidNotCreate() async throws {
        let source = try await SourceMedia.load(Self.fixture.url)
        let directory = Fixture.outputDirectory(for: "recovery/existing-directory")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = directory.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: unrelated)

        let task = Task {
            try await LivePhotoExporter().export(.centered(start: 1, duration: 3), source: source, to: directory, baseName: "LivePhoto")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: unrelated) == Data("keep me".utf8))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents == ["notes.txt"])
    }

    @Test func deliversBothFilesIntoANewFolder() async throws {
        let source = try await SourceMedia.load(Self.fixture.url)
        let root = Fixture.outputDirectory(for: "recovery/deliver")
        try? FileManager.default.removeItem(at: root)
        let staged = try await LivePhotoExporter().export(
            .centered(start: 1, duration: 3), source: source, to: root.appending(path: "staging"), baseName: "Beach"
        )
        let folder = root.appending(path: "Beach")

        let delivered = try LivePhotoExporter().deliver(staged, toNewFolder: folder)

        #expect(delivered.imageURL == folder.appending(path: "Beach.JPG"))
        #expect(delivered.videoURL == folder.appending(path: "Beach.MOV"))
        #expect(delivered.contentIdentifier == staged.contentIdentifier)
        #expect(!FileManager.default.fileExists(atPath: staged.imageURL.path))
        #expect(!FileManager.default.fileExists(atPath: staged.videoURL.path))
        let pairing = await LivePhotoInspector.checkPairing(imageURL: delivered.imageURL, videoURL: delivered.videoURL)
        #expect(pairing == .paired)
    }

    @Test func deliveryRefusesAnExistingFolder() async throws {
        let source = try await SourceMedia.load(Self.fixture.url)
        let root = Fixture.outputDirectory(for: "recovery/deliver-existing")
        try? FileManager.default.removeItem(at: root)
        let staged = try await LivePhotoExporter().export(
            .centered(start: 1, duration: 3), source: source, to: root.appending(path: "staging"), baseName: "Beach"
        )
        let folder = root.appending(path: "Beach")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unrelated = folder.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: unrelated)

        #expect(throws: LivePhotoExportError.self) {
            try LivePhotoExporter().deliver(staged, toNewFolder: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["notes.txt"])
        // The staged pair is still there, so the caller can deliver it somewhere else.
        #expect(FileManager.default.fileExists(atPath: staged.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: staged.videoURL.path))
    }
}
