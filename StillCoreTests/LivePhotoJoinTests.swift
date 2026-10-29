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

    /// Pieces dated a second apart make one moment; one dated two minutes later makes its own.
    @Test func momentsFollowTheDates() async throws {
        let source = Fixture.root.appending(path: "Fixtures/synthetic/framecode-30fps-6s.mov")
        try #require(Fixture.isAvailable(source), "Missing \(source.path). Run Scripts/make-fixtures.sh.")
        let directory = try Self.outputDirectory("moments-framecode")
        var shots: [LivePhotoShot] = []
        for (index, (start, second)) in [(3.5, 120), (0, 1), (1.7, 2)].enumerated() {
            let piece = directory.appending(path: "shot-\(index).mov")
            try await Self.cut(source, from: start, duration: 2.5, to: piece, dated: second)
            shots.append(LivePhotoShot(movieURL: piece))
        }
        let moments = try await LivePhotoJoiner.moments(of: shots)
        #expect(moments.map { $0.shots.map(\.movieURL.lastPathComponent) } == [["shot-1.mov", "shot-2.mov"], ["shot-0.mov"]])
    }

    /// Every run is a moment of its own, however they're chosen, and lasts about as long as its joined movie.
    @Test(.enabled(if: realRuns.count > 1))
    func eachRunIsAMoment() async throws {
        let runs = try Self.realRuns.map(Self.shots(inRun:))
        let moments = try await LivePhotoJoiner.moments(of: runs.flatMap(\.self).shuffled())
        let names = { (shots: [LivePhotoShot]) -> [String] in shots.map(\.movieURL.lastPathComponent) }
        let found: [[String]] = moments.map { names($0.shots) }.sorted { $0[0] < $1[0] }
        let expected: [[String]] = runs.map(names).sorted { $0[0] < $1[0] }
        #expect(found == expected)
        let dates = moments.compactMap(\.date)
        #expect(dates.count == moments.count && dates == dates.sorted())
        for (index, moment) in moments.enumerated() {
            let directory = try Self.outputDirectory("moment-\(index)")
            let joined = try await LivePhotoJoiner.join(moment.shots, to: directory.appending(path: "joined.mov"))
            let length = try await SourceMedia.load(joined.url).duration.seconds
            #expect(abs(moment.duration - length) < 0.5, "estimated \(moment.duration) s, joined \(length) s")
        }
    }

    /// Leaving out a shot from the middle of a run leaves a jump of a second or so, which keeps it one moment.
    @Test(arguments: realRuns)
    func aMissingShotKeepsTheMoment(_ run: String) async throws {
        var shots = try Self.shots(inRun: run)
        try #require(shots.count > 2)
        shots.remove(at: 1)
        let moments = try await LivePhotoJoiner.moments(of: shots)
        #expect(moments.count == 1)
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

    /// A run's shots, by file name, which is the order they were taken in.
    static func shots(inRun run: String) throws -> [LivePhotoShot] {
        let folder = Fixture.root.appending(path: "Fixtures/real/live-photos/\(run)")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { movie in
                LivePhotoShot(movieURL: movie, photoURL: files.first {
                    $0.pathExtension.lowercased() == "heic"
                        && $0.deletingPathExtension().lastPathComponent == movie.deletingPathExtension().lastPathComponent
                })
            }
    }

    @Test(arguments: realRuns)
    func joinsARunOfLivePhotos(_ run: String) async throws {
        let shots = try Self.shots(inRun: run)
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

        // The sound blends at each seam rather than jumping, so none clicks, and lasts exactly as long as the picture.
        let sound = try #require(try await MediaProbe.audio(joined.url, sampleRate: 48_000))
        let picture = try await result.videoTrack.load(.timeRange).duration.seconds
        #expect(abs(sound.duration - picture) < 0.002, "sound \(sound.duration) s, picture \(picture) s")
        let seams = try await result.videoTrack.load(.segments).map(\.timeMapping.target.start.seconds).filter { $0 > 0 }
        #expect(seams.count == shots.count - 1)
        for seam in seams {
            let jump = Self.stepAtSeam(sound, seam)
            #expect(jump < 2.5, "the sound at \(seam) s steps \(jump) times the loudest steps around it")
        }
    }

    /// The biggest sample-to-sample step within 2 ms of `seam`, against the loudest 1% of steps in the 50 ms around
    /// it. A click stands four to nine times above them; a clean join, about level.
    private static func stepAtSeam(_ sound: MediaProbe.Audio, _ seam: Double) -> Float {
        let samples = sound.samples
        let center = Int(((seam - sound.startTime) * sound.sampleRate).rounded())
        let near = Int(0.002 * sound.sampleRate), around = Int(0.05 * sound.sampleRate)
        guard center - around > 0, center + around < samples.count else { return 0 }
        let step = { (index: Int) in abs(samples[index] - samples[index - 1]) }
        let biggest = ((center - near)...(center + near)).map(step).max() ?? 0
        let nearby = ((center - around)..<(center + around)).filter { abs($0 - center) > near }.map(step).sorted()
        return biggest / max(nearby[nearby.count * 99 / 100], 1e-6)
    }

    // MARK: - Helpers

    static func outputDirectory(_ name: String) throws -> URL {
        let directory = Fixture.outputDirectory(for: name)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Re-encodes part of a movie into a file of its own, which starts at zero, like a Live Photo's movie, dated
    /// `second` seconds into a minute.
    static func cut(_ source: URL, from start: Double, duration: Double, to destination: URL, dated second: Int) async throws {
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
