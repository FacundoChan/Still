import Accelerate
import AVFoundation
import CoreMedia
import ImageIO

/// A Live Photo to join with others: its movie, and the photo that says when it was taken.
public struct LivePhotoShot: Sendable {
    public var movieURL: URL
    /// Without the photo, the movie's own date, to the second, stands in for it.
    public var photoURL: URL?

    public init(movieURL: URL, photoURL: URL? = nil) {
        self.movieURL = movieURL
        self.photoURL = photoURL
    }
}

/// The movie joined from Live Photos taken one after another.
public struct LivePhotoJoin: Sendable {
    public let url: URL
    /// The shots in the order they play.
    public let shots: [LivePhotoShot]
    /// How each shot runs into the next, in the order they play.
    public let seams: [LivePhotoSeam]
}

/// How one shot's movie runs into the next one's.
public enum LivePhotoSeam: Sendable, Equatable {
    /// The movies share frames, and the join falls on one of them.
    case matched
    /// The photos' times say the movies overlap, but no frames matched, so the join follows the times.
    case estimated
    /// The movies don't overlap: one ends, and the next begins.
    case cut
}

public enum LivePhotoJoinError: Error, LocalizedError {
    case notEnoughShots
    case differentFraming
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .notEnoughShots:
            String(localized: "Choose at least two Live Photos to join.", bundle: #bundle)
        case .differentFraming:
            String(localized: "These Live Photos can’t be joined, because iPhone wasn’t held the same way for all of them.", bundle: #bundle)
        case .exportFailed:
            String(localized: "The Live Photos couldn’t be joined.", bundle: #bundle)
        }
    }
}

/// Joins the movies of Live Photos taken one after another into one movie, as Photos plays them when the first is
/// pressed and held.
///
/// Each movie runs about a second and a half either side of its photo, so shots taken a second or two apart share
/// frames. The photos' times say roughly where the next movie starts, to about a tenth of a second; matching small
/// copies of the frames finds exactly where. The join falls on a frame both movies have, half-way through their
/// overlap, so picture and sound run on unbroken. Shots that don't overlap simply follow one another.
///
/// The movies are joined as they are, without re-encoding.
public enum LivePhotoJoiner {
    public static func join(_ shots: [LivePhotoShot], to destination: URL) async throws -> LivePhotoJoin {
        guard shots.count > 1 else { throw LivePhotoJoinError.notEnoughShots }
        // A few at a time: each decodes its whole movie, and a phone has only so many decoders.
        var loaded = try await withThrowingTaskGroup(of: (Int, Shot).self) { group in
            var results: [(Int, Shot)] = []
            var next = 0
            func loadNext() {
                guard next < shots.count else { return }
                let (index, shot) = (next, shots[next])
                group.addTask { (index, try await Shot.load(shot)) }
                next += 1
            }
            for _ in 0..<simultaneousLoads { loadNext() }
            for try await result in group {
                results.append(result)
                loadNext()
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // The order they were taken in, when each says when; otherwise the order they were chosen in.
        if loaded.allSatisfy({ $0.start != nil }) {
            loaded = loaded.enumerated().sorted { ($0.element.start!, $0.offset) < ($1.element.start!, $1.offset) }.map(\.element)
        }
        let first = loaded[0].source
        guard loaded.allSatisfy({
            $0.source.naturalSize == first.naturalSize && $0.source.preferredTransform == first.preferredTransform
        }) else {
            throw LivePhotoJoinError.differentFraming
        }

        // Each shot plays from its in-point to the next one's cut, on its own clock.
        var seams: [LivePhotoSeam] = []
        var segments: [CMTimeRange] = []
        var inPoint = loaded[0].videoRange.start
        for (shot, next) in zip(loaded, loaded.dropFirst()) {
            let join = cut(from: shot, playingFrom: inPoint, into: next)
            seams.append(join.seam)
            segments.append(CMTimeRange(start: inPoint, end: join.out))
            inPoint = join.in
        }
        segments.append(CMTimeRange(start: inPoint, end: loaded[loaded.count - 1].videoRange.end))
        try Task.checkCancellation()

        let composition = try compose(loaded, segments: segments)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw LivePhotoJoinError.exportFailed
        }
        session.metadata = try await metadata(for: loaded[0])
        try await session.export(to: destination, as: .mov)
        withExtendedLifetime(loaded) {}
        return LivePhotoJoin(url: destination, shots: loaded.map(\.shot), seams: seams)
    }

    private static let simultaneousLoads = 3

    // MARK: - Lining up

    /// How near the photos' times put the next movie: Exif keeps milliseconds, a movie's date only seconds.
    private static let preciseWindow = 0.4
    private static let roughWindow = 1.5
    /// Matched frames differ by 0–3 (out of 255) where the camera styled the two movies differently, and by far more
    /// where they don't show the same moment.
    private static let matchLimit: Float = 6

    /// Where `shot` stops and `next` takes over, each on its own clock.
    private static func cut(
        from shot: Shot, playingFrom inPoint: CMTime, into next: Shot
    ) -> (seam: LivePhotoSeam, out: CMTime, in: CMTime) {
        let estimate = next.start.flatMap { nextStart in shot.start.map { nextStart.timeIntervalSince($0) } }
        let isPrecise = shot.startIsPrecise && next.startIsPrecise
        let window = isPrecise ? preciseWindow : roughWindow
        let end = shot.videoRange.end.seconds
        if let estimate, estimate > end + window {
            return (.cut, shot.videoRange.end, next.videoRange.start)
        }

        // Where the next movie starts on this one's clock.
        let offset: Double
        let seam: LivePhotoSeam
        // A movie's date, unlike a photo's, can be well off, as on one another app saved again; then the frames decide
        // alone. Searching every offset could pair different moments of a still scene, so a photo's time keeps it near.
        if let matched = matchedOffset(of: next, on: shot, near: estimate, within: window)
            ?? (isPrecise ? nil : matchedOffset(of: next, on: shot, near: nil, within: window)) {
            (offset, seam) = (matched, .matched)
        } else if let estimate, estimate < end {
            (offset, seam) = (estimate, .estimated)
        } else {
            return (.cut, shot.videoRange.end, next.videoRange.start)
        }

        // Half-way through what both show, on a frame of this movie and the next movie's frame at the same moment.
        let middle = (max(offset, inPoint.seconds) + end) / 2
        guard let out = shot.frames.first(where: { $0.seconds >= middle && $0.time > inPoint }),
              let into = next.frame(nearest: out.seconds - offset)
        else {
            return (.cut, shot.videoRange.end, next.videoRange.start)
        }
        return (seam, out.time, into.time)
    }

    /// Where `next` starts on `shot`'s clock, at the offset where their frames look most alike; nil when none match.
    private static func matchedOffset(of next: Shot, on shot: Shot, near estimate: Double?, within window: Double) -> Double? {
        let range = estimate.map { ($0 - window)...($0 + window) } ?? 0...shot.videoRange.end.seconds
        // Shared frames line up exactly, so the candidates are the offsets that put a frame of one on a frame of the
        // other, to the millisecond.
        var candidates = Set<Int>()
        for frame in shot.frames {
            for other in next.frames where range.contains(frame.seconds - other.seconds) {
                candidates.insert(Int(((frame.seconds - other.seconds) * 1000).rounded()))
            }
        }
        var best: (offset: Double, difference: Float)?
        for candidate in candidates {
            let offset = Double(candidate) / 1000
            if let difference = difference(of: next, on: shot, at: offset), difference < best?.difference ?? .infinity {
                best = (offset, difference)
            }
        }
        guard let best, best.difference < matchLimit else { return nil }
        return best.offset
    }

    /// How much `next`'s frames differ from `shot`'s at the same moments, on average, with `next` starting at
    /// `offset` on `shot`'s clock; nil when fewer than three frames fall together.
    private static func difference(of next: Shot, on shot: Shot, at offset: Double) -> Float? {
        var total: Float = 0
        var count = 0
        for frame in next.frames {
            let time = frame.seconds + offset
            guard let other = shot.frame(nearest: time), abs(other.seconds - time) < 0.012 else { continue }
            total += vDSP.meanMagnitude(vDSP.subtract(frame.pixels, other.pixels))
            count += 1
        }
        return count >= 3 ? total / Float(count) : nil
    }

    // MARK: - Joining

    private static func compose(_ shots: [Shot], segments: [CMTimeRange]) throws -> AVComposition {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderPipelineError.compositionTrackUnavailable
        }
        video.preferredTransform = shots[0].source.preferredTransform
        let audio = shots.contains { $0.source.audioTrack != nil }
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil
        var cursor = CMTime.zero
        for (shot, segment) in zip(shots, segments) where segment.duration > .zero {
            try video.insertTimeRange(segment, of: shot.source.videoTrack, at: cursor)
            // The sound can end a moment before the picture.
            if let audio, let track = shot.source.audioTrack {
                let range = segment.intersection(shot.audioRange)
                if range.duration > .zero {
                    try audio.insertTimeRange(range, of: track, at: cursor + (range.start - segment.start))
                }
            }
            cursor = cursor + segment.duration
        }
        return composition
    }

    /// The first shot's camera and place, and when its first frame was taken, to the millisecond.
    private static func metadata(for first: Shot) async throws -> [AVMetadataItem] {
        let kept: Set<AVMetadataIdentifier> = [
            .quickTimeMetadataMake, .quickTimeMetadataModel, .quickTimeMetadataSoftware,
            .quickTimeMetadataLocationISO6709,
            AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.location.accuracy.horizontal"),
        ]
        var items = try await first.source.asset.load(.metadata).filter { $0.identifier.map(kept.contains) ?? false }
        if let start = first.start {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = first.source.capture.timeZoneOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.apple.quicktime.creationdate" as NSString
            item.value = formatter.string(from: start) as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }
        return items
    }
}

/// One shot, read: its movie, when the movie starts, and small copies of its frames to line it up by.
///
/// `@unchecked` for the same reason as `SourceMedia`.
private struct Shot: @unchecked Sendable {
    struct Frame {
        let time: CMTime
        let seconds: Double
        /// Brightness at 48 pixels across, less its average, so a movie styled a little lighter still matches.
        let pixels: [Float]
    }

    let shot: LivePhotoShot
    let source: SourceMedia
    let videoRange: CMTimeRange
    let audioRange: CMTimeRange
    /// When the movie's first frame was taken.
    let start: Date?
    /// Whether `start` comes from the photo, to the millisecond, rather than the movie's date, to the second.
    let startIsPrecise: Bool
    /// In time order.
    let frames: [Frame]

    static func load(_ shot: LivePhotoShot) async throws -> Shot {
        let source = try await SourceMedia.load(shot.movieURL)
        let videoRange = try await source.videoTrack.load(.timeRange)
        let audioRange = try await source.audioTrack?.load(.timeRange) ?? .zero
        // A Live Photo's movie marks where its photo was taken.
        let still = try await LivePhotoInspector.stillImageTime(in: source.asset)?.seconds ?? 0
        let photoDate = shot.photoURL.flatMap { photoDate(at: $0, fallbackOffset: source.capture.timeZoneOffset) }
        return Shot(
            shot: shot,
            source: source,
            videoRange: videoRange,
            audioRange: audioRange,
            start: (photoDate ?? source.capture.date)?.addingTimeInterval(-still),
            startIsPrecise: photoDate != nil,
            frames: try smallFrames(of: source)
        )
    }

    /// The frame shown nearest `seconds`.
    func frame(nearest seconds: Double) -> Frame? {
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].seconds < seconds { low = middle + 1 } else { high = middle }
        }
        return [low - 1, low].filter(frames.indices.contains).map { frames[$0] }
            .min { abs($0.seconds - seconds) < abs($1.seconds - seconds) }
    }

    /// When the photo was taken, from its Exif date and fraction of a second.
    private static func photoDate(at url: URL, fallbackOffset: Int?) -> Date? {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = fallbackOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var date = formatter.date(from: text)
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            date = formatter.date(from: text + offset) ?? date
        }
        if let subsec = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String, let fraction = Double("0." + subsec) {
            date = date?.addingTimeInterval(fraction)
        }
        return date
    }

    private static func smallFrames(of source: SourceMedia) throws -> [Frame] {
        let reader = try AVAssetReader(asset: source.asset)
        let output = AVAssetReaderTrackOutput(track: source.videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LivePhotoJoinError.exportFailed }
        var frames: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = sample.imageBuffer else { continue }
            let time = sample.presentationTimeStamp
            frames.append(Frame(time: time, seconds: time.seconds, pixels: smallLuma(of: image)))
        }
        if reader.status == .failed { throw reader.error ?? LivePhotoJoinError.exportFailed }
        return frames.sorted { $0.time < $1.time }
    }

    private static func smallLuma(of image: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        var source = vImage_Buffer(
            data: CVPixelBufferGetBaseAddressOfPlane(image, 0),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        )
        let smallWidth = 48
        let smallHeight = max(1, Int((Double(smallWidth * height) / Double(width)).rounded()))
        var bytes = [UInt8](repeating: 0, count: smallWidth * smallHeight)
        bytes.withUnsafeMutableBytes { buffer in
            var small = vImage_Buffer(
                data: buffer.baseAddress, height: vImagePixelCount(smallHeight),
                width: vImagePixelCount(smallWidth), rowBytes: smallWidth
            )
            vImageScale_Planar8(&source, &small, nil, vImage_Flags(kvImageNoFlags))
        }
        let pixels = vDSP.integerToFloatingPoint(bytes, floatingPointType: Float.self)
        return vDSP.add(-vDSP.mean(pixels), pixels)
    }
}
