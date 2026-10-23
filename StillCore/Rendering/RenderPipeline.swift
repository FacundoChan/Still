import AVFoundation
import CoreMedia
import Foundation

/// Everything a player, image generator, or exporter needs to render an edit identically.
public struct RenderGraph: @unchecked Sendable {
    // AVComposition is immutable once built here, so sharing it across tasks is safe.
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let videoTrackID: CMPersistentTrackID
    public let audioTrackIDs: [CMPersistentTrackID]
    public let renderSize: CGSize
    /// Whole output frames: the movie and its audio end exactly here.
    public let outputDuration: CMTime
    /// Used by preview playback only; export retimes audio with `audioRetimer` instead.
    public let audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm
    /// The source audio export retimes; nil when the source is silent or the edit is muted.
    let audioRetimer: AudioRetimer?

    public var hasAudio: Bool { !audioTrackIDs.isEmpty }

    /// A player item that renders like the export. For sound that also matches the export at other
    /// speeds, build the graph with `RenderPipeline.buildPreview`.
    @MainActor
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioTimePitchAlgorithm = audioTimePitchAlgorithm
        return item
    }

    /// Writes the retimed sound export uses to a CAF file, so preview playback can play exactly what will be
    /// exported. Returns false, writing nothing, when the edit has no sound.
    ///
    /// The file is interleaved 16-bit PCM: a composition can’t insert a track of non-interleaved float PCM.
    public func writeRetimedAudio(to url: URL) throws -> Bool {
        guard let audioRetimer else { return false }
        let channels = try audioRetimer.renderChannels()
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioRetimer.sampleRate,
                                   channels: AVAudioChannelCount(AudioRetimer.channelCount))!
        let frames = channels.first?.count ?? 0
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return false
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames) }
        }
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRetimer.sampleRate,
            AVNumberOfChannelsKey: AudioRetimer.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return true
    }
}

public enum RenderPipelineError: Error, LocalizedError {
    case compositionTrackUnavailable

    public var errorDescription: String? {
        "The video couldn’t be prepared for rendering."
    }
}

/// The single builder behind preview and export.
public enum RenderPipeline {
    public static func build(source: SourceMedia, plan: EditPlan) throws -> RenderGraph {
        try build(source: source, plan: plan, retimedAudio: nil)
    }

    /// The export’s graph with its sound replaced by `retimedAudio`, a file from `writeRetimedAudio(to:)`.
    /// AVFoundation’s own time-pitch lags at speed-ups, so preview plays the export’s retimed sound instead.
    public static func buildPreview(source: SourceMedia, plan: EditPlan, retimedAudio: URL?) async throws -> RenderGraph {
        guard let retimedAudio else { return try build(source: source, plan: plan) }
        // Keep the asset alive until the composition holds its track; a track whose asset has been released
        // can't be inserted (AVFoundation error -11800).
        let asset = AVURLAsset(url: retimedAudio)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return try build(source: source, plan: plan)
        }
        let duration = try await track.load(.timeRange).duration
        let graph = try build(source: source, plan: plan, retimedAudio: (track, duration))
        withExtendedLifetime(asset) {}
        return graph
    }

    private static func build(
        source: SourceMedia,
        plan: EditPlan,
        retimedAudio: (track: AVAssetTrack, duration: CMTime)?
    ) throws -> RenderGraph {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RenderPipelineError.compositionTrackUnavailable
        }
        try videoTrack.insertTimeRange(plan.selection, of: source.videoTrack, at: .zero)

        var audioTrackIDs: [CMPersistentTrackID] = []
        var audioRetimer: AudioRetimer?
        if retimedAudio == nil, plan.includesAudio, let sourceAudio = source.audioTrack,
           let audioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audioTrack.insertTimeRange(plan.selection, of: sourceAudio, at: .zero)
            audioTrackIDs.append(audioTrack.trackID)
            audioRetimer = AudioRetimer(
                asset: source.asset, track: sourceAudio, sourceRange: plan.selection,
                speed: plan.speed, outputDuration: plan.renderedDuration
            )
        }

        if plan.speed != 1 {
            composition.scaleTimeRange(
                CMTimeRange(start: .zero, duration: plan.selection.duration),
                toDuration: plan.outputDuration
            )
        }

        // Already at output speed, so it goes in after scaling.
        if plan.includesAudio, let retimedAudio,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let duration = CMTimeMinimum(retimedAudio.duration, plan.renderedDuration)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: retimedAudio.track, at: .zero)
            audioTrackIDs.append(audioTrack.trackID)
        }

        let geometry = OutputGeometry(
            orientedSize: source.orientedSize, crop: plan.crop, maxLongEdge: plan.output.maxLongEdge
        )
        var layer = AVVideoCompositionLayerInstruction.Configuration(trackID: videoTrack.trackID)
        layer.setTransform(
            geometry.transform(naturalSize: source.naturalSize, preferredTransform: source.preferredTransform),
            at: .zero
        )
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: composition.duration)
        ))

        // Rec. 709 output makes AVFoundation tone-map HDR sources (HLG, HDR10, Dolby Vision) to SDR,
        // and every consumer of this composition converts the same way.
        let videoComposition = AVVideoComposition(configuration: .init(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            frameDuration: plan.frameDuration,
            instructions: [instruction],
            renderSize: geometry.renderSize
        ))

        return RenderGraph(
            composition: composition.copy() as! AVComposition,
            videoComposition: videoComposition,
            videoTrackID: videoTrack.trackID,
            audioTrackIDs: audioTrackIDs,
            renderSize: geometry.renderSize,
            outputDuration: plan.renderedDuration,
            audioTimePitchAlgorithm: .spectral,
            audioRetimer: audioRetimer
        )
    }
}
