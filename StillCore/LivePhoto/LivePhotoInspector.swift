import AVFoundation
import CoreMedia
import ImageIO
import Photos
import Synchronization

/// What an exported pair actually contains, read back from the files.
public struct LivePhotoInspection: Sendable {
    public let imageContentIdentifier: String?
    public let videoContentIdentifier: String?
    public let stillImageTime: CMTime?
    public let imagePixelSize: CGSize
    public let videoPixelSize: CGSize
    public let videoDuration: CMTime
    public let videoFrameCount: Int
    public let videoCodec: FourCharCode?
    public let hasAudio: Bool

    public var identifiersMatch: Bool {
        imageContentIdentifier != nil && imageContentIdentifier == videoContentIdentifier
    }
}

public enum LivePhotoPairingResult: Sendable, Equatable {
    case paired
    case failed(String)
    case timedOut
}

public enum LivePhotoInspector {
    public static func inspect(imageURL: URL, videoURL: URL) async throws -> LivePhotoInspection {
        let image = imageInfo(at: imageURL)
        let asset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.metadata)
        let identifierItem = AVMetadataItem.metadataItems(
            from: metadata, filteredByIdentifier: LivePhotoMetadata.contentIdentifierIdentifier
        ).first
        let videoIdentifier = try await identifierItem?.load(.stringValue)

        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        var videoSize = CGSize.zero
        var codec: FourCharCode?
        var frameCount = 0
        if let videoTrack {
            let (size, formats) = try await videoTrack.load(.naturalSize, .formatDescriptions)
            videoSize = size
            codec = formats.first?.mediaSubType.rawValue
            frameCount = try countSamples(in: videoTrack, of: asset)
        }

        return LivePhotoInspection(
            imageContentIdentifier: image.contentIdentifier,
            videoContentIdentifier: videoIdentifier,
            stillImageTime: try await stillImageTime(in: asset),
            imagePixelSize: image.size,
            videoPixelSize: videoSize,
            videoDuration: duration,
            videoFrameCount: frameCount,
            videoCodec: codec,
            hasAudio: !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        )
    }

    /// Asks Photos to load the pair as a Live Photo without touching the library.
    ///
    /// This is the automated pairing check (goal.md §13, Goal A inner loop).
    public static func checkPairing(imageURL: URL, videoURL: URL) async -> LivePhotoPairingResult {
        do {
            _ = try await loadLivePhoto(imageURL: imageURL, videoURL: videoURL)
            return .paired
        } catch LivePhotoLoadError.timedOut {
            return .timedOut
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Loads the pair as a full-quality `PHLivePhoto`, for preview or validation.
    public static func loadLivePhoto(
        imageURL: URL,
        videoURL: URL,
        timeout: Duration = .seconds(30)
    ) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { continuation in
            let resume = ResumeOnce(continuation)
            PHLivePhoto.request(
                withResourceFileURLs: [imageURL, videoURL],
                placeholderImage: nil,
                targetSize: .zero,
                contentMode: .aspectFit
            ) { @Sendable livePhoto, info in
                if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                    resume(.failure(error))
                } else if (info[PHLivePhotoInfoCancelledKey] as? Bool) == true {
                    resume(.failure(LivePhotoLoadError.cancelled))
                } else if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true {
                    return  // A full-quality result follows.
                } else if let livePhoto {
                    resume(.success(livePhoto))
                } else {
                    resume(.failure(LivePhotoLoadError.notRecognized))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                resume(.failure(LivePhotoLoadError.timedOut))
            }
        }
    }

    // MARK: - Reading back

    private static func imageInfo(at url: URL) -> (contentIdentifier: String?, size: CGSize) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (nil, .zero) }
        let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (
            makerApple?[LivePhotoMetadata.makerAppleContentIdentifierKey] as? String,
            CGSize(width: width, height: height)
        )
    }

    private static func stillImageTime(in asset: AVAsset) async throws -> CMTime? {
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            reader.add(output)
            guard reader.startReading() else { continue }
            while let group = adaptor.nextTimedMetadataGroup() {
                let matches = AVMetadataItem.metadataItems(
                    from: group.items, filteredByIdentifier: LivePhotoMetadata.stillImageTimeIdentifier
                )
                if !matches.isEmpty {
                    reader.cancelReading()
                    return group.timeRange.start
                }
            }
        }
        return nil
    }

    private static func countSamples(in track: AVAssetTrack, of asset: AVAsset) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return 0 }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
        }
        return count
    }
}

public enum LivePhotoLoadError: Error, LocalizedError {
    case notRecognized
    case cancelled
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notRecognized: "Photos didn’t recognize these files as a Live Photo."
        case .cancelled: "Loading the Live Photo was cancelled."
        case .timedOut: "Photos didn’t respond while loading the Live Photo."
        }
    }
}

/// Resumes a continuation at most once; the Photos handler can call back several times,
/// and the timeout races it.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Error>?>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = Mutex(continuation)
    }

    func callAsFunction(_ result: Result<T, Error>) {
        let pending = continuation.withLock { value in
            defer { value = nil }
            return value
        }
        pending?.resume(with: result)
    }
}
