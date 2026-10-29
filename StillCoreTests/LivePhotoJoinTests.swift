import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import StillCore

/// Live Photos taken one after another share frames; joined, each moment plays once.
@Suite("Joining Live Photos", .serialized)
struct LivePhotoJoinTests {
    /// The frame-coded clip cut into three overlapping “Live Photos”, joined back frame for frame.
    @Test func joinsOverlappingMoviesFrameForFrame() async throws {
        let source = Fixture.root.appending(path: "Fixtures/synthetic/framecode-30fps-6s.mov")
        try #require(Fixture.isAvailable(source), "Missing \(source.path). Run Scripts/make-fixtures.sh.")
        let directory = try Self.outputDirectory("join-framecode")

        // 2.5 seconds each, overlapping the next by 0.8 and 0.7 seconds, and chosen out of order. With no photos, only
        // the movies' dates order them: the whole second of their middle, as a Live Photo's movie has its photo's.
        var shots: [LivePhotoShot] = []
        for (index, start) in [3.5, 0, 1.7].enumerated() {
            let piece = directory.appending(path: "shot-\(index).mov")
            try await Self.cut(source, from: start, duration: 2.5, to: piece, dated: Int(start + 1.25))
            shots.append(LivePhotoShot(movieURL: piece))
        }
        let joined = try await LivePhotoJoiner.join(shots, to: directory.appending(path: "joined.mov"))

        #expect(joined.seams == [.matched, .matched])
        let frames = try await MediaProbe.movieFrames(joined.url, at: Array(0..<180))
        let codes = (0..<180).map { frames[Int64($0)].map(MediaProbe.frameCode) }
        #expect(codes == (0..<180).map { $0 })
    }

    @Test func needsTwoShots() async throws {
        let source = Fixture.root.appending(path: "Fixtures/synthetic/framecode-30fps-6s.mov")
        await #expect(throws: LivePhotoJoinError.self) {
            try await LivePhotoJoiner.join([LivePhotoShot(movieURL: source)], to: source.deletingLastPathComponent())
        }
    }

    /// Runs of iPhone Live Photos, each in `Fixtures/real/live-photos/<run>/` as its photos' HEIC and MOV files.
    /// They carry location metadata, so they stay out of the repository, and the test runs only where they are.
    static let realRuns: [String] = {
        let folder = Fixture.root.appending(path: "Fixtures/real/live-photos")
        let runs = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return runs.filter { !$0.hasPrefix(".") }.sorted()
    }()

    @Test(arguments: realRuns)
    func joinsARunOfLivePhotos(_ run: String) async throws {
        let folder = Fixture.root.appending(path: "Fixtures/real/live-photos/\(run)")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let shots = files.filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { movie in
                LivePhotoShot(movieURL: movie, photoURL: files.first {
                    $0.pathExtension.lowercased() == "heic"
                        && $0.deletingPathExtension().lastPathComponent == movie.deletingPathExtension().lastPathComponent
                })
            }
        try #require(shots.count > 1)

        // Chosen in reverse; the photos' times put them back in order.
        let directory = try Self.outputDirectory("join-\(run)")
        let joined = try await LivePhotoJoiner.join(shots.reversed(), to: directory.appending(path: "joined.mov"))
        #expect(joined.seams.allSatisfy { $0 == .matched }, "\(joined.seams)")

        let result = try await SourceMedia.load(joined.url)
        let first = try await SourceMedia.load(shots[0].movieURL)
        let last = try await SourceMedia.load(shots[shots.count - 1].movieURL)
        #expect(result.naturalSize == first.naturalSize)
        #expect(result.preferredTransform == first.preferredTransform)
        #expect(result.audioTrack != nil)
        #expect(result.capture.model == first.capture.model)
        #expect(result.capture.location == first.capture.location)
        // Starts when the first movie does, a moment before its photo's whole second.
        let start = try #require(result.capture.date)
        let firstDate = try #require(first.capture.date)
        #expect(start < firstDate.addingTimeInterval(1) && start > firstDate.addingTimeInterval(-3))
        // Longer than any one shot, shorter than all of them end to end.
        let total = try await shots.asyncMap { try await SourceMedia.load($0.movieURL).duration.seconds }.reduce(0, +)
        #expect(result.duration.seconds > last.duration.seconds && result.duration.seconds < total)
    }

    // MARK: - Helpers

    private static func outputDirectory(_ name: String) throws -> URL {
        let directory = Fixture.outputDirectory(for: name)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Re-encodes part of a movie into a file of its own, which starts at zero, like a Live Photo's movie, dated
    /// `second` seconds into a minute.
    private static func cut(_ source: URL, from start: Double, duration: Double, to destination: URL, dated second: Int) async throws {
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetHighestQuality))
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        duration: CMTime(seconds: duration, preferredTimescale: 600))
        let date = AVMutableMetadataItem()
        date.keySpace = .quickTimeMetadata
        date.key = "com.apple.quicktime.creationdate" as NSString
        date.value = String(format: "2026-10-24T21:17:%02d+0800", second) as NSString
        date.dataType = kCMMetadataBaseDataType_UTF8 as String
        session.metadata = [date]
        try await session.export(to: destination, as: .mov)
    }
}

private extension Array where Element: Sendable {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
