import AVFoundation
import CoreMedia

public enum SourceMediaError: Error, LocalizedError {
    case noVideoTrack
    case unreadable(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "This file doesn’t contain a video track that can be decoded."
        case let .unreadable(underlying):
            "The video couldn’t be read. \(underlying.localizedDescription)"
        }
    }
}

/// A loaded source video and the facts about it that editing and rendering need.
///
/// `@unchecked` because `AVAssetTrack` isn’t marked Sendable; the tracks are never mutated after
/// loading and are only read through AVFoundation’s thread-safe loading APIs.
public struct SourceMedia: @unchecked Sendable {
    public let url: URL
    public let asset: AVURLAsset
    public let duration: CMTime
    public let videoTrack: AVAssetTrack
    /// Encoded pixel size, before the track's preferred transform.
    public let naturalSize: CGSize
    public let preferredTransform: CGAffineTransform
    public let nominalFrameRate: Float
    /// The single audio track that rendering uses, or nil for a silent source.
    public let audioTrack: AVAssetTrack?
    /// HLG, HDR10 or Dolby Vision video.
    public let isHDR: Bool
    /// When, on which camera and where the video was recorded, as far as its metadata says.
    public let capture: CaptureMetadata

    /// Size as displayed, with the preferred transform applied.
    public var orientedSize: CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    public static func load(_ url: URL) async throws -> SourceMedia {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let duration = try await asset.load(.duration)
            guard let videoTrack = try await firstEnabledTrack(of: asset, mediaType: .video) else {
                throw SourceMediaError.noVideoTrack
            }
            let (naturalSize, transform, frameRate, characteristics) = try await videoTrack.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .mediaCharacteristics
            )
            return SourceMedia(
                url: url,
                asset: asset,
                duration: duration,
                videoTrack: videoTrack,
                naturalSize: naturalSize,
                preferredTransform: transform,
                nominalFrameRate: frameRate,
                audioTrack: try await preferredAudioTrack(of: asset),
                isHDR: characteristics.contains(.containsHDRVideo),
                capture: try await captureMetadata(of: asset)
            )
        } catch let error as SourceMediaError {
            throw error
        } catch {
            throw SourceMediaError.unreadable(underlying: error)
        }
    }

    /// iPhone writes QuickTime metadata; other cameras and apps often write only the common keys.
    private static func captureMetadata(of asset: AVAsset) async throws -> CaptureMetadata {
        let items = try await asset.load(.metadata)
        func string(_ identifiers: AVMetadataIdentifier...) async -> String? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
                }
            }
            return nil
        }
        var capture = CaptureMetadata(
            make: await string(.quickTimeMetadataMake, .commonIdentifierMake),
            model: await string(.quickTimeMetadataModel, .commonIdentifierModel),
            software: await string(.quickTimeMetadataSoftware, .commonIdentifierSoftware)
        )
        if let text = await string(.quickTimeMetadataCreationDate, .commonIdentifierCreationDate),
           let parsed = CaptureMetadata.parseCreationDate(text) {
            capture.date = parsed.date
            capture.timeZoneOffset = parsed.offset
        } else {
            capture.date = try? await asset.load(.creationDate)?.load(.dateValue)
        }
        if let text = await string(.quickTimeMetadataLocationISO6709, .commonIdentifierLocation),
           var location = CaptureLocation(iso6709: text) {
            let accuracy = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.location.accuracy.horizontal")
            location.horizontalAccuracy = await string(accuracy).flatMap(Double.init)
            capture.location = location
        }
        return capture
    }

    private static func firstEnabledTrack(of asset: AVAsset, mediaType: AVMediaType) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        for track in tracks where try await track.load(.isEnabled) {
            return track
        }
        return tracks.first
    }

    /// iPhone recordings carry a stereo AAC track plus a multichannel spatial track; mixing both
    /// would double the sound, so pick one, preferring an enabled AAC or PCM track.
    private static func preferredAudioTrack(of asset: AVAsset) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var enabled: [AVAssetTrack] = []
        for track in tracks where try await track.load(.isEnabled) {
            enabled.append(track)
        }
        let candidates = enabled.isEmpty ? tracks : enabled
        for track in candidates {
            let formats = try await track.load(.formatDescriptions)
            let subtypes = formats.map(\.mediaSubType.rawValue)
            if subtypes.contains(kAudioFormatMPEG4AAC) || subtypes.contains(kAudioFormatLinearPCM) {
                return track
            }
        }
        return candidates.first
    }
}
