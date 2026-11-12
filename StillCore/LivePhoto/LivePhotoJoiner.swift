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
    /// When its first frame was taken, as the movie's creation date says.
    public let date: Date?
}

/// Live Photos taken one after another, held the same way: each one's movie overlaps the one before, or starts a few
/// seconds after it at most.
public struct LivePhotoMoment: Sendable {
    /// In the order they were taken.
    public let shots: [LivePhotoShot]
    /// When the first one's movie starts, as far as the photos or movies say.
    public let date: Date?
    /// About how long their joined movie runs, in seconds.
    public let duration: Double
}

/// Live Photos' motion as a plain video, as Photos' Save as Video makes one.
public struct LivePhotoVideo: Sendable {
    public let url: URL
    /// The shots in the order they play.
    public let shots: [LivePhotoShot]
    public let duration: CMTime
    /// As shown, with the movie's orientation applied.
    public let size: CGSize
    public let hasAudio: Bool
    public let isHDR: Bool
    /// When its first frame was taken.
    public let date: Date?
    /// Where the first shot was taken, as its photo says, which is where Photos puts the Live Photo; otherwise as its
    /// movie says, to four places.
    public let location: CaptureLocation?
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
/// The pictures are joined as they are, without re-encoding. So is the sound, but for a short crossfade at each seam:
/// neighbouring movies hold the same recording but place it 70 to 110 ms apart against their pictures, so sound cut
/// where the pictures join would jump by that much, and click.
public enum LivePhotoJoiner {
    public static func join(_ shots: [LivePhotoShot], to destination: URL) async throws -> LivePhotoJoin {
        guard shots.count > 1 else { throw LivePhotoJoinError.notEnoughShots }
        let loaded = try await inOrder(load(shots, decodingFrames: true))
        guard loaded.allSatisfy({ $0.isFramed(like: loaded[0]) }) else {
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
        let parts = zip(loaded, segments).filter { $0.1.duration > .zero }.map { Part(shot: $0.0, range: $0.1) }
        try Task.checkCancellation()
        try await write(parts, to: destination)
        return LivePhotoJoin(url: destination, shots: loaded.map(\.shot), seams: seams, date: parts[0].shot.start)
    }

    /// Sorts Live Photos into moments, in the order they were taken. A shot belongs to the moment before it when it was
    /// held the same way and its movie starts at most `maximumGap` seconds after the moment's last one ends, as when a
    /// shot in between wasn't chosen; a shot that doesn't say when it was taken is a moment of its own.
    ///
    /// Reads only what the files say about themselves, so it's quick; frames are matched when a moment is joined.
    public static func moments(of shots: [LivePhotoShot]) async throws -> [LivePhotoMoment] {
        var moments: [[Shot]] = []
        var momentEnd: Date?
        for shot in try await inOrder(load(shots, decodingFrames: false)) {
            if let start = shot.start, let end = momentEnd, let last = moments.last?.last, shot.isFramed(like: last),
               start.timeIntervalSince(end) <= maximumGap {
                moments[moments.count - 1].append(shot)
                momentEnd = max(end, shot.end ?? end)
            } else {
                moments.append([shot])
                momentEnd = shot.end
            }
        }
        return moments.map { shots in
            LivePhotoMoment(shots: shots.map(\.shot), date: shots[0].start, duration: duration(of: shots))
        }
    }

    /// The longest a moment skips between one movie's end and the next one's start.
    public static let maximumGap = 3.0

    /// How much later the photos' times put a movie that overlaps the one before than its shared frames do: 0.07 to
    /// 0.12 seconds, measured on an iPhone 17 Pro Max.
    private static let photoTimeLead = 0.1

    /// The time the movies cover between them: what they share plays once, and a gap is cut out.
    private static func duration(of shots: [Shot]) -> Double {
        var total = 0.0
        var coveredUntil: Date?
        for shot in shots {
            guard let start = shot.start, let end = shot.end else {
                total += shot.videoRange.duration.seconds
                continue
            }
            if let coveredUntil, start < coveredUntil {
                total += max(0, end.timeIntervalSince(coveredUntil) - photoTimeLead)
            } else {
                total += end.timeIntervalSince(start)
            }
            coveredUntil = max(coveredUntil ?? end, end)
        }
        return total
    }

    // MARK: - Reading

    /// A few at a time: decoding reads a whole movie, and a phone has only so many decoders.
    private static let simultaneousLoads = 3

    private static func load(_ shots: [LivePhotoShot], decodingFrames: Bool) async throws -> [Shot] {
        try await withThrowingTaskGroup(of: (Int, Shot).self) { group in
            var results: [(Int, Shot)] = []
            var next = 0
            func loadNext() {
                guard next < shots.count else { return }
                let (index, shot) = (next, shots[next])
                group.addTask { (index, try await Shot.load(shot, decodingFrames: decodingFrames)) }
                next += 1
            }
            for _ in 0..<simultaneousLoads { loadNext() }
            for try await result in group {
                results.append(result)
                loadNext()
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The order they were taken in, when each says when; otherwise the order they were chosen in.
    private static func inOrder(_ shots: [Shot]) -> [Shot] {
        guard shots.allSatisfy({ $0.start != nil }) else { return shots }
        return shots.enumerated().sorted { ($0.element.start!, $0.offset) < ($1.element.start!, $1.offset) }.map(\.element)
    }

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

    /// What one shot plays of its movie, on its own clock.
    private struct Part {
        let shot: Shot
        let range: CMTimeRange
    }

    /// The parts' pictures end to end, as they are, with their sound under them, into a movie of those two tracks
    /// alone that has the first part's camera and place, and its starting time.
    private static func write(_ parts: [Part], to destination: URL) async throws {
        let soundURL = URL.temporaryDirectory.appending(path: "StillJoinedSound-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: soundURL) }
        let sound = try await writeSound(of: parts, to: soundURL) ? AVURLAsset(url: soundURL) : nil
        let soundTrack = try await sound?.loadTracks(withMediaType: .audio).first
        let composition = try compose(parts, sound: soundTrack)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw LivePhotoJoinError.exportFailed
        }
        session.metadata = try await metadata(for: parts[0].shot)
        try await session.export(to: destination, as: .mov)
        withExtendedLifetime((parts, sound)) {}
    }

    /// The parts' pictures end to end, with `sound`, already joined, under them.
    private static func compose(_ parts: [Part], sound: AVAssetTrack?) throws -> AVComposition {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderPipelineError.compositionTrackUnavailable
        }
        video.preferredTransform = parts[0].shot.source.preferredTransform
        var cursor = CMTime.zero
        for part in parts {
            try video.insertTimeRange(part.range, of: part.shot.source.videoTrack, at: cursor)
            cursor = cursor + part.range.duration
        }
        if let sound, let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audio.insertTimeRange(CMTimeRange(start: .zero, duration: cursor), of: sound, at: .zero)
        }
        return composition
    }

    // MARK: - Sound

    /// How long each seam's sound blends from one shot into the next.
    static let crossfade = 0.02

    /// Lays the parts' sound end to end as their pictures are, blending each seam over `crossfade` with equal power,
    /// and writes it to `url` as 16-bit PCM, as the movies have it, so all but the seams is the recording itself.
    /// Each shot keeps its sound in step with its pictures. Returns false, writing nothing, when no shot has sound.
    private static func writeSound(of parts: [Part], to url: URL) async throws -> Bool {
        guard let first = parts.lazy.compactMap(\.shot.source.audioTrack).first,
              let description = try await first.load(.formatDescriptions).first?.audioStreamBasicDescription
        else { return false }
        let rate = description.mSampleRate
        // One or two channels, which is all AVAudioFormat's standard layouts allow.
        let channelCount = min(max(Int(description.mChannelsPerFrame), 1), 2)
        let sounds = try await reading { try parts.map { try decodedSound(of: $0.shot, rate: rate, channelCount: channelCount) } }

        // Where each part starts in the output, in frames, and how far its shot's own frames sit from the output's.
        var starts: [Int] = []
        var shifts: [Int] = []
        var cursor = 0.0
        for (part, sound) in zip(parts, sounds) {
            starts.append(Int((cursor * rate).rounded()))
            shifts.append(Int(((part.range.start.seconds - cursor - (sound?.start ?? 0)) * rate).rounded()))
            cursor += part.range.duration.seconds
        }
        let frameCount = Int((cursor * rate).rounded())
        starts.append(frameCount)
        func frame(_ part: Int, _ channel: Int, _ index: Int) -> Float {
            guard let samples = sounds[part]?.channels[channel] else { return 0 }
            let source = index + shifts[part]
            return samples.indices.contains(source) ? samples[source] : 0
        }

        var output = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channelCount)
        for part in parts.indices {
            for channel in 0..<channelCount {
                for index in starts[part]..<starts[part + 1] { output[channel][index] = frame(part, channel, index) }
            }
        }
        // Each seam blends from the shot before, played on past its cut, into the shot after, from before its own.
        let halfFade = Int(crossfade * rate / 2)
        for part in parts.indices.dropFirst() {
            let seam = starts[part]
            let half = min(halfFade, seam - starts[part - 1], starts[part + 1] - seam)
            guard half > 0 else { continue }
            for index in (seam - half)..<(seam + half) {
                let progress = (Float(index - seam + half) + 0.5) / Float(2 * half) * .pi / 2
                for channel in 0..<channelCount {
                    output[channel][index] = frame(part - 1, channel, index) * cos(progress) + frame(part, channel, index) * sin(progress)
                }
            }
        }
        try writePCM(output, rate: rate, to: url)
        return true
    }

    /// One shot's sound at `rate`, one array per channel, and when its first frame plays on the movie's clock; nil
    /// when it has none.
    private static func decodedSound(of shot: Shot, rate: Double, channelCount: Int) throws -> (channels: [[Float]], start: Double)? {
        guard let track = shot.source.audioTrack else { return nil }
        let reader = try AVAssetReader(asset: shot.source.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LivePhotoJoinError.exportFailed }
        var interleaved: [Float] = []
        var start: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            if start == nil { start = sample.presentationTimeStamp.seconds }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            interleaved += chunk
        }
        guard reader.status == .completed else { throw reader.error ?? LivePhotoJoinError.exportFailed }
        let channels = (0..<channelCount).map { channel in
            stride(from: channel, to: interleaved.count, by: channelCount).map { interleaved[$0] }
        }
        return (channels, start ?? 0)
    }

    /// Writes the samples as interleaved 16-bit PCM, which a composition can insert; the file closes on return.
    private static func writePCM(_ channels: [[Float]], rate: Double, to url: URL) throws {
        let frames = channels.first?.count ?? 0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))
        else { throw LivePhotoJoinError.exportFailed }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames) }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
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

    // MARK: - As a video

    /// The motion of one Live Photo, or of several taken one after another joined as `join` joins them, as a plain
    /// video, as Photos' Save as Video makes one: the pictures as they are, and the sound, without the Live Photo's
    /// other tracks and identifier, so Photos keeps it as a video of its own. It has the first shot's camera and
    /// place, and is dated when its first frame was taken.
    public static func video(of shots: [LivePhotoShot], to destination: URL) async throws -> LivePhotoVideo {
        let played: (shots: [LivePhotoShot], date: Date?)
        if shots.count > 1 {
            let join = try await join(shots, to: destination)
            played = (join.shots, join.date)
        } else {
            guard let shot = shots.first else { throw LivePhotoJoinError.notEnoughShots }
            let loaded = try await Shot.load(shot, decodingFrames: false)
            try await write([Part(shot: loaded, range: loaded.videoRange)], to: destination)
            played = ([shot], loaded.start)
        }
        let video = try await SourceMedia.load(destination)
        return LivePhotoVideo(
            url: destination,
            shots: played.shots,
            duration: try await video.videoTrack.load(.timeRange).duration,
            size: video.orientedSize,
            hasAudio: video.audioTrack != nil,
            isHDR: video.isHDR,
            date: played.date,
            location: played.shots[0].photoURL.flatMap(Shot.photoLocation(at:)) ?? video.capture.location
        )
    }
}

/// Runs `read`, which reads a movie sample by sample, on a queue of its own, without holding a Swift concurrency thread
/// while it waits.
///
/// `copyNextSampleBuffer` blocks its thread until each sample is decoded. Swift keeps one thread per core, so three
/// movies read at once on a 3-core Mac, such as a CI runner, would leave it none for anything else.
private func reading<T: Sendable>(_ read: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        readingQueue.async { continuation.resume(with: Result(catching: read)) }
    }
}

private let readingQueue = DispatchQueue(label: "Still.join.reading", attributes: .concurrent)

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
    /// When the movie's first frame was taken.
    let start: Date?
    /// Whether `start` comes from the photo, to the millisecond, rather than the movie's date, to the second.
    let startIsPrecise: Bool
    /// In time order; empty when they weren't asked for.
    let frames: [Frame]

    /// When the movie's last frame ends.
    var end: Date? { start?.addingTimeInterval(videoRange.end.seconds) }

    /// Whether the two were held the same way, at the same size, so their movies can play as one.
    func isFramed(like other: Shot) -> Bool {
        source.naturalSize == other.source.naturalSize && source.preferredTransform == other.source.preferredTransform
    }

    static func load(_ shot: LivePhotoShot, decodingFrames: Bool) async throws -> Shot {
        let source = try await SourceMedia.load(shot.movieURL)
        let videoRange = try await source.videoTrack.load(.timeRange)
        // A Live Photo's movie marks where its photo was taken.
        let still = try await LivePhotoInspector.stillImageTime(in: source.asset)?.seconds ?? 0
        let photoDate = shot.photoURL.flatMap { photoDate(at: $0, fallbackOffset: source.capture.timeZoneOffset) }
        return Shot(
            shot: shot,
            source: source,
            videoRange: videoRange,
            start: (photoDate ?? source.capture.date)?.addingTimeInterval(-still),
            startIsPrecise: photoDate != nil,
            frames: decodingFrames ? try await reading { try smallFrames(of: source) } : []
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

    /// Where the photo was taken, from its GPS tags, which keep more places than a movie's.
    static func photoLocation(at url: URL) -> CaptureLocation? {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }
        var location = CaptureLocation(
            latitude: gps[kCGImagePropertyGPSLatitudeRef] as? String == "S" ? -latitude : latitude,
            longitude: gps[kCGImagePropertyGPSLongitudeRef] as? String == "W" ? -longitude : longitude
        )
        if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
            // A reference of 1 is below sea level.
            location.altitude = gps[kCGImagePropertyGPSAltitudeRef] as? Int == 1 ? -altitude : altitude
        }
        location.horizontalAccuracy = gps[kCGImagePropertyGPSHPositioningError] as? Double
        return location
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
