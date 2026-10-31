import AVFoundation
import CoreMedia
import os

public enum VideoExportError: Error, LocalizedError {
    case destinationExists(URL)
    case readerConfigurationFailed
    case writerConfigurationFailed
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case let .destinationExists(url):
            String(localized: "“\(url.lastPathComponent)” already exists.", bundle: #bundle)
        case .readerConfigurationFailed, .writerConfigurationFailed, .renderFailed:
            String(localized: "The video couldn’t be compressed.", bundle: #bundle)
        }
    }
}

/// Where a compression is, for progress.
public enum VideoExportStage: Sendable, Equatable {
    /// Building the composition.
    case preparing
    /// Encoding; the fraction of the video done.
    case compressing(Double)
    /// Finishing the movie file.
    case finishing
}

/// A compressed copy of a video, as a movie file.
public struct CompressedVideo: Sendable, Equatable {
    public let url: URL
    public let duration: CMTime
    public let pixelSize: CGSize
    public let hasAudio: Bool
    public let isHDR: Bool
    /// The file’s size.
    public let byteCount: Int64
    /// When the original was recorded, as far as its metadata says.
    public let captureDate: Date?
    /// Where the original was taken, when the copy includes it.
    public let location: CaptureLocation?
}

/// Makes a plain video of an edit, or a smaller or differently encoded copy of a whole video, with the render pipeline
/// the Live Photo uses, so trimming, speed, cropping, scaling, HDR, tone mapping and captions are the same.
public struct VideoExporter: Sendable {
    /// Pieces of the video `measure` renders, and how long each is. The encoder spends more in its first second, about
    /// half as much again at Low, before it settles on the bit rate asked for, so each piece measures only what follows.
    static let sampleCount = 3
    static let sampleSeconds = 2.0
    static let settlingSeconds = 1.0

    public init() {}

    /// Renders `compression` of `source` into a new QuickTime movie at `url`. Never overwrites a file, and removes what
    /// it wrote if rendering fails or is cancelled.
    public func export(
        _ compression: VideoCompression,
        source: SourceMedia,
        to url: URL,
        progress: (@Sendable (VideoExportStage) -> Void)? = nil
    ) async throws -> CompressedVideo {
        try await export(compression.plan(duration: source.duration), keepsFrameTiming: compression.keepsOriginalFrameRate,
                         audio: compression.source.audio, source: source, to: url, progress: progress)
    }

    /// Renders `plan` of `source` into a new QuickTime movie at `url`: its selection at its speed, cropped and with its
    /// captions, as a plain video. `keepsFrameTiming` keeps the source's frames and their timing, as a copy at its own
    /// frame rate and speed does; `audio` is how the source's sound is stored. Never overwrites a file, and removes what
    /// it wrote if rendering fails or is cancelled.
    public func export(
        _ plan: EditPlan,
        keepsFrameTiming: Bool,
        audio: CompressionSource.Audio?,
        source: SourceMedia,
        to url: URL,
        progress: (@Sendable (VideoExportStage) -> Void)? = nil
    ) async throws -> CompressedVideo {
        progress?(.preparing)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { throw VideoExportError.destinationExists(url) }
        let capture = CaptureStamp(capture: source.capture, plan: plan)
        do {
            let graph = try await render(plan, keepsFrameTiming: keepsFrameTiming, audio: audio, source: source, to: url,
                                         metadata: capture.movieItems, progress: progress)
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return CompressedVideo(
                url: url,
                duration: plan.outputDuration,
                pixelSize: graph.renderSize,
                hasAudio: graph.hasAudio,
                isHDR: plan.output.dynamicRange == .high,
                byteCount: Int64(bytes),
                captureDate: capture.movieDate,
                location: capture.location
            )
        } catch {
            // The file is new (checked above), so removing it never touches the user's data.
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    /// How this video encodes with `compression`'s settings: a few short pieces of it, or all of a short one, rendered at
    /// the copy's own size without sound into a new folder inside `parent` and measured against the bit rate asked for.
    /// Removes what it rendered before returning.
    public func measure(_ compression: VideoCompression, source: SourceMedia, in parent: URL) async throws -> SizeCalibration {
        try await measure(compression.plan(duration: source.duration), keepsFrameTiming: compression.keepsOriginalFrameRate,
                          source: source, in: parent)
    }

    /// How `plan`'s selection encodes with its settings, as above: pieces of it at its speed and crop, without sound or
    /// captions.
    public func measure(_ plan: EditPlan, keepsFrameTiming: Bool, source: SourceMedia, in parent: URL) async throws -> SizeCalibration {
        let directory = parent.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var silent = plan
        silent.includesAudio = false
        silent.captions = nil
        var asked = 0.0
        var spent = 0.0
        var pixels = 0.0
        let ranges = Self.sampleRanges(duration: plan.selection.duration)
        // A short video is measured whole, as its copy also has the encoder's first second.
        let settling = ranges.count > 1 ? Self.settlingSeconds : 0
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let url = directory.appending(path: "Sample\(index).mov")
            var piece = silent
            piece.selection = CMTimeRange(start: plan.selection.start + range.start, duration: range.duration)
            piece.keyPhotoSourceTime = piece.selection.start
            let graph = try await render(piece, keepsFrameTiming: keepsFrameTiming, audio: nil, source: source, to: url,
                                         metadata: [], progress: nil)
            spent += Double(try await Self.videoBytes(in: url, from: settling)) * 8
            asked += Double(piece.output.averageVideoBitRate(for: graph.renderSize)) * (piece.outputDuration.seconds - settling)
            pixels = Double(graph.renderSize.width * graph.renderSize.height)
        }
        let measured = asked > 0 ? spent / asked : 1
        return SizeCalibration(videoRateFactor: ranges.count > 1 ? Self.settledRateFactor(measured) : measured,
                               photoBytesPerPixel: 0, pixelCount: pixels)
    }

    /// Over a long video the encoder ends nearer the bit rate asked for than a piece's second second shows. Footage that
    /// needs more than the rate comes down to within a few percent of it; simple footage, which needs less, still rises
    /// by about 38% over its first six seconds or so, at every rate. Measured on a 48-second iPhone clip and a ten-minute
    /// test pattern, at Low and High.
    static func settledRateFactor(_ measured: Double) -> Double {
        measured >= 1 ? min(measured, 1.05) : min(measured * 1.38, 1)
    }

    /// The encoded picture's bytes from `start` seconds on.
    private static func videoBytes(in url: URL, from start: Double) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoExportError.readerConfigurationFailed }
        var bytes = 0
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isNumeric, time.seconds >= start - 1e-3 { bytes += CMSampleBufferGetTotalSampleSize(sample) }
        }
        return bytes
    }

    /// Two seconds each at a sixth, half and five sixths of the way through, or all of a short video.
    static func sampleRanges(duration: CMTime) -> [CMTimeRange] {
        let seconds = duration.seconds
        guard seconds > Double(sampleCount) * sampleSeconds + 1 else { return [CMTimeRange(start: .zero, duration: duration)] }
        return (0..<sampleCount).map { index in
            let center = seconds * (Double(index) * 2 + 1) / Double(sampleCount * 2)
            return CMTimeRange(start: .seconds(center - sampleSeconds / 2), duration: .seconds(sampleSeconds))
        }
    }

    private func render(
        _ plan: EditPlan,
        keepsFrameTiming: Bool,
        audio sound: CompressionSource.Audio?,
        source: SourceMedia,
        to url: URL,
        metadata: [AVMetadataItem],
        progress: (@Sendable (VideoExportStage) -> Void)?
    ) async throws -> RenderGraph {
        try Task.checkCancellation()
        // The original's frame rate keeps its frames and their timing, so 29.97 fps and variable rates stay as they were.
        let graph = keepsFrameTiming
            ? try RenderPipeline.buildKeepingFrameTiming(source: source, plan: plan)
            : try RenderPipeline.build(source: source, plan: plan)
        var audio: VideoRenderSession.Audio?
        if graph.hasAudio, let sound, let track = source.audioTrack {
            // AAC at its own speed goes in as it is. At another speed, the mix output retimes the sound, so it's encoded.
            audio = sound.isAAC && plan.speed == 1
                ? .passthrough(try await track.load(.formatDescriptions).first)
                : .encoded(sampleRate: sound.encodedSampleRate, channels: sound.encodedChannelCount, bitRate: sound.encodedBitRate)
        }
        let session = try VideoRenderSession(graph: graph, plan: plan, audio: audio, url: url, metadata: metadata,
                                             progress: progress)
        try await session.run()
        try Task.checkCancellation()
        return graph
    }
}

/// One pass that reads the render graph and writes a plain movie: frames as the compositor makes them, with their own
/// timing and the plan's captions drawn over them, and the sound as it is or encoded as AAC.
///
/// Uses the AVAssetReader/AVAssetWriter pull APIs, as `MovieRenderSession` does. Unlike it, nothing is held in memory:
/// the sound streams from the source, since a video can be long. It streams through a reader of its own: with one reader
/// for both, the reader held the picture back until the sound was read, while the writer held the sound back until the
/// picture caught up, and a long video stopped there.
///
/// Thread safety: video state is touched only on `videoQueue`, audio state only on `audioQueue`, and the two meet only
/// after both have finished.
final class VideoRenderSession: @unchecked Sendable {
    enum Audio {
        /// Copies the source's AAC packets, described by this format.
        case passthrough(CMFormatDescription?)
        case encoded(sampleRate: Double, channels: Int, bitRate: Int)
    }

    private let reader: AVAssetReader
    private let audioReader: AVAssetReader?
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderOutput?
    private let audioInput: AVAssetWriterInput?
    private let duration: CMTime
    private let progress: (@Sendable (VideoExportStage) -> Void)?
    /// Captions to draw into the movie; nil leaves its frames as the compositor made them.
    private let captions: CaptionOverlay?
    private let dynamicRange: DynamicRange

    private let videoQueue = DispatchQueue(label: "Still.compress.video")
    private let audioQueue = DispatchQueue(label: "Still.compress.audio")
    /// Set from any thread by cancelling; each queue then stops its own reader between samples. A reader cancelled
    /// from elsewhere while its queue was copying a sample crashed Still.
    private let cancelRequested = OSAllocatedUnfairLock(initialState: false)

    // videoQueue only
    private var videoFinished = false
    private var reportedPercent = -1
    private var captionCompositor: CaptionCompositor?
    /// Why a frame couldn't be captioned, which ends the movie as failed.
    private var videoError: Error?
    // audioQueue only
    private var audioFinished = false

    init(
        graph: RenderGraph,
        plan: EditPlan,
        audio: Audio?,
        url: URL,
        metadata: [AVMetadataItem],
        progress: (@Sendable (VideoExportStage) -> Void)?
    ) throws {
        reader = try AVAssetReader(asset: graph.composition)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        // The movie's index goes first, so a copy shared to the web starts playing before it has all arrived.
        writer.shouldOptimizeForNetworkUse = true
        duration = plan.outputDuration
        self.progress = progress
        dynamicRange = plan.output.dynamicRange
        captions = plan.captions
            .map { CaptionOverlay($0, plan: plan, renderSize: graph.renderSize) }
            .flatMap { $0.cues.isEmpty ? nil : $0 }

        videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: graph.composition.tracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: plan.output.dynamicRange.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.videoComposition = graph.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoExportError.readerConfigurationFailed }
        reader.add(videoOutput)

        videoInput = AVAssetWriterInput(mediaType: .video,
                                        outputSettings: MovieRenderSession.videoSettings(for: graph.renderSize, output: plan.output))
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoExportError.writerConfigurationFailed }
        writer.add(videoInput)

        guard let audio, let track = graph.composition.tracks(withMediaType: .audio).first else {
            audioReader = nil
            audioOutput = nil
            audioInput = nil
            return
        }
        let audioReader = try AVAssetReader(asset: graph.composition)
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        switch audio {
        case let .passthrough(format):
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        case let .encoded(sampleRate, channels, bitRate):
            // The mix output downmixes and resamples to what the encoder takes, and retimes sound at another speed,
            // keeping its pitch.
            let mix = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            mix.audioTimePitchAlgorithm = .spectral
            output = mix
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
            ])
        }
        output.alwaysCopiesSampleData = false
        input.expectsMediaDataInRealTime = false
        guard audioReader.canAdd(output) else { throw VideoExportError.readerConfigurationFailed }
        guard writer.canAdd(input) else { throw VideoExportError.writerConfigurationFailed }
        audioReader.add(output)
        writer.add(input)
        self.audioReader = audioReader
        audioOutput = output
        audioInput = input
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancelled before reading began: the handler below has already run and found nothing to stop.
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                start(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        cancelRequested.withLock { $0 = true }
        // While a queue waits for the writer, nothing there sees the flag; stop its reader there now.
        videoQueue.async { [self] in reader.cancelReading() }
        audioQueue.async { [self] in audioReader?.cancelReading() }
    }

    // MARK: - Pass

    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        guard writer.startWriting() else {
            continuation.resume(throwing: writer.error ?? VideoExportError.writerConfigurationFailed)
            return
        }
        for reader in [reader, audioReader].compactMap(\.self) where !reader.startReading() {
            self.reader.cancelReading()
            audioReader?.cancelReading()
            writer.cancelWriting()
            continuation.resume(throwing: reader.error ?? VideoExportError.readerConfigurationFailed)
            return
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        group.enter()
        pumpVideo { group.leave() }
        if audioInput != nil {
            group.enter()
            pumpAudio { group.leave() }
        }
        group.notify(queue: videoQueue) { [self] in
            finish(continuation)
        }
    }

    private func pumpVideo(completion: @escaping @Sendable () -> Void) {
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
            while !videoFinished && videoInput.isReadyForMoreMediaData {
                if cancelRequested.withLock({ $0 }) { reader.cancelReading() }
                guard let sample = videoOutput.copyNextSampleBuffer(), videoError == nil, videoInput.append(captioned(sample)) else {
                    videoFinished = true
                    videoInput.markAsFinished()
                    completion()
                    return
                }
                report(CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
    }

    /// `frame` with the caption showing at its time drawn over it, or `frame` itself when none is.
    private func captioned(_ frame: CMSampleBuffer) -> CMSampleBuffer {
        guard let cue = captions?.cue(at: CMSampleBufferGetPresentationTimeStamp(frame).seconds) else { return frame }
        do {
            let compositor = captionCompositor ?? CaptionCompositor(dynamicRange: dynamicRange)
            captionCompositor = compositor
            return try compositor.draw(cue, over: frame)
        } catch {
            videoError = error
            return frame
        }
    }

    /// Whole percents only: a long video has tens of thousands of frames.
    private func report(_ time: CMTime) {
        guard let progress, duration.seconds > 0 else { return }
        let fraction = min(max(time.seconds / duration.seconds, 0), 1)
        let percent = Int(fraction * 100)
        guard percent > reportedPercent else { return }
        reportedPercent = percent
        progress(.compressing(fraction))
    }

    private func pumpAudio(completion: @escaping @Sendable () -> Void) {
        guard let audioInput else { return completion() }
        audioInput.requestMediaDataWhenReady(on: audioQueue) { [self] in
            guard let audioInput = self.audioInput, let audioOutput = self.audioOutput else { return }
            while !audioFinished && audioInput.isReadyForMoreMediaData {
                if cancelRequested.withLock({ $0 }) { audioReader?.cancelReading() }
                guard let sample = audioOutput.copyNextSampleBuffer(), audioInput.append(sample) else {
                    audioFinished = true
                    audioInput.markAsFinished()
                    completion()
                    return
                }
            }
        }
    }

    // MARK: - Completion (videoQueue)

    private func finish(_ continuation: CheckedContinuation<Void, Error>) {
        let readers = [reader, audioReader].compactMap(\.self)
        if let videoError {
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
            continuation.resume(throwing: videoError)
            return
        }
        if let failed = readers.first(where: { $0.status == .failed }) {
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
            continuation.resume(throwing: failed.error ?? VideoExportError.renderFailed)
            return
        }
        if readers.contains(where: { $0.status == .cancelled }) {
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
            continuation.resume(throwing: CancellationError())
            return
        }
        if writer.status == .failed {
            continuation.resume(throwing: writer.error ?? VideoExportError.renderFailed)
            return
        }
        progress?(.finishing)
        writer.endSession(atSourceTime: duration)
        writer.finishWriting { [self] in
            if writer.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: writer.error ?? VideoExportError.renderFailed)
            }
        }
    }
}
