import CoreGraphics
import Testing
@testable import StillCore

@Suite("Editing rules")
struct EditStateTests {
    private func source(_ duration: Double, fps: Double = 30, size: CGSize = CGSize(width: 1920, height: 1080), audio: Bool = true) -> SourceInfo {
        SourceInfo(duration: duration, frameRate: fps, orientedSize: size, hasAudio: audio)
    }

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - Initial state (§5)

    @Test func longSourceStartsWithLockedThreeSeconds() throws {
        let state = try EditState(source: source(42))
        #expect(state.selectionStart == 0 && state.selectionEnd == 3)
        #expect(state.speed == 1)
        #expect(state.durationLock == DurationLock(isOn: true, target: 3))
        #expect(state.cropAspect == .original && state.cropRect == CropGeometry.fullFrame)
        #expect(close(state.keyPhotoTime, 1.5))
        #expect(state.includesAudio)
        #expect(state.exportIssue == nil)
    }

    @Test func shortSourceUsesEverythingUnlocked() throws {
        let state = try EditState(source: source(2))
        #expect(state.selectionStart == 0 && state.selectionEnd == 2)
        #expect(!state.durationLock.isOn)
        #expect(close(state.outputDuration, 2))
        #expect(state.speed == 1, "Short sources must not silently change speed")
    }

    @Test func silentSourceStartsWithoutAudio() throws {
        var state = try EditState(source: source(10, audio: false))
        #expect(!state.includesAudio && !state.canIncludeAudio)
        state.setIncludesAudio(true)
        #expect(!state.includesAudio)
    }

    @Test func rejectsSourcesThatCanNeverReachOneSecond() {
        #expect(throws: EditRejection.sourceTooShort(seconds: 0.3, minimum: 0.5)) {
            try EditState(source: source(0.3))
        }
    }

    // MARK: - §6 lock and Key Photo examples

    @Test func speedChangeResizesAroundKeyPhoto() throws {
        // Locked at 3 s, 1×, selection 10.5–13.5 s with the Key Photo at 12 s; change to 2×.
        var state = try EditState(source: source(20))
        state.makeKeyPhoto(at: 12)
        #expect(close(state.selectionStart, 10.5) && close(state.selectionEnd, 13.5))
        try state.setSpeed(2)
        #expect(close(state.selectionStart, 9) && close(state.selectionEnd, 15))
        #expect(close(state.keyPhotoTime, 12))
        #expect(close(state.keyPhotoOutputTime, 1.5))
        #expect(close(state.outputDuration, 3))
    }

    @Test func makeKeyPhotoOutsideNearStartShiftsInward() throws {
        // Locked at 3 s, 1×, selection 10–13 s; Make Key Photo at 1.0 s → 0–3 s, Key Photo at output 1.0 s.
        var state = try EditState(source: source(20))
        state.moveSelection(toStart: 10)
        state.makeKeyPhoto(at: 1)
        #expect(state.selectionStart == 0 && close(state.selectionEnd, 3))
        #expect(close(state.keyPhotoOutputTime, 1))
    }

    @Test func makeKeyPhotoOutsideNearEndShiftsInward() throws {
        var state = try EditState(source: source(20))
        state.makeKeyPhoto(at: 19.5)
        #expect(close(state.selectionStart, 17) && close(state.selectionEnd, 20))
        #expect(close(state.keyPhotoTime, 19.5))
    }

    @Test func makeKeyPhotoInsideLeavesTheSelection() throws {
        var state = try EditState(source: source(20))
        state.moveSelection(toStart: 10)
        state.makeKeyPhoto(at: 10.4)
        #expect(close(state.selectionStart, 10) && close(state.selectionEnd, 13))
        #expect(close(state.keyPhotoTime, 10.4))
    }

    @Test func tooShortOutputOffersHalfSpeed() throws {
        // 0.8 s source at 1× → output 0.8 s; export disabled; Use 0.5× gives 1.6 s.
        var state = try EditState(source: source(0.8))
        #expect(close(state.outputDuration, 0.8))
        #expect(state.exportIssue == .outputTooShort(seconds: 0.8, minimum: 1))
        let suggestion = try #require(state.suggestedSpeed)
        #expect(suggestion == 0.5)
        try state.setSpeed(suggestion)
        #expect(close(state.outputDuration, 1.6))
        #expect(state.exportIssue == nil)
    }

    @Test func halfSpeedSuggestedWhenItExactlyReachesTheMinimum() throws {
        let state = try EditState(source: source(0.5))  // 1.0 s at 0.5×
        #expect(state.suggestedSpeed == 0.5)
    }

    @Test func noSuggestionWhenHalfSpeedIsNotEnough() throws {
        var state = try EditState(source: source(20))
        try state.setDurationLocked(false)
        state.setSelectionEnd(0.4)  // 0.8 s at 0.5×, still under 1 s
        #expect(state.exportIssue == .outputTooShort(seconds: 0.4, minimum: 1))
        #expect(state.suggestedSpeed == nil)
    }

    @Test func lockDisablesSpeedsThatNeedMoreSource() throws {
        // 4.2 s source, locked at 3 s → 1.5× and 2× disabled; 0.5×, 0.75×, 1× available.
        var state = try EditState(source: source(4.2))
        #expect(state.durationLock.isOn)
        #expect(state.isSpeedAvailable(0.5) && state.isSpeedAvailable(0.75) && state.isSpeedAvailable(1))
        #expect(!state.isSpeedAvailable(1.5) && !state.isSpeedAvailable(2))
        #expect(state.unavailabilityReason(forSpeed: 2) == .needsMoreSource(required: 6, available: 4.2))
        #expect(state.unavailabilityReason(forSpeed: 2)?.errorDescription == "Needs 6.0 s of video; this one is 4.2 s.")

        let before = state
        #expect(throws: EditRejection.self) { try state.setSpeed(2) }
        #expect(state == before, "A rejected edit must leave the state unchanged")
    }

    // MARK: - Duration lock behavior

    @Test func lockedTrimSetsTheLockedDuration() throws {
        var state = try EditState(source: source(20))
        state.moveSelection(toStart: 10)
        #expect(state.setSelectionEnd(14) == nil)
        #expect(close(state.selectionStart, 10) && close(state.selectionEnd, 14))
        #expect(state.durationLock == DurationLock(isOn: true, target: 4))
        #expect(state.setSelectionStart(11.5) == nil)
        #expect(close(state.durationLock.target, 2.5))

        // A later speed change keeps the trimmed length.
        try state.setSpeed(0.5)
        #expect(close(state.outputDuration, 2.5))
    }

    @Test func lockedTrimStopsAtTheSupportedRange() throws {
        var state = try EditState(source: source(20))
        state.moveSelection(toStart: 10)
        #expect(state.setSelectionEnd(18) == .lockedDurationLimit(1...5))
        #expect(close(state.selectionEnd, 15) && close(state.durationLock.target, 5))
        state.setKeyPhoto(at: 14.5)
        #expect(state.setSelectionStart(14.8) == .lockedDurationLimit(1...5))
        #expect(close(state.selectionStart, 14) && close(state.durationLock.target, 1))

        // At 2× a locked output of 1–5 s spans 2–10 s of source; here the source end stops it first.
        try state.setSpeed(2)
        #expect(close(state.selectionStart, 13.5) && close(state.selectionEnd, 15.5))
        #expect(state.setSelectionEnd(30) == nil)
        #expect(close(state.selectionEnd, 20) && close(state.durationLock.target, 3.25))
        #expect(state.exportIssue == nil)
    }

    @Test func lockedTrimThatExcludesKeyPhotoMovesItInside() throws {
        var state = try EditState(source: source(20))
        state.moveSelection(toStart: 10)
        state.setKeyPhoto(at: 10.5)
        #expect(state.setSelectionStart(11) == .keyPhotoMovedInsideSelection)
        #expect(close(state.keyPhotoTime, 11))
    }

    @Test func movingPastTheEndShiftsInward() throws {
        var state = try EditState(source: source(10))
        state.moveSelection(toStart: 9)
        #expect(close(state.selectionStart, 7) && close(state.selectionEnd, 10))
    }

    @Test func unlockedSpeedChangeKeepsTheInterval() throws {
        var state = try EditState(source: source(20))
        try state.setDurationLocked(false)
        try state.setSpeed(2)
        #expect(state.selectionStart == 0 && close(state.selectionEnd, 3))
        #expect(close(state.outputDuration, 1.5))
    }

    @Test func unlockedOutputOutOfRangeDisablesExport() throws {
        var state = try EditState(source: source(20))
        try state.setDurationLocked(false)
        state.setSelectionEnd(12)
        #expect(state.exportIssue == .outputTooLong(seconds: 12, maximum: 5))
        try state.setSpeed(2)
        #expect(state.exportIssue == .outputTooLong(seconds: 6, maximum: 5))
    }

    @Test func unlockedTrimThatExcludesKeyPhotoMovesItInside() throws {
        var state = try EditState(source: source(20))
        try state.setDurationLocked(false)
        state.setKeyPhoto(at: 1)
        let notice = state.setSelectionStart(2)
        #expect(notice == .keyPhotoMovedInsideSelection)
        #expect(close(state.keyPhotoTime, 2))
        #expect(state.setSelectionStart(2.5) == .keyPhotoMovedInsideSelection)
        #expect(state.setSelectionEnd(2.9) == nil, "The Key Photo is still inside; no notice")
    }

    @Test func lockingCapturesOutputDurationOrNearestInRange() throws {
        var state = try EditState(source: source(20))
        try state.setDurationLocked(false)
        state.setSelectionEnd(4)
        try state.setDurationLocked(true)
        #expect(state.durationLock == DurationLock(isOn: true, target: 4))

        try state.setDurationLocked(false)
        state.setSelectionEnd(8)
        try state.setDurationLocked(true)
        #expect(state.durationLock.target == 5, "8 s is outside 1–5 s; the closest in-range value is 5 s")
        #expect(close(state.selectionLength, 5))
    }

    @Test func outputDurationValidation() throws {
        var state = try EditState(source: source(4))
        #expect(throws: EditRejection.lockTargetOutOfRange(target: 6, range: 1...5)) { try state.setOutputDuration(6) }
        #expect(throws: EditRejection.needsMoreSource(required: 4.5, available: 4)) { try state.setOutputDuration(4.5) }
        try state.setOutputDuration(2)
        #expect(close(state.outputDuration, 2))
        #expect(state.availableDurations == 1...4)
        try state.setSpeed(0.5)
        #expect(state.availableDurations == 1...5)
    }

    @Test func outputDurationResizesAroundTheKeyPhotoWithTheLockOff() throws {
        var state = try EditState(source: source(20))
        try state.setDurationLocked(false)
        state.makeKeyPhoto(at: 12)  // Selection 10.5–13.5 s, Key Photo in the middle.
        try state.setOutputDuration(5)
        #expect(close(state.selectionStart, 9.5) && close(state.selectionEnd, 14.5))
        #expect(close(state.keyPhotoTime, 12))
        #expect(!state.durationLock.isOn)
    }

    @Test func noDurationsAvailableForTooShortASource() throws {
        let state = try EditState(source: source(0.8))
        #expect(state.availableDurations == nil)
    }

    @Test func keyPhotoClampsToLastRenderedFrame() throws {
        var state = try EditState(source: source(20))
        state.setKeyPhoto(at: 3)
        #expect(state.plan.keyPhotoFrameIndex == 89)
        #expect(close(state.keyPhotoTime, 89.0 / 30))
    }

    // MARK: - Motion rate (§6)

    @Test func motionRate() throws {
        var state = try EditState(source: source(20, fps: 30))
        try state.setSpeed(0.5)
        #expect(state.motionRate == 15 && state.isMotionChoppy)

        var fast = try EditState(source: source(20, fps: 120))
        try fast.setSpeed(0.5)
        #expect(fast.motionRate == 60 && !fast.isMotionChoppy)

        let ntsc = try EditState(source: source(20, fps: 29.97))
        #expect(!ntsc.isMotionChoppy)
    }
}

@Suite("Crop rules")
struct CropTests {
    private let landscape = SourceInfo(duration: 10, frameRate: 30, orientedSize: CGSize(width: 1920, height: 1080), hasAudio: true)

    private func pixelRatio(_ rect: CGRect, _ size: CGSize) -> Double {
        Double((rect.width * size.width) / (rect.height * size.height))
    }

    @Test(arguments: CropAspect.presets.filter { if case .ratio = $0 { true } else { false } })
    func presetRatiosAreExactAndFitTheFrame(_ aspect: CropAspect) throws {
        var state = try EditState(source: landscape)
        try state.setCropAspect(aspect)
        let expected = try #require(aspect.pixelRatio(for: landscape.orientedSize))
        #expect(abs(pixelRatio(state.cropRect, landscape.orientedSize) - expected) < 1e-9)
        #expect(state.cropRect.minX >= 0 && state.cropRect.minY >= 0 && state.cropRect.maxX <= 1 + 1e-12 && state.cropRect.maxY <= 1 + 1e-12)
        #expect(state.cropRect.width == 1 || state.cropRect.height == 1, "Largest rectangle that fits")
    }

    @Test func changingRatioKeepsCenterWherePossible() throws {
        var state = try EditState(source: landscape)
        try state.setCropAspect(.freeform)
        state.setCropRect(CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.3))
        try state.setCropAspect(.ratio(width: 9, height: 16))
        #expect(abs(state.cropRect.midX - 0.75) < 1e-9, "Center kept horizontally")
        #expect(state.cropRect.minY == 0 && state.cropRect.height == 1)
    }

    @Test func fixedRatioIsEnforcedOnResize() throws {
        var state = try EditState(source: landscape)
        try state.setCropAspect(.ratio(width: 1, height: 1))
        state.setCropRect(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.9))
        #expect(abs(pixelRatio(state.cropRect, landscape.orientedSize) - 1) < 1e-9)
    }

    @Test func cropStaysInsideTheFrame() throws {
        var state = try EditState(source: landscape)
        try state.setCropAspect(.freeform)
        state.setCropRect(CGRect(x: 0.9, y: -0.2, width: 0.5, height: 0.5))
        #expect(state.cropRect == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        state.setCropRect(CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        #expect(state.cropRect.width * 1920 >= CropGeometry.minimumEdgePixels - 1e-9)
    }

    @Test func customRatioValidationAndReset() throws {
        var state = try EditState(source: landscape)
        #expect(throws: EditRejection.invalidAspectRatio) { try state.setCropAspect(.custom(width: 0, height: 3)) }
        try state.setCropAspect(.custom(width: 5, height: 4))
        #expect(abs(pixelRatio(state.cropRect, landscape.orientedSize) - 1.25) < 1e-9)
        state.resetCrop()
        #expect(state.cropAspect == .original && state.cropRect == CropGeometry.fullFrame)
    }

    @Test func outputSizeIsEvenCappedAndNeverUpscaled() throws {
        var state = try EditState(source: landscape)
        try state.setCropAspect(.ratio(width: 9, height: 16))
        let size = state.outputGeometry.renderSize
        #expect(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)
        #expect(size.height == 1080, "Never upscaled past the source")
        #expect(abs(Double(size.width / size.height) - 9.0 / 16) < 0.01)

        let fourK = SourceInfo(duration: 10, frameRate: 60, orientedSize: CGSize(width: 2160, height: 3840), hasAudio: true)
        let tall = try EditState(source: fourK)
        #expect(tall.outputGeometry.renderSize == CGSize(width: 1080, height: 1920))

        try state.setCropAspect(.freeform)
        state.setCropRect(CGRect(x: 0, y: 0, width: 0.25, height: 0.25))
        #expect(state.isLowResolution)
    }
}
