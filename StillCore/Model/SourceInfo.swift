import CoreGraphics

/// The facts about a source that editing rules depend on, independent of AVFoundation.
public struct SourceInfo: Sendable, Equatable {
    /// Seconds.
    public var duration: Double
    /// Average frames per second; for variable-frame-rate sources, the measured average.
    public var frameRate: Double
    /// Pixel size as displayed, after the track’s rotation.
    public var orientedSize: CGSize
    public var hasAudio: Bool
    /// HLG, HDR10 or Dolby Vision video.
    public var isHDR: Bool
    /// Whether the video recorded where it was taken.
    public var hasLocation: Bool

    public init(duration: Double, frameRate: Double, orientedSize: CGSize, hasAudio: Bool, isHDR: Bool = false,
                hasLocation: Bool = false) {
        self.duration = duration
        self.frameRate = frameRate
        self.orientedSize = orientedSize
        self.hasAudio = hasAudio
        self.isHDR = isHDR
        self.hasLocation = hasLocation
    }
}

extension SourceMedia {
    public var info: SourceInfo {
        SourceInfo(
            duration: duration.seconds,
            frameRate: Double(nominalFrameRate),
            orientedSize: orientedSize,
            hasAudio: audioTrack != nil,
            isHDR: isHDR,
            hasLocation: capture.location != nil
        )
    }
}
