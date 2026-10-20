import AVFoundation
import CoreMedia
import VideoToolbox

/// One pass that reads the render graph, writes the paired movie, and captures the Key Photo.
///
/// Uses the AVAssetReader/AVAssetWriter pull APIs, which are deprecated from macOS 27 but are the
/// documented path on the macOS 26 deployment target. Migrating to the async
/// `AVAssetReaderOutput.Provider` / `AVAssetWriterInput.SampleBufferReceiver` APIs is local to this file.
///
/// Thread safety: video state is touched only on `videoQueue`, audio state only on `audioQueue`,
/// and the two meet only after both have finished.
final class MovieRenderSession: @unchecked Sendable {
    struct Result: Sendable {
        let keyPhotoPresentationTime: CMTime
    }

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    /// Retimed PCM for the whole output, rendered before writing starts.
    private let audioBuffers: [CMSampleBuffer]
    private let metadataAdaptor: AVAssetWriterInputMetadataAdaptor

    private let outputDuration: CMTime
    private let frameDuration: CMTime
    private let frameRate: Int32
    private let frameCount: Int64
    private let keyPhotoTime: CMTime
    private let keyPhotoFrameIndex: Int64
    private let keyPhotoURL: URL
    private let contentIdentifier: String
    private let progress: (@Sendable (LivePhotoExportStage) -> Void)?

    private let videoQueue = DispatchQueue(label: "Still.render.video")
    private let audioQueue = DispatchQueue(label: "Still.render.audio")

    // videoQueue only
    private var videoFinished = false
    private var sourceFramesExhausted = false
    private var lastSourceFrame: CMSampleBuffer?
    private var pendingFrames: [CMSampleBuffer] = []
    private var nextFrameIndex: Int64 = 0
    private var videoError: Error?
    private var keyPhotoPresentationTime: CMTime = .invalid
    private var keyPhotoWriter: KeyPhotoWriter?
    // audioQueue only
    private var audioFinished = false
    private var nextAudioBuffer = 0

    init(
        graph: RenderGraph,
        plan: EditPlan,
        movieURL: URL,
        keyPhotoURL: URL,
        contentIdentifier: String,
        progress: (@Sendable (LivePhotoExportStage) -> Void)?
    ) throws {
        reader = try AVAssetReader(asset: graph.composition)
        writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        writer.metadata = [LivePhotoMetadata.contentIdentifierItem(contentIdentifier)]
        writer.shouldOptimizeForNetworkUse = true

        outputDuration = graph.outputDuration
        frameDuration = plan.frameDuration
        frameRate = plan.output.frameRate
        frameCount = plan.outputFrameCount
        keyPhotoTime = plan.keyPhotoFrameTime
        keyPhotoFrameIndex = plan.keyPhotoFrameIndex
        self.keyPhotoURL = keyPhotoURL
        self.contentIdentifier = contentIdentifier
        self.progress = progress

        let videoTracks = graph.composition.tracks(withMediaType: .video)
        videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.videoComposition = graph.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw LivePhotoExportError.readerConfigurationFailed }
        reader.add(videoOutput)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(for: graph.renderSize, output: plan.output))
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw LivePhotoExportError.writerConfigurationFailed }
        writer.add(videoInput)

        if let retimer = graph.audioRetimer {
            audioBuffers = try retimer.render()
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.encodedAudioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw LivePhotoExportError.writerConfigurationFailed }
            writer.add(input)
            audioInput = input
        } else {
            audioBuffers = []
            audioInput = nil
        }

        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: try LivePhotoMetadata.stillImageTimeFormatDescription()
        )
        metadataInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(metadataInput) else { throw LivePhotoExportError.writerConfigurationFailed }
        writer.add(metadataInput)
        metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
    }

    func run() async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancelled before reading began: the handler below has already run and found nothing to stop.
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                start(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        reader.cancelReading()
    }

    // MARK: - Pass

    private func start(_ continuation: CheckedContinuation<Result, Error>) {
        guard writer.startWriting() else {
            continuation.resume(throwing: writer.error ?? LivePhotoExportError.writerConfigurationFailed)
            return
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            continuation.resume(throwing: reader.error ?? LivePhotoExportError.readerConfigurationFailed)
            return
        }
        writer.startSession(atSourceTime: .zero)

        // The marker goes in first and its input finishes immediately, so it never holds back
        // the writer's interleaving of video and audio.
        let marker = LivePhotoMetadata.stillImageTimeGroup(at: keyPhotoTime, duration: frameDuration)
        guard metadataAdaptor.append(marker) else {
            reader.cancelReading()
            writer.cancelWriting()
            continuation.resume(throwing: writer.error ?? LivePhotoExportError.writerConfigurationFailed)
            return
        }
        metadataAdaptor.assetWriterInput.markAsFinished()

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
                if pendingFrames.isEmpty {
                    guard queueNextFrames() else {
                        finishVideo(completion)
                        return
                    }
                    continue
                }
                guard videoInput.append(pendingFrames.removeFirst()) else {
                    finishVideo(completion)
                    return
                }
            }
        }
    }

    private func finishVideo(_ completion: @Sendable () -> Void) {
        videoFinished = true
        pendingFrames.removeAll()
        lastSourceFrame = nil
        videoInput.markAsFinished()
        completion()
    }

    /// The compositor emits a frame only when the picture changes, so slowed clips arrive at the source’s
    /// cadence rather than 30 fps. Each frame is re-stamped onto the constant-rate grid, and the previous
    /// frame repeats in any slot the compositor skipped (goal.md §6, constant output frame rate).
    ///
    /// Returns false once every output frame has been queued.
    private func queueNextFrames() -> Bool {
        guard nextFrameIndex < frameCount, videoError == nil else { return false }
        guard !sourceFramesExhausted, let sample = videoOutput.copyNextSampleBuffer() else {
            sourceFramesExhausted = true
            // A cancelled or failed read also ends the samples; stop instead of filling the rest of the grid.
            guard reader.status != .cancelled, reader.status != .failed, let last = lastSourceFrame else { return false }
            queue(last, through: frameCount - 1)
            return true
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let index = Int64((time.seconds * Double(frameRate)).rounded())
        if let last = lastSourceFrame {
            queue(last, through: min(index, frameCount) - 1)
        }
        queue(sample, through: min(index, frameCount - 1))
        lastSourceFrame = sample
        return true
    }

    /// Appends copies of `sample` for every grid slot from `nextFrameIndex` through `lastIndex`.
    private func queue(_ sample: CMSampleBuffer, through lastIndex: Int64) {
        while nextFrameIndex <= lastIndex {
            let time = CMTime(value: nextFrameIndex, timescale: frameRate)
            var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var frame: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &frame
            )
            guard status == noErr, let frame else {
                videoError = LivePhotoExportError.renderFailed
                return
            }
            if nextFrameIndex == keyPhotoFrameIndex {
                captureKeyPhoto(from: frame, at: time)
            }
            pendingFrames.append(frame)
            nextFrameIndex += 1
        }
        progress?(.rendering(Double(nextFrameIndex) / Double(max(frameCount, 1))))
    }

    private func captureKeyPhoto(from sample: CMSampleBuffer, at time: CMTime) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            videoError = LivePhotoExportError.keyPhotoEncodingFailed
            return
        }
        do {
            let writer = keyPhotoWriter ?? KeyPhotoWriter()
            keyPhotoWriter = writer
            try writer.write(pixelBuffer, to: keyPhotoURL, contentIdentifier: contentIdentifier)
            keyPhotoPresentationTime = time
        } catch {
            videoError = error
        }
    }

    private func pumpAudio(completion: @escaping @Sendable () -> Void) {
        guard let audioInput else { return completion() }
        audioInput.requestMediaDataWhenReady(on: audioQueue) { [self] in
            guard let audioInput = self.audioInput else { return }
            while !audioFinished && audioInput.isReadyForMoreMediaData {
                guard nextAudioBuffer < audioBuffers.count, reader.status != .cancelled,
                      audioInput.append(audioBuffers[nextAudioBuffer]) else {
                    audioFinished = true
                    audioInput.markAsFinished()
                    completion()
                    return
                }
                nextAudioBuffer += 1
            }
        }
    }

    // MARK: - Completion (videoQueue)

    private func finish(_ continuation: CheckedContinuation<Result, Error>) {
        switch reader.status {
        case .failed:
            writer.cancelWriting()
            continuation.resume(throwing: reader.error ?? LivePhotoExportError.renderFailed)
            return
        case .cancelled:
            writer.cancelWriting()
            continuation.resume(throwing: CancellationError())
            return
        default:
            break
        }
        if writer.status == .failed {
            continuation.resume(throwing: writer.error ?? LivePhotoExportError.renderFailed)
            return
        }
        if let videoError {
            reader.cancelReading()
            writer.cancelWriting()
            continuation.resume(throwing: videoError)
            return
        }
        guard keyPhotoPresentationTime.isValid else {
            writer.cancelWriting()
            continuation.resume(throwing: LivePhotoExportError.keyPhotoFrameMissing(keyPhotoTime.seconds))
            return
        }

        let result = Result(keyPhotoPresentationTime: keyPhotoPresentationTime)
        progress?(.creatingLivePhoto)
        writer.endSession(atSourceTime: outputDuration)
        writer.finishWriting { [self] in
            if writer.status == .completed {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: writer.error ?? LivePhotoExportError.renderFailed)
            }
        }
    }

    // MARK: - Settings

    private static func videoSettings(for size: CGSize, output: OutputSettings) -> [String: Any] {
        let frameRate = Int(output.frameRate)
        let pixelsPerSecond = size.width * size.height * Double(frameRate)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(pixelsPerSecond * output.bitsPerPixel),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate,
        ]
        if let quality = output.encoderQuality { compression[AVVideoQualityKey] = quality }
        switch output.videoCodec {
        case .h264: compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc: compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        return [
            AVVideoCodecKey: output.videoCodec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    private static var encodedAudioSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ] }
}
