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
            "Key Photo moved inside the selection."
        case let .durationLimit(range):
            String(format: "A Live Photo can be %.0f to %.0f seconds long.", range.lowerBound, range.upperBound)
        case let .selectionResizedForSpeed(range):
            String(format: "Selection resized to keep the Live Photo between %.0f and %.0f seconds.", range.lowerBound, range.upperBound)
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
            String(format: "This video is %.2f s long. A Live Photo needs at least %.1f s of video.", seconds, minimum)
        case let .needsMoreSource(required, available):
            String(format: "Needs %.1f s of video; this one is %.1f s.", required, available)
        case let .durationOutOfRange(_, range):
            String(format: "Choose a duration from %.0f to %.0f seconds.", range.lowerBound, range.upperBound)
        case let .unsupportedSpeed(speed):
            "\(speed)× isn’t a supported speed."
        case .invalidAspectRatio:
            "Enter a positive width and height."
        }
    }
}

/// The authoritative editing state (goal.md §12) and the rules that change it (§5–§9).
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
    public let output: OutputSettings
    public private(set) var selectionStart: Double
    public private(set) var selectionEnd: Double
    public private(set) var speed: Double
    public private(set) var keyPhotoTime: Double
    public private(set) var cropAspect: CropAspect
    /// Normalized to the oriented source; see `CropGeometry`.
    public private(set) var cropRect: CGRect
    public private(set) var includesAudio: Bool

    /// The initial editing state for a newly opened source (goal.md §5).
    public init(source: SourceInfo, output: OutputSettings = .standard) throws {
        guard source.duration >= Self.minimumSourceDuration - Self.tolerance else {
            throw EditRejection.sourceTooShort(seconds: source.duration, minimum: Self.minimumSourceDuration)
        }
        self.source = source
        self.output = output
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
            output: output
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

    public var isLowResolution: Bool {
        let size = outputGeometry.renderSize
        return max(size.width, size.height) < Self.lowResolutionLongEdge
    }

    public var canIncludeAudio: Bool { source.hasAudio }

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
    public var estimatedFileSize: Int64 {
        let size = outputGeometry.renderSize
        let pixels = Double(size.width * size.height)
        let videoBits = pixels * Double(output.frameRate) * output.bitsPerPixel * outputDuration
        let audioBits = includesAudio ? 128_000 * outputDuration : 0
        // JPEG at quality 0.92 averages about a third of a byte per pixel on camera footage.
        let jpegBytes = pixels * 0.35
        return Int64((videoBits + audioBits) / 8 + jpegBytes)
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

    /// Make Key Photo (goal.md §7). Inside the selection, the Key Photo moves to `time` and the selection
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
