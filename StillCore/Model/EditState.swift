import CoreGraphics
import CoreMedia
import Foundation

/// Something the UI should briefly tell the user after an edit.
public enum EditNotice: Sendable, Equatable {
    /// A trim excluded the Key Photo, so it moved to the nearest valid frame.
    case keyPhotoMovedInsideSelection
    /// A trim stopped where the output would leave the supported length.
    case durationLimit(ClosedRange<Double>)
    /// A speed change would have left the supported length, so the selection was resized around the Key Photo.
    case selectionResizedForSpeed(ClosedRange<Double>)

    public var message: String {
        switch self {
        case .keyPhotoMovedInsideSelection:
            String(localized: "Key Photo moved inside the selection.", bundle: #bundle)
        case let .durationLimit(range):
            String(localized: "A Live Photo can be \(range.lowerBound, format: .decimals(0)) to \(range.upperBound, format: .decimals(0)) seconds long.", bundle: #bundle)
        case let .selectionResizedForSpeed(range):
            String(localized: "Selection resized to keep the Live Photo between \(range.lowerBound, format: .decimals(0)) and \(range.upperBound, format: .decimals(0)) seconds.", bundle: #bundle)
        }
    }
}

/// An edit the rules don’t allow; the state is left unchanged.
public enum EditRejection: Error, Sendable, Equatable, LocalizedError {
    case sourceTooShort(seconds: Double, minimum: Double)
    case needsMoreSource(required: Double, available: Double)
    case durationOutOfRange(target: Double, range: ClosedRange<Double>)
    case unsupportedSpeed(Double)
    case invalidAspectRatio

    public var errorDescription: String? {
        switch self {
        case let .sourceTooShort(seconds, minimum):
            String(localized: "This video is \(seconds, format: .decimals(2)) s long. A Live Photo needs at least \(minimum, format: .decimals(1)) s of video.", bundle: #bundle)
        case let .needsMoreSource(required, available):
            String(localized: "Needs \(required, format: .decimals(1)) s of video; this one is \(available, format: .decimals(1)) s.", bundle: #bundle)
        case let .durationOutOfRange(_, range):
            String(localized: "Choose a duration from \(range.lowerBound, format: .decimals(0)) to \(range.upperBound, format: .decimals(0)) seconds.", bundle: #bundle)
        case let .unsupportedSpeed(speed):
            String(localized: "\(speed, format: .number)× isn’t a supported speed.", bundle: #bundle)
        case .invalidAspectRatio:
            String(localized: "Enter a positive width and height.", bundle: #bundle)
        }
    }
}

/// What the edit is saved as.
public enum OutputKind: String, Sendable, CaseIterable {
    /// A Key Photo and up to 15 seconds of motion.
    case livePhoto
    /// A plain video of any length, at the size its choices give: a trimmed, cropped or smaller copy.
    case video
}

/// The authoritative editing state and the rules that change it.
///
/// A value type: every edit produces a complete new state, which makes undo a stack of snapshots.
/// Times are source seconds unless a name says “output”.
public struct EditState: Sendable, Equatable {
    public static let speeds: [Double] = [0.5, 0.75, 1, 1.5, 2]
    public static let defaultDuration = 3.0
    /// Sources shorter than this can’t reach the one-second minimum even at 0.5×.
    public static let minimumSourceDuration = 0.5
    /// Shortest selection a trim handle can make.
    public static let minimumSelectionLength = 0.1
    /// Below this longer edge, the inspector warns about resolution without blocking export.
    public static let lowResolutionLongEdge: CGFloat = 1080

    private static let tolerance = 1e-6

    public let source: SourceInfo
    public private(set) var kind = OutputKind.livePhoto
    /// The Live Photo's settings, kept while the edit is a video.
    public private(set) var livePhotoOutput: OutputSettings
    /// The video's choices, kept while the edit is a Live Photo; nil when the facts a video needs aren't known.
    public private(set) var video: VideoCompression?
    public private(set) var selectionStart: Double
    public private(set) var selectionEnd: Double
    public private(set) var speed: Double
    public private(set) var keyPhotoTime: Double
    public private(set) var cropAspect: CropAspect
    /// Normalized to the oriented source; see `CropGeometry`.
    public private(set) var cropRect: CGRect
    public private(set) var includesAudio: Bool
    /// Off unless the user turns it on: a location is personal.
    public private(set) var includesLocation = false
    /// A location the user chose, replacing the video's own.
    public private(set) var chosenLocation: CaptureLocation?
    /// Captions of what's said, drawn into the video. The words come from transcribing the sound, which the editor
    /// does; the plan carries them only once they're known.
    public private(set) var includesCaptions = false

    /// The initial editing state for a newly opened source, a Live Photo to begin with. `video`, the facts a plain
    /// video's choices depend on, lets the edit become one.
    public init(source: SourceInfo, output: OutputSettings = .standard, video: CompressionSource? = nil) throws {
        guard source.duration >= Self.minimumSourceDuration - Self.tolerance else {
            throw EditRejection.sourceTooShort(seconds: source.duration, minimum: Self.minimumSourceDuration)
        }
        self.source = source
        livePhotoOutput = output
        // HDR videos keep their HDR unless the user turns it off.
        livePhotoOutput.dynamicRange = source.isHDR ? .high : .standard
        self.video = video.map(VideoCompression.init)
        speed = 1
        cropAspect = .original
        cropRect = CropGeometry.fullFrame
        includesAudio = source.hasAudio
        selectionStart = 0
        // Short sources use everything, without padding or a silent speed change.
        selectionEnd = min(Self.defaultDuration, source.duration)
        keyPhotoTime = (selectionStart + selectionEnd) / 2
        clampKeyPhoto()
    }

    // MARK: - Derived values

    /// What the edit renders with: the Live Photo's settings, or the video's choices.
    public var output: OutputSettings {
        guard kind == .video, let video else { return livePhotoOutput }
        var settings = video.output
        // Any length the source and the speeds allow: the shortest selection at the fastest speed up to all of it at
        // the slowest.
        let shortest = Self.minimumSelectionLength / (Self.speeds.last ?? 1)
        settings.durationRange = shortest...max(source.duration / (Self.speeds.first ?? 1), 1)
        return settings
    }

    /// Whether the edit can become a plain video.
    public var canMakeVideo: Bool { video != nil }

    /// Whether a video keeps the source's frames and their timing, as a copy at its own frame rate and speed does.
    public var keepsFrameTiming: Bool {
        kind == .video && speed == 1 && video?.keepsOriginalFrameRate == true
    }

    public var selectionLength: Double { selectionEnd - selectionStart }

    /// Output duration = selected source duration / playback speed.
    public var outputDuration: Double { selectionLength / speed }

    /// Key Photo output time = (Key Photo source time − selection start) / speed.
    public var keyPhotoOutputTime: Double { (keyPhotoTime - selectionStart) / speed }

    /// Distinct source frames per output second: source frame rate × speed.
    public var motionRate: Double { source.frameRate * speed }

    /// True when frames will visibly repeat. Allows 5% under the output rate, so 29.97 fps sources at 1×
    /// aren’t flagged.
    public var isMotionChoppy: Bool { motionRate < Double(output.frameRate) * 0.95 }

    public var plan: EditPlan {
        EditPlan(
            selection: CMTimeRange(start: .seconds(selectionStart), end: .seconds(selectionEnd)),
            speed: speed,
            keyPhotoSourceTime: .seconds(keyPhotoTime),
            includesAudio: includesAudio,
            crop: cropRect,
            output: output,
            location: includedLocation
        )
    }

    /// Why export is disabled, if it is.
    public var exportIssue: EditPlanIssue? {
        plan.issue(sourceDuration: .seconds(source.duration))
    }

    /// The one-click fix offered when the output is under the minimum: 0.5× when that is enough.
    public var suggestedSpeed: Double? {
        guard case .outputTooShort = exportIssue, let slowest = Self.speeds.first, slowest < speed else { return nil }
        let slowed = selectionLength / slowest
        return slowed >= output.durationRange.lowerBound - Self.tolerance
            && slowed <= output.durationRange.upperBound + Self.tolerance ? slowest : nil
    }

    /// Source times the Key Photo may take: the selection start through the last rendered output frame.
    public var keyPhotoRange: ClosedRange<Double> {
        let lastFrame = Double(max(plan.outputFrameCount - 1, 0)) / Double(output.frameRate)
        return selectionStart...min(selectionEnd, selectionStart + lastFrame * speed)
    }

    public var outputGeometry: OutputGeometry {
        OutputGeometry(orientedSize: source.orientedSize, crop: cropRect, maxLongEdge: output.maxLongEdge)
    }

    /// The output size `resolution` would give with the current crop.
    public func renderSize(at resolution: OutputResolution) -> CGSize {
        OutputGeometry(orientedSize: source.orientedSize, crop: cropRect, maxLongEdge: resolution.maxLongEdge).renderSize
    }

    /// The current resolution choice; nil when the output settings use a size outside the choices.
    public var resolution: OutputResolution? { OutputResolution(maxLongEdge: output.maxLongEdge) }

    /// The current bit rate choice; nil when the output settings use a rate outside the choices.
    public var bitRate: VideoBitRate? {
        kind == .video ? video?.bitRate : VideoBitRate(bitsPerPixel: output.bitsPerPixel)
    }

    /// The choice the menus show as chosen: the smallest that gives the current size. On a 720p video, 1080p gives
    /// the same size as 720p, so 720p shows as chosen even while 1080p is the one remembered; the remembered choice
    /// still applies once the video or crop is larger. Nil when the size is outside the choices.
    public var shownResolution: OutputResolution? {
        let size = outputGeometry.renderSize
        return OutputResolution.allCases
            .sorted { $0.maxLongEdge < $1.maxLongEdge }
            .first { renderSize(at: $0) == size }
    }

    /// A resolution is unavailable when it gives the same size as a smaller one, because the video or crop isn't
    /// larger: choosing it would change nothing. The shown choice is always available, since it is the smallest.
    public func isResolutionAvailable(_ candidate: OutputResolution) -> Bool {
        let size = renderSize(at: candidate)
        return !OutputResolution.allCases.contains { $0.maxLongEdge < candidate.maxLongEdge && renderSize(at: $0) == size }
    }

    /// The video's average bit rate, in bits per second, at `bitRate` and the current size.
    public func videoBitRate(at bitRate: VideoBitRate) -> Int {
        var settings = output
        // A video's rates are lower than a Live Photo's, as a camera's are; see `compressionBitsPerPixel`.
        settings.bitsPerPixel = kind == .video ? video?.bitsPerPixel(at: bitRate) ?? 0 : bitRate.bitsPerPixel
        return settings.averageVideoBitRate(for: outputGeometry.renderSize)
    }

    public var isLowResolution: Bool {
        let size = outputGeometry.renderSize
        return max(size.width, size.height) < Self.lowResolutionLongEdge
    }

    public var canIncludeAudio: Bool { source.hasAudio }

    /// Captions come from the video's speech, whether or not the Live Photo keeps the sound.
    public var canIncludeCaptions: Bool { source.hasAudio }

    public var canUseHDR: Bool { source.isHDR }

    /// Whether HDR can be kept with the current choices: HDR is HEVC only, so a video in H.264 is standard range, as
    /// iPhone records Most Compatible.
    public var canKeepHDR: Bool { kind == .video ? video?.canKeepHDR == true : source.isHDR }

    /// The location the Live Photo would carry: the one the user chose, or else the video's.
    public var location: CaptureLocation? { chosenLocation ?? source.location }

    public var canIncludeLocation: Bool { location != nil }

    /// What the Live Photo will carry.
    public var includedLocation: CaptureLocation? { includesLocation ? location : nil }

    public var isHDR: Bool { output.dynamicRange == .high }

    /// A speed is unavailable when even the whole source would make less than the minimum output at it.
    /// The current speed always stays available, so the control never disables its own selection.
    public func unavailabilityReason(forSpeed candidate: Double) -> EditRejection? {
        guard candidate != speed else { return nil }
        let required = output.durationRange.lowerBound * candidate
        return required > source.duration + Self.tolerance
            ? .needsMoreSource(required: required, available: source.duration)
            : nil
    }

    /// About how many bytes the Live Photo takes: the video at its average bit rate, the sound, and the JPEG.
    public var estimatedFileSize: Int64 { estimatedFileSize(calibration: nil) }

    /// The estimate, adjusted to how this video actually encodes when `calibration` is available.
    ///
    /// The bit rate is the encoder's target, not a promise: detailed footage overshoots it a little, and simple
    /// footage leaves most of it unused, more so at higher bit rates and sizes. The JPEG's size varies with
    /// detail too.
    public func estimatedFileSize(calibration: SizeCalibration?) -> Int64 {
        estimatedSizes(calibration: calibration).total
    }

    /// The estimate in its two parts: the Key Photo and the movie with its sound.
    public func estimatedSizes(calibration: SizeCalibration?) -> SizeEstimate {
        let size = outputGeometry.renderSize
        let pixels = Double(size.width * size.height)
        var videoBits = Double(output.averageVideoBitRate(for: size)) * outputDuration
        if kind == .video {
            if let calibration, calibration.pixelCount > 0 {
                videoBits *= SizeCalibration.rateFactor(calibration.videoRateFactor, scaledBy: max(pixels / calibration.pixelCount, 1))
            }
            // AAC sound goes in as it is at its own speed; otherwise it's encoded, as `VideoExporter` does.
            let sound = video?.source.audio.map { speed == 1 ? $0.outputBitRate : Double($0.encodedBitRate) } ?? 0
            let audioBits = includesAudio ? sound * outputDuration : 0
            return SizeEstimate(photo: 0, video: Int64((videoBits + audioBits) / 8))
        }
        // JPEG at quality 0.92 averages about a third of a byte per pixel on camera footage. An HDR gain map adds
        // about a quarter.
        var jpegBytes = pixels * (isHDR ? 0.45 : 0.35)
        if let calibration, calibration.pixelCount > 0 {
            let ratio = max(pixels / calibration.pixelCount, 1)
            videoBits *= SizeCalibration.rateFactor(calibration.videoRateFactor, scaledBy: ratio)
            jpegBytes = calibration.photoBytesPerPixel * calibration.pixelCount * pow(ratio, SizeCalibration.photoExponent)
        }
        let audioBits = includesAudio ? 128_000 * outputDuration : 0
        return SizeEstimate(photo: Int64(jpegBytes), video: Int64((videoBits + audioBits) / 8))
    }

    public func isSpeedAvailable(_ candidate: Double) -> Bool {
        unavailabilityReason(forSpeed: candidate) == nil
    }

    // MARK: - Time mapping

    public func isInsideSelection(_ time: Double) -> Bool {
        time >= selectionStart - Self.tolerance && time <= selectionEnd + Self.tolerance
    }

    /// Source time that output frame `index` shows.
    public func sourceTime(ofOutputFrame index: Int64) -> Double {
        selectionStart + Double(index) / Double(output.frameRate) * speed
    }

    /// Output time for a source time inside the selection.
    public func outputTime(atSourceTime time: Double) -> Double {
        (time - selectionStart) / speed
    }

    /// The output frame showing `time`, clamped to the rendered frames.
    public func outputFrame(atSourceTime time: Double) -> Int64 {
        let index = Int64((outputTime(atSourceTime: time) * Double(output.frameRate) + 1e-6).rounded(.down))
        return min(max(index, 0), max(plan.outputFrameCount - 1, 0))
    }

    // MARK: - Moment and Key Photo

    /// Make Key Photo. Inside the selection, the Key Photo moves to `time` and the selection
    /// stays where it is. Outside it, the selection first comes to `time`, centering on it.
    public mutating func makeKeyPhoto(at time: Double) {
        if isInsideSelection(time) {
            setKeyPhoto(at: time)
        } else {
            centerSelection(onKeyPhotoAt: time)
        }
    }

    /// The Key Photo goes to `time`, and the selection centers on it in output time, keeping its length
    /// and shifting inward near either end of the source.
    public mutating func centerSelection(onKeyPhotoAt time: Double) {
        let key = min(max(time, 0), source.duration)
        place(start: key - selectionLength / 2, length: selectionLength)
        keyPhotoTime = key
        clampKeyPhoto()
    }

    /// Sets the Key Photo without moving the selection; times outside it are clamped.
    public mutating func setKeyPhoto(at time: Double) {
        keyPhotoTime = time
        clampKeyPhoto()
    }

    // MARK: - Selection

    /// Moves the whole selection. The Key Photo travels with it, keeping its output time.
    public mutating func moveSelection(toStart start: Double) {
        let keyOffset = keyPhotoTime - selectionStart
        place(start: start, length: selectionLength)
        keyPhotoTime = selectionStart + keyOffset
        clampKeyPhoto()
    }

    /// Start-bracket drag: trims the start, as on iPhone. The bracket stops where the output would leave the
    /// supported length.
    @discardableResult
    public mutating func setSelectionStart(_ time: Double) -> EditNotice? {
        let lengths = allowedSelectionLengths
        let requested = max(0, min(time, selectionEnd - Self.minimumSelectionLength))
        selectionStart = min(max(time, selectionEnd - lengths.upperBound, 0), selectionEnd - lengths.lowerBound)
        return finishTrim(limited: abs(selectionStart - requested) > Self.tolerance)
    }

    /// End-bracket drag: trims the end; see `setSelectionStart(_:)`.
    @discardableResult
    public mutating func setSelectionEnd(_ time: Double) -> EditNotice? {
        let lengths = allowedSelectionLengths
        let requested = min(source.duration, max(time, selectionStart + Self.minimumSelectionLength))
        selectionEnd = max(min(time, selectionStart + lengths.upperBound, source.duration), selectionStart + lengths.lowerBound)
        return finishTrim(limited: abs(selectionEnd - requested) > Self.tolerance)
    }

    /// Source lengths a trim may produce at the current speed: those giving the supported output length.
    /// A selection already below the minimum, as in a source too short for it, may stay as it is.
    private var allowedSelectionLengths: ClosedRange<Double> {
        let range = output.durationRange
        let shortest = max(Self.minimumSelectionLength, min(range.lowerBound * speed, selectionLength))
        return shortest...max(shortest, range.upperBound * speed)
    }

    private mutating func finishTrim(limited: Bool) -> EditNotice? {
        if let notice = keepKeyPhotoInside() { return notice }
        return limited ? .durationLimit(output.durationRange) : nil
    }

    // MARK: - Speed and duration

    /// Keeps the selected moment, so the output gets longer when slower and shorter when faster. When that
    /// would leave the supported length, the selection resizes around the Key Photo to the nearest limit.
    @discardableResult
    public mutating func setSpeed(_ newSpeed: Double) throws -> EditNotice? {
        guard Self.speeds.contains(newSpeed) else { throw EditRejection.unsupportedSpeed(newSpeed) }
        if let reason = unavailabilityReason(forSpeed: newSpeed) { throw reason }
        speed = newSpeed
        let range = output.durationRange
        let fitted = min(max(outputDuration, range.lowerBound), range.upperBound)
        guard abs(fitted - outputDuration) > Self.tolerance else {
            clampKeyPhoto()
            return nil
        }
        resize(toLength: min(fitted * newSpeed, source.duration))
        return .selectionResizedForSpeed(range)
    }

    /// The Duration field: the selection resizes around the Key Photo to give this output length.
    public mutating func setOutputDuration(_ target: Double) throws {
        let range = output.durationRange
        guard target >= range.lowerBound - Self.tolerance, target <= range.upperBound + Self.tolerance else {
            throw EditRejection.durationOutOfRange(target: target, range: range)
        }
        let required = target * speed
        guard required <= source.duration + Self.tolerance else {
            throw EditRejection.needsMoreSource(required: required, available: source.duration)
        }
        resize(toLength: min(required, source.duration))
    }

    // MARK: - Audio

    /// Ignored for sources without audio.
    public mutating func setIncludesAudio(_ include: Bool) {
        includesAudio = include && source.hasAudio
    }

    /// Ignored for sources without audio, which have nothing to caption.
    public mutating func setIncludesCaptions(_ include: Bool) {
        includesCaptions = include && canIncludeCaptions
    }

    // MARK: - Output

    /// Makes the edit a Live Photo or a video, each with its own resolution, bit rate and HDR choices. A Live Photo's
    /// length is limited, so a longer selection shortens around the Key Photo. Ignored for a video when its facts aren't
    /// known.
    @discardableResult
    public mutating func setKind(_ newKind: OutputKind) -> EditNotice? {
        guard newKind != kind, newKind == .livePhoto || video != nil else { return nil }
        kind = newKind
        let range = output.durationRange
        let fitted = min(max(outputDuration, range.lowerBound), range.upperBound)
        guard abs(fitted - outputDuration) > Self.tolerance else {
            clampKeyPhoto()
            return nil
        }
        resize(toLength: min(fitted * speed, source.duration))
        return .selectionResizedForSpeed(range)
    }

    /// Selects all of the source, or as much as the output's length allows, with the Key Photo in the middle.
    public mutating func selectAll() {
        place(start: 0, length: min(source.duration, allowedSelectionLengths.upperBound))
        keyPhotoTime = (selectionStart + selectionEnd) / 2
        clampKeyPhoto()
    }

    /// Changes the video's choices, whether or not the edit is a video now: its frame rate and format, or choices
    /// remembered from an earlier video. Ignored when its facts aren't known.
    public mutating func updateVideo(_ change: (inout VideoCompression) -> Void) {
        guard var next = video else { return }
        change(&next)
        video = next
    }

    public mutating func setResolution(_ resolution: OutputResolution) {
        if kind == .video {
            updateVideo { $0.setResolution(resolution) }
        } else {
            livePhotoOutput.maxLongEdge = resolution.maxLongEdge
        }
    }

    public mutating func setBitRate(_ bitRate: VideoBitRate) {
        if kind == .video {
            updateVideo { $0.setBitRate(bitRate) }
        } else {
            livePhotoOutput.bitsPerPixel = bitRate.bitsPerPixel
        }
    }

    /// Ignored while there's no location to include.
    public mutating func setIncludesLocation(_ include: Bool) {
        includesLocation = include && location != nil
    }

    /// Choosing a location includes it.
    public mutating func chooseLocation(_ chosen: CaptureLocation) {
        chosenLocation = chosen
        includesLocation = true
    }

    /// Back to the video's own location, or to none if it has none.
    public mutating func clearChosenLocation() {
        chosenLocation = nil
        includesLocation = includesLocation && location != nil
    }

    /// Ignored for SDR sources, which have no HDR to keep. A video remembers the choice while it's in H.264, so HDR comes
    /// back with HEVC.
    public mutating func setHDR(_ on: Bool) {
        if kind == .video {
            updateVideo { $0.setKeepsHDR(on) }
        } else {
            livePhotoOutput.dynamicRange = on && source.isHDR ? .high : .standard
        }
    }

    // MARK: - Crop

    /// Fixed ratios take the largest rectangle that fits, centered where the crop was.
    public mutating func setCropAspect(_ aspect: CropAspect) throws {
        guard aspect.isValid else { throw EditRejection.invalidAspectRatio }
        cropAspect = aspect
        switch aspect {
        case .original:
            cropRect = CropGeometry.fullFrame
        case .freeform:
            break
        case .ratio, .custom:
            cropRect = CropGeometry.largestRect(
                pixelRatio: aspect.pixelRatio(for: source.orientedSize)!,
                centeredOn: CGPoint(x: cropRect.midX, y: cropRect.midY),
                sourceSize: source.orientedSize
            )
        }
    }

    /// Moves or resizes the crop, enforcing the current ratio and keeping it inside the frame.
    public mutating func setCropRect(_ rect: CGRect) {
        let ratio = cropAspect == .freeform ? nil : cropAspect.pixelRatio(for: source.orientedSize)
        cropRect = CropGeometry.constrain(rect, pixelRatio: ratio, sourceSize: source.orientedSize)
    }

    public mutating func resetCrop() {
        cropAspect = .original
        cropRect = CropGeometry.fullFrame
    }

    // MARK: - Helpers

    private mutating func place(start: Double, length: Double) {
        let clampedStart = min(max(start, 0), max(0, source.duration - length))
        selectionStart = clampedStart
        selectionEnd = min(clampedStart + length, source.duration)
    }

    /// Keeps the Key Photo at the same fraction of the selection.
    private mutating func resize(toLength length: Double) {
        let fraction = selectionLength > 0 ? (keyPhotoTime - selectionStart) / selectionLength : 0.5
        place(start: keyPhotoTime - fraction * length, length: length)
        clampKeyPhoto()
    }

    private mutating func clampKeyPhoto() {
        let range = keyPhotoRange
        keyPhotoTime = min(max(keyPhotoTime, range.lowerBound), range.upperBound)
    }

    /// Notices only when the trim actually excluded the Key Photo, not for sub-frame snapping.
    private mutating func keepKeyPhotoInside() -> EditNotice? {
        let excluded = keyPhotoTime < selectionStart - Self.tolerance || keyPhotoTime > selectionEnd + Self.tolerance
        clampKeyPhoto()
        return excluded ? .keyPhotoMovedInsideSelection : nil
    }
}

/// How this video actually encoded in a smaller render of the same edit, such as the Live Photo preview. The
/// size estimate scales it to the output size.
public struct SizeCalibration: Sendable, Equatable {
    /// The video bit rate the encoder spent, as a share of the rate it was asked for.
    public var videoRateFactor: Double
    /// Key Photo bytes per pixel.
    public var photoBytesPerPixel: Double
    /// Pixels in the render measured.
    public var pixelCount: Double

    public init(videoRateFactor: Double, photoBytesPerPixel: Double, pixelCount: Double) {
        self.videoRateFactor = videoRateFactor
        self.photoBytesPerPixel = photoBytesPerPixel
        self.pixelCount = pixelCount
    }

    /// The share of the target bit rate at `ratio` times the measured pixels. Footage that overshoots overshoots
    /// less at larger sizes, and footage that leaves bits unused leaves more unused: larger frames have less
    /// detail per pixel. The exponent fits three clips (detailed, typical and a test pattern) measured from the
    /// 720-pixel preview to 1080p and 4K.
    static func rateFactor(_ factor: Double, scaledBy ratio: Double) -> Double {
        let scale = pow(ratio, -0.45)
        return factor >= 1 ? 1 + (factor - 1) * scale : factor * scale
    }

    /// JPEG bytes grow with about the 0.8th power of the pixel count, for the same reason.
    static let photoExponent = 0.8
}

/// About how many bytes each file of a Live Photo takes.
public struct SizeEstimate: Sendable, Equatable {
    /// The Key Photo JPEG. Photos' info panel shows only this part.
    public var photo: Int64
    /// The paired movie, sound included.
    public var video: Int64

    public var total: Int64 { photo + video }
}
