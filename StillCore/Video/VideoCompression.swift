import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// The facts about a video that compressing it depends on.
public struct CompressionSource: Sendable, Equatable {
    /// Seconds.
    public var duration: Double
    /// Pixel size as displayed, after the track’s rotation.
    public var orientedSize: CGSize
    /// The frames per second the video reaches. A screen recording or other variable-rate video averages well below
    /// the rate it reaches while things move, so this is that higher rate when it differs much from the average.
    public var frameRate: Double
    /// HLG, HDR10 or Dolby Vision video.
    public var isHDR: Bool
    /// The sound the copy can keep; nil for a silent video.
    public var audio: Audio?
    /// The video track’s average bit rate, in bits per second.
    public var videoBitRate: Double
    /// The file’s size in bytes, which the copy is compared with.
    public var fileSize: Int64
    /// Where the video was taken, if it recorded that.
    public var location: CaptureLocation?

    public struct Audio: Sendable, Equatable {
        /// AAC goes into the copy as it is; anything else, such as a Live Photo’s PCM, is encoded as AAC.
        public var isAAC: Bool
        public var channelCount: Int
        public var sampleRate: Double
        /// Bits per second, as stored.
        public var bitRate: Double

        public init(isAAC: Bool, channelCount: Int, sampleRate: Double, bitRate: Double) {
            self.isAAC = isAAC
            self.channelCount = channelCount
            self.sampleRate = sampleRate
            self.bitRate = bitRate
        }

        /// AAC at 64 kbit/s a channel, mono or stereo, for sound that isn’t AAC already.
        var encodedChannelCount: Int { min(max(channelCount, 1), 2) }
        var encodedBitRate: Int { 64_000 * encodedChannelCount }
        /// AAC encodes up to 48 kHz.
        var encodedSampleRate: Double { min(sampleRate > 0 ? sampleRate : 44_100, 48_000) }

        /// What the copy’s sound takes, in bits per second.
        var outputBitRate: Double { isAAC ? bitRate : Double(encodedBitRate) }
    }

    public init(duration: Double, orientedSize: CGSize, frameRate: Double, isHDR: Bool = false, audio: Audio? = nil,
                videoBitRate: Double = 0, fileSize: Int64 = 0, location: CaptureLocation? = nil) {
        self.duration = duration
        self.orientedSize = orientedSize
        self.frameRate = frameRate
        self.isHDR = isHDR
        self.audio = audio
        self.videoBitRate = videoBitRate
        self.fileSize = fileSize
        self.location = location
    }

    /// The original’s frame rate in whole frames, as the choices show it: 30 for 29.97.
    public var wholeFrameRate: Int32 { Int32(max(1, frameRate.rounded())) }

    /// The average rate, or the shortest frame’s rate where that is much higher, up to 240 fps.
    static func frameRate(nominal: Double, shortestFrame: Double) -> Double {
        let peak = shortestFrame > 0 ? min(1 / shortestFrame, 240) : 0
        return peak > nominal * 1.25 ? peak : nominal
    }
}

extension SourceMedia {
    /// What compressing this video depends on, read from its tracks and file.
    public func compressionSource() async throws -> CompressionSource {
        let (shortestFrame, videoRate) = try await videoTrack.load(.minFrameDuration, .estimatedDataRate)
        var audio: CompressionSource.Audio?
        if let audioTrack {
            let (formats, rate) = try await audioTrack.load(.formatDescriptions, .estimatedDataRate)
            let description = formats.first?.audioStreamBasicDescription
            audio = CompressionSource.Audio(
                isAAC: formats.first?.mediaSubType.rawValue == kAudioFormatMPEG4AAC,
                channelCount: Int(description?.mChannelsPerFrame ?? 2),
                sampleRate: description?.mSampleRate ?? 44_100,
                bitRate: Double(rate)
            )
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        return CompressionSource(
            duration: duration.seconds,
            orientedSize: orientedSize,
            frameRate: CompressionSource.frameRate(nominal: Double(nominalFrameRate), shortestFrame: shortestFrame.seconds),
            isHDR: isHDR,
            audio: audio,
            videoBitRate: Double(videoRate),
            fileSize: Int64(fileSize),
            location: capture.location
        )
    }
}

extension VideoBitRate {
    /// Bits per pixel per frame for a compressed copy of a whole video, in HEVC. A Live Photo is a few seconds long, so
    /// its rates aim for detail; these aim lower, as a camera does: iPhone records 4K at 60 fps in about 0.11 bits per
    /// pixel, between Standard and High here.
    public var compressionBitsPerPixel: Double {
        switch self {
        case .low: 0.05
        case .standard: 0.08
        case .high: 0.12
        case .veryHigh: 0.18
        }
    }
}

/// The choices for a smaller, or differently encoded, copy of a whole video, and the rules for them.
///
/// A value type, as `EditState` is: each change gives a complete new value.
public struct VideoCompression: Sendable, Equatable {
    /// The rates offered below the original’s.
    public static let frameRates: [Int32] = [24, 30, 60]
    /// H.264 needs about half as many bits again as HEVC for the same picture.
    static let h264BitRateFactor = 1.5

    public let source: CompressionSource
    /// The remembered resolution; `shownResolution` is the one the copy gets.
    public private(set) var resolution: OutputResolution = .fullHD
    public private(set) var bitRate: VideoBitRate = .standard
    /// The rate chosen below the original’s; nil keeps the original’s, frame for frame.
    public private(set) var frameRateLimit: Int32?
    /// HEVC, as iPhone records; H.264 for players that can’t play HEVC.
    public private(set) var codec: OutputSettings.VideoCodec = .hevc
    /// Whether an HDR video stays HDR. HDR needs HEVC, so H.264 copies are standard range whatever this says.
    public private(set) var keepsHDR = true
    public private(set) var includesAudio: Bool
    /// Off unless the user turns it on: a location is personal.
    public private(set) var includesLocation = false

    public init(source: CompressionSource) {
        self.source = source
        includesAudio = source.audio != nil
    }

    // MARK: - Derived values

    public var outputGeometry: OutputGeometry {
        OutputGeometry(orientedSize: source.orientedSize, crop: CropGeometry.fullFrame, maxLongEdge: resolution.maxLongEdge)
    }

    public var renderSize: CGSize { outputGeometry.renderSize }

    /// The output size `resolution` would give.
    public func renderSize(at resolution: OutputResolution) -> CGSize {
        OutputGeometry(orientedSize: source.orientedSize, crop: CropGeometry.fullFrame, maxLongEdge: resolution.maxLongEdge).renderSize
    }

    /// The choice shown as chosen: the smallest that gives the copy’s size, as in the Live Photo editor.
    public var shownResolution: OutputResolution? {
        OutputResolution.allCases
            .sorted { $0.maxLongEdge < $1.maxLongEdge }
            .first { renderSize(at: $0) == renderSize }
    }

    /// A resolution is unavailable when it gives the same size as a smaller one, because the video isn’t larger.
    public func isResolutionAvailable(_ candidate: OutputResolution) -> Bool {
        let size = renderSize(at: candidate)
        return !OutputResolution.allCases.contains { $0.maxLongEdge < candidate.maxLongEdge && renderSize(at: $0) == size }
    }

    /// The rates below the original’s that can be chosen, fastest first. The original’s own is always available too.
    public var lowerFrameRates: [Int32] {
        Self.frameRates.filter { Double($0) < source.frameRate * 0.97 }.reversed()
    }

    /// Whether the copy keeps the original’s frames and their timing.
    public var keepsOriginalFrameRate: Bool { frameRateLimit == nil }

    /// Frames per second in the copy, in whole frames.
    public var frameRate: Int32 { frameRateLimit ?? source.wholeFrameRate }

    public var canUseHDR: Bool { source.isHDR }

    /// HDR is HEVC only, as on iPhone, where Most Compatible records without it.
    public var canKeepHDR: Bool { source.isHDR && codec == .hevc }

    public var isHDR: Bool { keepsHDR && canKeepHDR }

    public var canIncludeAudio: Bool { source.audio != nil }

    public var canIncludeLocation: Bool { source.location != nil }

    /// What the copy is rendered with.
    public var output: OutputSettings {
        OutputSettings(
            frameRate: frameRate,
            maxLongEdge: resolution.maxLongEdge,
            durationRange: 0...max(source.duration, 1),
            videoCodec: codec,
            bitsPerPixel: bitsPerPixel(at: bitRate),
            dynamicRange: isHDR ? .high : .standard
        )
    }

    private func bitsPerPixel(at bitRate: VideoBitRate) -> Double {
        bitRate.compressionBitsPerPixel * (codec == .h264 ? Self.h264BitRateFactor : 1)
    }

    /// The video’s average bit rate, in bits per second, at `bitRate` and the copy’s size and frame rate.
    public func videoBitRate(at bitRate: VideoBitRate) -> Int {
        var settings = output
        settings.bitsPerPixel = bitsPerPixel(at: bitRate)
        return settings.averageVideoBitRate(for: renderSize)
    }

    /// The whole video, from `start`, with the copy’s settings. A plan’s other parts don’t apply to a plain video.
    public func plan(duration: CMTime, start: CMTime = .zero) -> EditPlan {
        EditPlan(
            selection: CMTimeRange(start: start, duration: duration),
            keyPhotoSourceTime: start,
            includesAudio: includesAudio,
            output: output,
            location: includesLocation ? source.location : nil
        )
    }

    /// About how many bytes the copy takes: the video at its average bit rate, and the sound.
    ///
    /// The bit rate is the encoder’s target: simple footage leaves much of it unused. `calibration`, measured from
    /// pieces of this video rendered with these settings, says how much.
    public func estimatedFileSize(calibration: SizeCalibration?) -> Int64 {
        let pixels = Double(renderSize.width * renderSize.height)
        var videoBits = Double(output.averageVideoBitRate(for: renderSize)) * source.duration
        if let calibration, calibration.pixelCount > 0 {
            videoBits *= SizeCalibration.rateFactor(calibration.videoRateFactor, scaledBy: max(pixels / calibration.pixelCount, 1))
        }
        let audioBits = includesAudio ? (source.audio?.outputBitRate ?? 0) * source.duration : 0
        return Int64((videoBits + audioBits) / 8)
    }

    // MARK: - Choices

    public mutating func setResolution(_ resolution: OutputResolution) {
        self.resolution = resolution
    }

    public mutating func setBitRate(_ bitRate: VideoBitRate) {
        self.bitRate = bitRate
    }

    /// Nil, or a rate that isn’t below the original’s, keeps the original’s.
    public mutating func setFrameRate(_ rate: Int32?) {
        frameRateLimit = rate.flatMap { lowerFrameRates.contains($0) ? $0 : nil }
    }

    /// Remembered from an earlier video: the fastest rate offered here up to `rate`, or the original’s when it isn’t
    /// faster.
    public mutating func limitFrameRate(to rate: Int32) {
        guard Double(rate) < source.frameRate * 0.97 else { return setFrameRate(nil) }
        setFrameRate(lowerFrameRates.first { $0 <= rate } ?? lowerFrameRates.last)
    }

    public mutating func setCodec(_ codec: OutputSettings.VideoCodec) {
        self.codec = codec
    }

    /// Kept while H.264 is chosen, so HDR comes back with HEVC.
    public mutating func setKeepsHDR(_ on: Bool) {
        keepsHDR = on
    }

    /// Ignored for videos without sound.
    public mutating func setIncludesAudio(_ include: Bool) {
        includesAudio = include && canIncludeAudio
    }

    /// Ignored while the video has no location.
    public mutating func setIncludesLocation(_ include: Bool) {
        includesLocation = include && canIncludeLocation
    }
}
