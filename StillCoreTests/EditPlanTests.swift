import CoreMedia
import Testing
@testable import StillCore

@Suite("Edit plan timing")
struct EditPlanTests {
    private func plan(from start: Double, to end: Double, speed: Double, key: Double? = nil) -> EditPlan {
        EditPlan(
            selection: CMTimeRange(start: .seconds(start), end: .seconds(end)),
            speed: speed,
            keyPhotoSourceTime: .seconds(key ?? (start + end) / 2)
        )
    }

    // goal.md §6, required examples.
    @Test(arguments: [
        (10.0, 13.0, 1.0, 3.0),
        (10.0, 16.0, 2.0, 3.0),
        (10.0, 11.5, 0.5, 3.0),
        (10.0, 13.0, 2.0, 1.5),
    ])
    func outputDuration(start: Double, end: Double, speed: Double, expected: Double) {
        #expect(abs(plan(from: start, to: end, speed: speed).outputDuration.seconds - expected) < 1e-6)
    }

    // goal.md §7: a Key Photo at source 12 s in a 10–16 s selection at 2× is output second 1.
    @Test func keyPhotoOutputTime() {
        let edit = plan(from: 10, to: 16, speed: 2, key: 12)
        #expect(abs(edit.keyPhotoOutputTime.seconds - 1) < 1e-6)
        #expect(edit.keyPhotoFrameIndex == 30)
        #expect(edit.keyPhotoFrameTime == CMTime(value: 30, timescale: 30))
    }

    @Test func frameCountAtThirtyFramesPerSecond() {
        #expect(plan(from: 0, to: 3, speed: 1).outputFrameCount == 90)
        #expect(plan(from: 0, to: 1.5, speed: 1).outputFrameCount == 45)
        #expect(plan(from: 0, to: 3, speed: 2).outputFrameCount == 45)
    }

    @Test func keyPhotoSnapsToNearestRenderedFrame() {
        // 1.51 s × 30 = 45.3 → frame 45.
        #expect(plan(from: 0, to: 3, speed: 1, key: 1.51).keyPhotoFrameIndex == 45)
        // The last rendered frame of a 3 s output is 89, even when the key sits on the end.
        #expect(plan(from: 0, to: 3, speed: 1, key: 3).keyPhotoFrameIndex == 89)
    }

    @Test func rejectsOutputOutsideProductRange() {
        let sourceDuration = CMTime.seconds(20)
        #expect(plan(from: 0, to: 0.8, speed: 1).issue(sourceDuration: sourceDuration) == .outputTooShort(seconds: 0.8, minimum: 1))
        #expect(plan(from: 0, to: 0.8, speed: 0.5).issue(sourceDuration: sourceDuration) == nil)
        #expect(plan(from: 0, to: 6, speed: 1).issue(sourceDuration: sourceDuration) == .outputTooLong(seconds: 6, maximum: 5))
        #expect(plan(from: 18, to: 21, speed: 1).issue(sourceDuration: sourceDuration) == .selectionOutsideSource)
        #expect(plan(from: 0, to: 3, speed: 1, key: 4).issue(sourceDuration: sourceDuration) == .keyPhotoOutsideSelection)
    }
}
