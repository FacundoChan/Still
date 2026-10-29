import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Testing
@testable import StillCore

/// Live Photos saved as a plain video, as Photos' Save as Video does: the motion as it is, with its sound, dated and
/// placed as the first Live Photo was.
@Suite("Live Photos as a video", .serialized)
struct LivePhotoVideoTests {
    /// A piece of the flash-and-beep clip, standing in for a Live Photo's movie, keeps its pictures, its sound in step
    /// with them, and its date.
    @Test func oneMovieKeepsItsPicturesAndSound() async throws {
        let source = Fixture.root.appending(path: "Fixtures/synthetic/av-sync-30fps-8s.mov")
        try #require(Fixture.isAvailable(source), "Missing \(source.path). Run Scripts/make-fixtures.sh.")
        let directory = try LivePhotoJoinTests.outputDirectory("video-av-sync")
        let piece = directory.appending(path: "piece.mov")
        try await LivePhotoJoinTests.cut(source, from: 0.5, duration: 2.5, to: piece, dated: 7)

        let video = try await LivePhotoJoiner.video(of: [LivePhotoShot(movieURL: piece)], to: directory.appending(path: "video.mov"))

        let movie = try await SourceMedia.load(piece)
        #expect(video.duration == (try await movie.videoTrack.load(.timeRange).duration))
        #expect(video.size == movie.orientedSize)
        #expect(try await Self.encodedFrames(video.url) == Self.encodedFrames(piece))
        // The flashes and beeps, at the start of each of the clip's seconds, fall where they did.
        #expect(try await MediaProbe.flashOnsets(video.url) == MediaProbe.flashOnsets(piece))
        let sound = try #require(try await MediaProbe.audio(video.url))
        let original = try #require(try await MediaProbe.audio(piece))
        let beeps = MediaProbe.beepOnsets(sound), originalBeeps = MediaProbe.beepOnsets(original)
        #expect(beeps.count == 2 && beeps.count == originalBeeps.count)
        for (beep, originalBeep) in zip(beeps, originalBeeps) {
            #expect(abs(beep - originalBeep) < 0.001, "beep at \(beep) s, was at \(originalBeep) s")
        }
        #expect(try await Self.isPlainVideo(video.url))
        // Without a photo, the movie's own date, to the second, is when it starts.
        let date = try #require(video.date)
        #expect(date == movie.capture.date)
        #expect(try await SourceMedia.load(video.url).capture.date == date)
    }

    /// Movies that don't say where they were taken make a video that doesn't either; several are joined.
    @Test func joinedMoviesStartWithTheFirst() async throws {
        let source = Fixture.root.appending(path: "Fixtures/synthetic/framecode-30fps-6s.mov")
        try #require(Fixture.isAvailable(source), "Missing \(source.path). Run Scripts/make-fixtures.sh.")
        let directory = try LivePhotoJoinTests.outputDirectory("video-framecode")
        var shots: [LivePhotoShot] = []
        for (index, start) in [3.5, 0, 1.7].enumerated() {
            let piece = directory.appending(path: "shot-\(index).mov")
            try await LivePhotoJoinTests.cut(source, from: start, duration: 2.5, to: piece, dated: Int(start + 1.25))
            shots.append(LivePhotoShot(movieURL: piece))
        }

        let video = try await LivePhotoJoiner.video(of: shots, to: directory.appending(path: "video.mov"))

        #expect(video.shots.map(\.movieURL.lastPathComponent) == ["shot-1.mov", "shot-2.mov", "shot-0.mov"])
        #expect(abs(video.duration.seconds - 6) < 0.001)
        #expect(!video.hasAudio && video.location == nil)
        let frames = try await MediaProbe.movieFrames(video.url, at: Array(0..<180))
        #expect((0..<180).map { frames[Int64($0)].map(MediaProbe.frameCode) } == (0..<180).map { $0 })
        #expect(video.date == (try await SourceMedia.load(shots[1].movieURL).capture.date))
    }

    /// One iPhone Live Photo: its movie's frames and sound unchanged, without the rest of what a Live Photo's movie
    /// holds, dated when its first frame was taken, to the millisecond, and placed where it was taken.
    @Test(arguments: LivePhotoJoinTests.realRuns)
    func oneLivePhotoIsItsMotion(_ run: String) async throws {
        let shot = try LivePhotoJoinTests.shots(inRun: run)[0]
        let directory = try LivePhotoJoinTests.outputDirectory("video-one-\(run)")

        let video = try await LivePhotoJoiner.video(of: [shot], to: directory.appending(path: "video.mov"))

        let movie = try await SourceMedia.load(shot.movieURL)
        let result = try await SourceMedia.load(video.url)
        #expect(video.duration == (try await movie.videoTrack.load(.timeRange).duration))
        #expect(result.naturalSize == movie.naturalSize && result.preferredTransform == movie.preferredTransform)
        #expect(video.isHDR == movie.isHDR)
        #expect(try await Self.encodedFrames(video.url) == Self.encodedFrames(shot.movieURL))

        // The recording itself, in step with the pictures, then quiet to the last frame.
        #expect(video.hasAudio)
        let sound = try #require(try await MediaProbe.audio(video.url, sampleRate: 48_000))
        let original = try #require(try await MediaProbe.audio(shot.movieURL, sampleRate: 48_000))
        #expect(abs(sound.duration - video.duration.seconds) < 0.002, "sound \(sound.duration) s, picture \(video.duration.seconds) s")
        let shift = Int(((original.startTime - sound.startTime) * 48_000).rounded())
        let shared = max(0, -shift)..<min(original.samples.count, sound.samples.count - shift)
        try #require(shared.count > 48_000)
        let difference = shared.map { abs(sound.samples[$0 + shift] - original.samples[$0]) }.max() ?? 0
        #expect(difference < 1e-4)
        #expect(original.samples.map(abs).max() ?? 0 > 0.001, "the Live Photo is silent")

        #expect(try await Self.isPlainVideo(video.url))
        #expect(try await !Self.isPlainVideo(shot.movieURL))
        let expectedDate = try #require(try await Self.firstFrameDate(of: shot))
        let date = try #require(video.date)
        #expect(abs(date.timeIntervalSince(expectedDate)) < 0.001)
        #expect(abs(try #require(result.capture.date).timeIntervalSince(date)) < 0.001)
        try Self.expectPhotosPlace(video.location, of: shot, movie: movie.capture.location)
        #expect(result.capture.location == movie.capture.location)
        #expect(result.capture.model == movie.capture.model)
    }

    /// A run of iPhone Live Photos: one video as long as the moment, every frame one of the movies' own, in the order
    /// they were taken, with sound throughout, dated and placed as the first.
    @Test(arguments: LivePhotoJoinTests.realRuns)
    func aRunIsOneVideo(_ run: String) async throws {
        let shots = try LivePhotoJoinTests.shots(inRun: run)
        let moments = try await LivePhotoJoiner.moments(of: shots)
        let moment = try #require(moments.first)
        try #require(moments.count == 1)
        let directory = try LivePhotoJoinTests.outputDirectory("video-run-\(run)")

        let video = try await LivePhotoJoiner.video(of: moment.shots, to: directory.appending(path: "video.mov"))

        #expect(video.shots.map(\.movieURL) == shots.map(\.movieURL))
        #expect(abs(video.duration.seconds - moment.duration) < 0.5, "estimated \(moment.duration) s, made \(video.duration.seconds) s")
        let movies = try await shots.asyncMap { try await Self.encodedFrames($0.movieURL) }
        var place = (movie: 0, frame: -1)
        for (index, frame) in try await Self.encodedFrames(video.url).enumerated() {
            let later = movies[place.movie].indices.dropFirst(place.frame + 1).first { movies[place.movie][$0] == frame }
                .map { (place.movie, $0) }
                ?? (place.movie + 1..<movies.count).lazy.compactMap { movie in movies[movie].firstIndex(of: frame).map { (movie, $0) } }.first
            let found = try #require(later, "frame \(index) isn't one of the movies' own, after frame \(place.frame) of movie \(place.movie)")
            place = (found.0, found.1)
        }
        #expect(place.movie == shots.count - 1)

        let sound = try #require(try await MediaProbe.audio(video.url, sampleRate: 48_000))
        #expect(abs(sound.duration - video.duration.seconds) < 0.002)
        #expect(try await Self.isPlainVideo(video.url))
        let expectedDate = try #require(try await Self.firstFrameDate(of: shots[0]))
        #expect(abs(try #require(video.date).timeIntervalSince(expectedDate)) < 0.001)
        let first = try await SourceMedia.load(shots[0].movieURL)
        try Self.expectPhotosPlace(video.location, of: shots[0], movie: first.capture.location)
        #expect(try await SourceMedia.load(video.url).capture.location == first.capture.location)
    }

    // MARK: - Helpers

    /// The photo's own place, as its GPS tags have it, which the movie keeps to four places.
    static func expectPhotosPlace(_ location: CaptureLocation?, of shot: LivePhotoShot, movie: CaptureLocation?) throws {
        let photo = try #require(shot.photoURL)
        let image = try #require(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        let gps = try #require(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        let location = try #require(location)
        let movie = try #require(movie)
        // Hong Kong, north and east.
        #expect(location.latitude == gps[kCGImagePropertyGPSLatitude] as? Double)
        #expect(location.longitude == gps[kCGImagePropertyGPSLongitude] as? Double)
        #expect(location.altitude == gps[kCGImagePropertyGPSAltitude] as? Double)
        #expect(location.horizontalAccuracy == gps[kCGImagePropertyGPSHPositioningError] as? Double)
        #expect(abs(location.latitude - movie.latitude) < 0.0001 && abs(location.longitude - movie.longitude) < 0.0001)
    }

    /// The movie's pictures as stored, frame by frame, in decoding order.
    static func encodedFrames(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            frames.append(data)
        }
        #expect(reader.status == .completed && !frames.isEmpty)
        return frames
    }

    /// Pictures and sound alone, without a Live Photo's identifier, still-image marker or other tracks, so Photos
    /// takes it for a video of its own.
    static func isPlainVideo(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let kinds = try await asset.load(.tracks).map(\.mediaType)
        let identifiers = try await asset.load(.metadata).compactMap(\.identifier)
        return kinds.filter { $0 != .audio } == [.video] && kinds.filter { $0 == .audio }.count <= 1
            && !identifiers.contains(.quickTimeMetadataContentIdentifier)
    }

    /// When a Live Photo's movie starts: its photo's time, to the millisecond, less where the photo falls in the movie.
    static func firstFrameDate(of shot: LivePhotoShot) async throws -> Date? {
        guard let photo = shot.photoURL, let image = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
              let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
              let subsec = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String, let fraction = Double("0." + subsec)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        guard let taken = formatter.date(from: text + offset),
              let still = try await LivePhotoInspector.stillImageTime(in: AVURLAsset(url: shot.movieURL))
        else { return nil }
        return taken.addingTimeInterval(fraction - still.seconds)
    }
}

private extension Array where Element: Sendable {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
