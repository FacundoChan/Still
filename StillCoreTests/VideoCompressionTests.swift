import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import StillCore

/// Compressed copies of whole videos: the rules for the choices, and what the exporter writes.
@Suite("Video compression", .serialized)
struct VideoCompressionTests {
    // MARK: - Choices

    @Test func frameRatesNeverExceedTheOriginal() {
        let at60 = VideoCompression(source: Self.source(frameRate: 59.94))
        #expect(at60.lowerFrameRates == [30, 24])
        #expect(at60.keepsOriginalFrameRate && at60.frameRate == 60)

        var at30 = VideoCompression(source: Self.source(frameRate: 29.97))
        #expect(at30.lowerFrameRates == [24])
        at30.setFrameRate(60)
        #expect(at30.keepsOriginalFrameRate && at30.frameRate == 30, "60 fps isn't offered for a 30 fps video")
        at30.setFrameRate(24)
        #expect(at30.frameRate == 24 && !at30.keepsOriginalFrameRate)

        #expect(VideoCompression(source: Self.source(frameRate: 23.976)).lowerFrameRates.isEmpty)

        // A rate remembered from another video applies as a limit.
        var remembered = at60
        remembered.limitFrameRate(to: 25)
        #expect(remembered.frameRate == 24)
        remembered.limitFrameRate(to: 120)
        #expect(remembered.keepsOriginalFrameRate)
    }

    /// A screen recording averages a low rate but reaches its full rate while things move; a Live Photo's uneven
    /// frames aren't a higher rate.
    @Test func variableRateVideosOfferTheRateTheyReach() {
        #expect(CompressionSource.frameRate(nominal: 21.5, shortestFrame: 1.0 / 30) == 30)
        #expect(CompressionSource.frameRate(nominal: 26.06, shortestFrame: 0.0367) == 26.06)
        #expect(CompressionSource.frameRate(nominal: 30, shortestFrame: 0.0001) == 240, "Odd timestamps stop at 240 fps")
    }

    @Test func h264CopiesAreStandardRange() {
        var compression = VideoCompression(source: Self.source(frameRate: 30, isHDR: true))
        #expect(compression.isHDR && compression.output.dynamicRange == .high)
        let hevcRate = compression.videoBitRate(at: .standard)
        compression.setCodec(.h264)
        #expect(!compression.isHDR && !compression.canKeepHDR && compression.output.dynamicRange == .standard)
        #expect(compression.videoBitRate(at: .standard) > hevcRate, "H.264 needs more bits for the same picture")
        compression.setCodec(.hevc)
        #expect(compression.isHDR, "HDR comes back with HEVC")
        compression.setKeepsHDR(false)
        #expect(!compression.isHDR)
    }

    @Test func resolutionNeverUpscales() {
        var compression = VideoCompression(source: Self.source(frameRate: 30, size: CGSize(width: 1280, height: 720)))
        compression.setResolution(.uhd)
        #expect(compression.renderSize == CGSize(width: 1280, height: 720))
        #expect(compression.shownResolution == .hd)
        #expect(compression.isResolutionAvailable(.hd))
        #expect(!compression.isResolutionAvailable(.fullHD) && !compression.isResolutionAvailable(.uhd))
    }

    @Test func estimateFollowsTheChoices() {
        let sound = CompressionSource.Audio(isAAC: true, channelCount: 2, sampleRate: 48_000, bitRate: 128_000)
        var compression = VideoCompression(source: Self.source(frameRate: 30, audio: sound))
        // 1080p at 30 fps and 0.08 bits per pixel for a minute, and the AAC sound as it is.
        let standard = compression.estimatedFileSize(calibration: nil)
        #expect(standard == Int64((1920.0 * 1080 * 30 * 0.08 + 128_000) * 60 / 8))

        let half = SizeCalibration(videoRateFactor: 0.5, photoBytesPerPixel: 0, pixelCount: 1920 * 1080)
        #expect(compression.estimatedFileSize(calibration: half) == Int64((1920.0 * 1080 * 30 * 0.04 + 128_000) * 60 / 8))

        compression.setIncludesAudio(false)
        #expect(compression.estimatedFileSize(calibration: nil) == standard - 128_000 * 60 / 8)
        compression.setFrameRate(24)
        compression.setBitRate(.low)
        compression.setResolution(.hd)
        #expect(compression.estimatedFileSize(calibration: nil) == Int64(1280.0 * 720 * 24 * 0.05 * 60 / 8))

        // Sound that isn't AAC is encoded at 64 kbit/s a channel.
        let pcm = CompressionSource.Audio(isAAC: false, channelCount: 1, sampleRate: 48_000, bitRate: 768_000)
        var livePhoto = VideoCompression(source: Self.source(frameRate: 30, audio: pcm))
        let withSound = livePhoto.estimatedFileSize(calibration: nil)
        livePhoto.setIncludesAudio(false)
        #expect(withSound - livePhoto.estimatedFileSize(calibration: nil) == 64_000 * 60 / 8)
    }

    // MARK: - Export

    /// 4K goes down to 1080p in HEVC, as long as the original, and a real recording comes out much smaller.
    @Test(arguments: Fixture.uhd.filter(\.isAvailable))
    func compressesToTheChosenSize(_ fixture: Fixture) async throws {
        let source = try await SourceMedia.load(fixture.url)
        var compression = VideoCompression(source: try await source.compressionSource())
        compression.setResolution(.fullHD)
        let video = try await Self.export(compression, of: source, named: "1080p-\(fixture.name)")

        let expected = fixture.expectedSize.width > fixture.expectedSize.height
            ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        let facts = try await MovieFacts.load(video.url)
        #expect(video.pixelSize == expected && facts.size == expected)
        #expect(facts.codec == kCMVideoCodecType_HEVC)
        #expect(abs(facts.duration - source.duration.seconds) < 1.0 / 30)
        #expect(video.byteCount == facts.fileSize)
        if fixture.kind == .real {
            #expect(Double(video.byteCount) < Double(compression.source.fileSize) * 0.3, "\(video.byteCount) of \(compression.source.fileSize) bytes")
        }
    }

    /// A lower rate drops frames evenly; the original's keeps every frame at its own time, even at a variable rate.
    @Test func frameRateReachesTheCopy() async throws {
        let fast = try await SourceMedia.load(Fixture.root.appending(path: "Fixtures/synthetic/hfr-120fps-4s.mov"))
        var compression = VideoCompression(source: try await fast.compressionSource())
        #expect(compression.lowerFrameRates == [60, 30, 24])
        compression.setFrameRate(30)
        let thirty = try await MovieFacts.load(try await Self.export(compression, of: fast, named: "120-to-30").url)
        #expect(abs(thirty.nominalFrameRate - 30) < 0.5 && abs(thirty.frameCount - 120) <= 1, "\(thirty)")
        compression.setFrameRate(nil)
        let original = try await MovieFacts.load(try await Self.export(compression, of: fast, named: "120-kept").url)
        #expect(abs(original.nominalFrameRate - 120) < 1 && abs(original.frameCount - 480) <= 1, "\(original)")

        let variableURL = Fixture.root.appending(path: "Fixtures/synthetic/vfr-30fps-5s.mov")
        let variable = try await SourceMedia.load(variableURL)
        let kept = try await Self.export(VideoCompression(source: try await variable.compressionSource()), of: variable, named: "vfr-kept")
        // From the first frame: the fixture's stored times start two frames late, where its B-frame delay is.
        let sourceTimes = try await MediaProbe.videoPresentationTimes(variableURL).map(\.seconds)
        let copyTimes = try await MediaProbe.videoPresentationTimes(kept.url).map(\.seconds)
        #expect(copyTimes.count == sourceTimes.count)
        #expect(zip(copyTimes, sourceTimes).allSatisfy { abs(($0 - copyTimes[0]) - ($1 - sourceTimes[0])) < 1e-3 },
                "\(copyTimes.prefix(8)) vs \(sourceTimes.prefix(8))")
    }

    /// The encoder keeps to the bit rate asked for once it has settled, after its first second: never far above it, and
    /// on camera footage close to it.
    @Test func bitRateReachesTheCopy() async throws {
        let fixtures = ["synthetic/landscape-sdr-30fps-6s.mov", "real/portrait-sdr-h264-30fps-4.8s.mov", "real/portrait-hdr-dolbyvision-59.94fps-5.1s.mov"]
            .map { Fixture.root.appending(path: "Fixtures/\($0)") }
            .filter(Fixture.isAvailable)
        for url in fixtures {
            let source = try await SourceMedia.load(url)
            var compression = VideoCompression(source: try await source.compressionSource())
            compression.setResolution(.hd)
            var spent: [VideoBitRate: Double] = [:]
            for bitRate in [VideoBitRate.low, .veryHigh] {
                compression.setBitRate(bitRate)
                let video = try await Self.export(compression, of: source, named: "rate-\(bitRate.rawValue)-\(url.lastPathComponent)")
                let facts = try await MovieFacts.load(video.url)
                let asked = Double(compression.videoBitRate(at: bitRate))
                let rate = Double(try await MovieFacts.videoBytes(in: video.url, from: 1) * 8) / (facts.duration - 1)
                spent[bitRate] = rate
                // A 4K iPhone clip at Low settles 18% above the rate: the encoder won't starve detail further.
                #expect(rate < asked * 1.25, "\(url.lastPathComponent) at \(bitRate): \(Int(rate)) of \(Int(asked)) bit/s")
                if url.path.contains("/real/") {
                    #expect(rate > asked * 0.85, "\(url.lastPathComponent) at \(bitRate): \(Int(rate)) of \(Int(asked)) bit/s")
                }
            }
            #expect(spent[.veryHigh]! > spent[.low]!)
        }
    }

    /// HDR stays 10-bit HLG; turned off, or in H.264, it's tone-mapped to 8-bit Rec. 709.
    @Test(arguments: Fixture.hdr.filter(\.isAvailable))
    func hdrIsKeptOrToneMapped(_ fixture: Fixture) async throws {
        let source = try await SourceMedia.load(fixture.url)
        var compression = VideoCompression(source: try await source.compressionSource())
        compression.setResolution(.hd)
        #expect(compression.isHDR)
        let hdr = try await MovieFacts.load(try await Self.export(compression, of: source, named: "hdr-\(fixture.name)").url)
        #expect(hdr.codec == kCMVideoCodecType_HEVC)
        #expect(hdr.transferFunction == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        #expect(hdr.bitsPerComponent == 10)

        compression.setKeepsHDR(false)
        let sdr = try await MovieFacts.load(try await Self.export(compression, of: source, named: "sdr-\(fixture.name)").url)
        #expect(sdr.transferFunction == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(sdr.bitsPerComponent != 10)

        compression.setKeepsHDR(true)
        compression.setCodec(.h264)
        let h264 = try await MovieFacts.load(try await Self.export(compression, of: source, named: "h264-\(fixture.name)").url)
        #expect(h264.codec == kCMVideoCodecType_H264)
        #expect(h264.transferFunction == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
    }

    /// AAC goes in as it is, in step with the picture; other sound is encoded as AAC; sound off leaves none.
    @Test func soundIsKeptInStep() async throws {
        let url = Fixture.root.appending(path: "Fixtures/synthetic/av-sync-30fps-8s.mov")
        let source = try await SourceMedia.load(url)
        var compression = VideoCompression(source: try await source.compressionSource())
        #expect(compression.source.audio?.isAAC == true)
        let video = try await Self.export(compression, of: source, named: "sync")
        let facts = try await MovieFacts.load(video.url)
        #expect(facts.audioCodec == kAudioFormatMPEG4AAC && facts.audioChannels == 1)

        let sourceOffsets = zip(try await MediaProbe.flashOnsets(url), MediaProbe.beepOnsets(try #require(try await MediaProbe.audio(url))))
            .map { $0 - $1 }
        let flashes = try await MediaProbe.flashOnsets(video.url)
        let beeps = MediaProbe.beepOnsets(try #require(try await MediaProbe.audio(video.url)))
        #expect(flashes.count == sourceOffsets.count && beeps.count == sourceOffsets.count, "Flashes \(flashes), beeps \(beeps)")
        for (offset, sourceOffset) in zip(zip(flashes, beeps).map { $0 - $1 }, sourceOffsets) {
            #expect(abs(offset - sourceOffset) < 0.012, "Flash-to-beep \(offset) s, \(sourceOffset) s in the original")
        }

        compression.setIncludesAudio(false)
        let silent = try await MovieFacts.load(try await Self.export(compression, of: source, named: "sync-silent").url)
        #expect(silent.audioCodec == nil)

        // A Live Photo's movie has PCM sound, which is far larger than AAC.
        let livePhoto = Fixture.root.appending(path: "Fixtures/real/live-photos/IMG_4641-4644/IMG_4642.MOV")
        guard Fixture.isAvailable(livePhoto) else { return }
        let pcmSource = try await SourceMedia.load(livePhoto)
        let pcm = VideoCompression(source: try await pcmSource.compressionSource())
        #expect(pcm.source.audio?.isAAC == false)
        let encoded = try await MovieFacts.load(try await Self.export(pcm, of: pcmSource, named: "pcm").url)
        #expect(encoded.audioCodec == kAudioFormatMPEG4AAC)
        let pcmDuration = try await #require(pcmSource.audioTrack).load(.timeRange).duration.seconds
        #expect(abs(encoded.audioDuration - pcmDuration) < 0.01)
    }

    /// Measured from three pieces of the video, or all of a short one, the estimate lands near what the copy takes.
    @Test func calibratedEstimateIsClose() async throws {
        var fixtures = ["synthetic/landscape-sdr-30fps-6s.mov", "real/portrait-sdr-h264-30fps-4.8s.mov",
                        "real/portrait-hdr-dolbyvision-59.94fps-5.1s.mov"]
            .map { Fixture.root.appending(path: "Fixtures/\($0)") }
            .filter(Fixture.isAvailable)
        // Long enough to be measured in pieces: simple footage, and camera footage.
        if let pattern = try await Self.longClip(from: "synthetic/long-10min.mov", upTo: 40, named: "pattern-40s.mov") {
            fixtures.append(pattern)
        }
        if let looped = try await Self.longClip(from: "real/portrait-sdr-h264-30fps-4.8s.mov", times: 10, named: "looped-48s.mov") {
            fixtures.append(looped)
        }
        for url in fixtures {
            let source = try await SourceMedia.load(url)
            var compression = VideoCompression(source: try await source.compressionSource())
            compression.setResolution(.hd)
            for bitRate in [VideoBitRate.low, .high] {
                compression.setBitRate(bitRate)
                let scratch = Fixture.outputDirectory(for: "compress/samples")
                let calibration = try await VideoExporter().measure(compression, source: source, in: scratch)
                let estimate = Double(compression.estimatedFileSize(calibration: calibration))
                let video = try await Self.export(compression, of: source, named: "estimate-\(bitRate.rawValue)-\(url.lastPathComponent)")
                let actual = Double(video.byteCount)
                #expect(abs(estimate / actual - 1) < 0.2, "\(url.lastPathComponent) at \(bitRate): estimated \(Int(estimate)), made \(Int(actual)) bytes")
                #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "The samples are removed")
            }
        }
    }

    /// The copy carries the original's date and camera, and its place only when asked.
    @Test func metadataCarriesOver() async throws {
        let url = Fixture.root.appending(path: "Fixtures/real/portrait-sdr-h264-30fps-4.8s.mov")
        guard Fixture.isAvailable(url) else { return }
        let source = try await SourceMedia.load(url)
        var compression = VideoCompression(source: try await source.compressionSource())
        compression.setResolution(.hd)
        let plain = try await Self.export(compression, of: source, named: "metadata")
        let copy = try await SourceMedia.load(plain.url)
        #expect(copy.capture.date == source.capture.date && copy.capture.model == source.capture.model)
        #expect(plain.captureDate == source.capture.date)
        #expect(copy.capture.location == nil && plain.location == nil)

        if source.capture.location != nil {
            compression.setIncludesLocation(true)
            let located = try await Self.export(compression, of: source, named: "metadata-location")
            #expect(try await SourceMedia.load(located.url).capture.location != nil)
            #expect(located.location == source.capture.location)
        }
    }

    /// Cancelling stops the render and leaves no file behind.
    @Test func cancellingRemovesTheCopy() async throws {
        let source = try await SourceMedia.load(Fixture.root.appending(path: "Fixtures/synthetic/long-10min.mov"))
        let compression = VideoCompression(source: try await source.compressionSource())
        let directory = Fixture.outputDirectory(for: "compress/cancelled")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Video.MOV")
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await VideoExporter().export(compression, source: source, to: url) { stage in
                if case .compressing = stage { started.continuation.yield() }
            }
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Helpers

    private static func source(frameRate: Double, size: CGSize = CGSize(width: 3840, height: 2160), isHDR: Bool = false,
                               audio: CompressionSource.Audio? = nil) -> CompressionSource {
        CompressionSource(duration: 60, orientedSize: size, frameRate: frameRate, isHDR: isHDR, audio: audio)
    }

    /// `fixture` `times` over, one after another, at most `seconds` of it each time; nil when the fixture is missing. Kept
    /// in the test output, as making it takes a moment.
    private static func longClip(from fixture: String, times: Int = 1, upTo seconds: Double = .infinity, named name: String) async throws -> URL? {
        let clipURL = Fixture.root.appending(path: "Fixtures/\(fixture)")
        guard Fixture.isAvailable(clipURL) else { return nil }
        let url = Fixture.outputDirectory(for: "compress/\(name)")
        if Fixture.isAvailable(url) { return url }
        let clip = AVURLAsset(url: clipURL)
        let composition = AVMutableComposition()
        let duration = try await clip.load(.duration)
        let piece = CMTimeRange(start: .zero, duration: seconds.isFinite ? CMTimeMinimum(duration, .seconds(seconds)) : duration)
        for _ in 0..<times { try await composition.insertTimeRange(piece, of: clip, at: composition.duration) }
        if let track = try await clip.loadTracks(withMediaType: .video).first {
            composition.tracks(withMediaType: .video).first?.preferredTransform = try await track.load(.preferredTransform)
        }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await session.export(to: url, as: .mov)
        return url
    }

    private static func export(_ compression: VideoCompression, of source: SourceMedia, named name: String) async throws -> CompressedVideo {
        let directory = Fixture.outputDirectory(for: "compress/\(name)")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await VideoExporter().export(compression, source: source, to: directory.appending(path: "Video.MOV"))
    }
}

/// What a movie file turned out as.
private struct MovieFacts: CustomStringConvertible {
    var fileSize: Int64
    var duration: Double
    var size: CGSize
    var codec: FourCharCode?
    var nominalFrameRate: Double
    var frameCount: Int
    var transferFunction: String?
    var bitsPerComponent: Int?
    var videoBytes: Int64
    var audioCodec: AudioFormatID?
    var audioChannels: Int?
    var audioDuration: Double

    var description: String {
        "\(Int(size.width))×\(Int(size.height)), \(duration) s, \(frameCount) frames at \(nominalFrameRate) fps"
    }

    static func load(_ url: URL) async throws -> MovieFacts {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, formats, rate, bytes) = try await video.load(.naturalSize, .formatDescriptions, .nominalFrameRate, .totalSampleDataLength)
        let format = formats.first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let audioFormat = try await audio?.load(.formatDescriptions).first
        return MovieFacts(
            fileSize: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
            duration: try await asset.load(.duration).seconds,
            size: size,
            codec: format?.mediaSubType.rawValue,
            nominalFrameRate: Double(rate),
            frameCount: try await MediaProbe.videoPresentationTimes(url).count,
            transferFunction: format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String },
            bitsPerComponent: format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int },
            videoBytes: bytes,
            audioCodec: audioFormat?.mediaSubType.rawValue,
            audioChannels: audioFormat?.audioStreamBasicDescription.map { Int($0.mChannelsPerFrame) },
            audioDuration: try await audio?.load(.timeRange).duration.seconds ?? 0
        )
    }

    /// The encoded picture's bytes from `start` seconds on.
    static func videoBytes(in url: URL, from start: Double) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var bytes = 0
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isNumeric, time.seconds >= start { bytes += CMSampleBufferGetTotalSampleSize(sample) }
        }
        return bytes
    }
}
