import CoreGraphics
import CoreMedia
import Foundation

/// Fixed properties of every rendered output (goal.md §6, §8, §10).
public struct OutputSettings: Sendable, Equatable {
    public enum VideoCodec: Sendable, Equatable {
        case h264
        case hevc
    }

    public var frameRate: Int32
    public var maxLongEdge: Int
    /// Product limit on output length, not a property of the Live Photo format.
    public var durationRange: ClosedRange<Double>
    /// HEVC, as iPhone uses for its own Live Photos; at the same size it keeps more detail than H.264.
    public var videoCodec: VideoCodec
    /// Average encoded bits per pixel per frame. 0.25 is about 16.6 Mbit/s at 1080 × 1920, 30 fps, and keeps
    /// about 90% of the fine detail of a 4K iPhone clip (docs/decisions.md, “Video quality measurements”).
    public var bitsPerPixel: Double
    /// Encoder quality from 0 to 1, where the encoder supports it; nil leaves rate control to the bitrate.
    public var encoderQuality: Double?

    public init(
        frameRate: Int32 = 30,
        maxLongEdge: Int = 1920,
        durationRange: ClosedRange<Double> = 1...5,
        videoCodec: VideoCodec = .hevc,
        bitsPerPixel: Double = 0.25,
        encoderQuality: Double? = nil
    ) {
        self.frameRate = frameRate
        self.maxLongEdge = maxLongEdge
        self.durationRange = durationRange
        self.videoCodec = videoCodec
        self.bitsPerPixel = bitsPerPixel
        self.encoderQuality = encoderQuality
    }

    public static let standard = OutputSettings()
}

/// The editing intent that preview and export both derive from.
///
/// Times are source times unless a property says otherwise. `EditState` produces plans; tests
/// and tools can also build them directly.
public struct EditPlan: Sendable, Equatable {
    public var selection: CMTimeRange
    public var speed: Double
    public var keyPhotoSourceTime: CMTime
    public var includesAudio: Bool
    /// Normalized to the oriented source; see `CropGeometry`.
    public var crop: CGRect
    public var output: OutputSettings

    public init(
        selection: CMTimeRange,
        speed: Double = 1,
        keyPhotoSourceTime: CMTime,
        includesAudio: Bool = true,
        crop: CGRect = CropGeometry.fullFrame,
        output: OutputSettings = .standard
    ) {
        self.selection = selection
        self.speed = speed
        self.keyPhotoSourceTime = keyPhotoSourceTime
        self.includesAudio = includesAudio
        self.crop = crop
        self.output = output
    }

    /// A selection of `duration` source seconds starting at `start`, with the Key Photo in its middle.
    public static func centered(
        start: Double,
        duration: Double,
        speed: Double = 1,
        includesAudio: Bool = true,
        crop: CGRect = CropGeometry.fullFrame
    ) -> EditPlan {
        let selection = CMTimeRange(start: .seconds(start), duration: .seconds(duration))
        return EditPlan(selection: selection, speed: speed, keyPhotoSourceTime: .seconds(start + duration / 2),
                        includesAudio: includesAudio, crop: crop)
    }
}

// MARK: - Derived timing

extension EditPlan {
    /// Output duration = selected source duration / playback speed.
    public var outputDuration: CMTime {
        CMTimeMultiplyByFloat64(selection.duration, multiplier: 1 / speed)
    }

    public var frameDuration: CMTime {
        CMTime(value: 1, timescale: output.frameRate)
    }

    /// Number of constant-rate frames whose presentation time falls inside the output. An overhang under a
    /// thousandth of a frame, from rounding source times, doesn’t add a sliver frame at the end.
    public var outputFrameCount: Int64 {
        let exact = outputDuration.seconds * Double(output.frameRate)
        return max(1, Int64((exact - 1e-3).rounded(.up)))
    }

    /// The length actually rendered: a whole number of output frames, within one frame of `outputDuration`.
    public var renderedDuration: CMTime {
        CMTime(value: outputFrameCount, timescale: output.frameRate)
    }

    /// Key Photo output time = (Key Photo source time − selection start) / speed.
    public var keyPhotoOutputTime: CMTime {
        CMTimeMultiplyByFloat64(keyPhotoSourceTime - selection.start, multiplier: 1 / speed)
    }

    /// Index of the rendered output frame nearest the requested Key Photo time.
    public var keyPhotoFrameIndex: Int64 {
        let nearest = Int64((keyPhotoOutputTime.seconds * Double(output.frameRate)).rounded())
        return min(max(nearest, 0), max(outputFrameCount - 1, 0))
    }

    /// Presentation time of the rendered Key Photo frame, used for the still-image marker.
    public var keyPhotoFrameTime: CMTime {
        CMTime(value: keyPhotoFrameIndex, timescale: output.frameRate)
    }
}

// MARK: - Validation

public enum EditPlanIssue: Error, Equatable, Sendable, LocalizedError {
    case selectionOutsideSource
    case outputTooShort(seconds: Double, minimum: Double)
    case outputTooLong(seconds: Double, maximum: Double)
    case keyPhotoOutsideSelection
    case invalidSpeed
    case invalidCrop

    public var errorDescription: String? {
        switch self {
        case .selectionOutsideSource:
            "The selection extends beyond the video."
        case let .outputTooShort(seconds, minimum):
            String(format: "The Live Photo would be %.2f s long; the minimum is %.0f s.", seconds, minimum)
        case let .outputTooLong(seconds, maximum):
            String(format: "The Live Photo would be %.2f s long; the maximum is %.0f s.", seconds, maximum)
        case .keyPhotoOutsideSelection:
            "The Key Photo is outside the selection."
        case .invalidSpeed:
            "The playback speed must be positive."
        case .invalidCrop:
            "The crop must lie inside the video frame."
        }
    }
}

extension EditPlan {
    /// Returns the first rule this plan breaks for a source of `sourceDuration`, or nil when it can be exported.
    public func issue(sourceDuration: CMTime) -> EditPlanIssue? {
        guard speed > 0, speed.isFinite else { return .invalidSpeed }
        let tolerance = 1e-3
        guard crop.width > 0, crop.height > 0,
              crop.minX >= -tolerance, crop.minY >= -tolerance,
              crop.maxX <= 1 + tolerance, crop.maxY <= 1 + tolerance
        else { return .invalidCrop }
        if selection.start.seconds < -tolerance || selection.end.seconds > sourceDuration.seconds + tolerance {
            return .selectionOutsideSource
        }
        let seconds = outputDuration.seconds
        if seconds < output.durationRange.lowerBound - tolerance {
            return .outputTooShort(seconds: seconds, minimum: output.durationRange.lowerBound)
        }
        if seconds > output.durationRange.upperBound + tolerance {
            return .outputTooLong(seconds: seconds, maximum: output.durationRange.upperBound)
        }
        let key = keyPhotoSourceTime.seconds
        if key < selection.start.seconds - tolerance || key > selection.end.seconds + tolerance {
            return .keyPhotoOutsideSelection
        }
        return nil
    }
}

extension CMTime {
    /// Seconds at a timescale fine enough for frame-accurate editing, rounded to the nearest tick.
    /// (`CMTime(seconds:preferredTimescale:)` truncates, which can lengthen a selection by a tick.)
    public static func seconds(_ value: Double) -> CMTime {
        CMTime(value: CMTimeValue((value * 60_000).rounded()), timescale: 60_000)
    }
}
