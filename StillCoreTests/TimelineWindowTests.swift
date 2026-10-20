import Testing
@testable import StillCore

@Suite("Timeline window")
struct TimelineWindowTests {
    @Test func shortSourcesShowOnlyTheDetailStrip() {
        #expect(!TimelineWindow.showsOverview(sourceDuration: 8))
        #expect(TimelineWindow.detailRange(selection: 1...4, playhead: 2, sourceDuration: 6) == 0...6)
    }

    @Test func detailFollowsTheSelectionWithPadding() {
        #expect(TimelineWindow.detailRange(selection: 100...103, playhead: 101, sourceDuration: 600) == 98...105)
        #expect(TimelineWindow.detailRange(selection: 0.5...3.5, playhead: 1, sourceDuration: 600) == 0...7)
        #expect(TimelineWindow.detailRange(selection: 597...600, playhead: 598, sourceDuration: 600) == 593...600)
    }

    @Test func detailFollowsThePlayheadOutsideTheSelection() {
        #expect(TimelineWindow.detailRange(selection: 100...103, playhead: 300, sourceDuration: 600) == 296.5...303.5)
    }

    @Test func outputFrameMapping() throws {
        var state = try EditState(source: SourceInfo(duration: 20, frameRate: 30, orientedSize: .init(width: 1920, height: 1080), hasAudio: true))
        try state.setSpeed(2)
        try state.setOutputDuration(3)  // 6 s of source at 2×.
        state.moveSelection(toStart: 10)
        #expect(state.sourceTime(ofOutputFrame: 30) == 12)
        #expect(state.outputFrame(atSourceTime: 12) == 30)
        #expect(state.outputFrame(atSourceTime: 12.05) == 30)
        #expect(state.outputFrame(atSourceTime: 30) == 89)
        #expect(state.isInsideSelection(16) && !state.isInsideSelection(16.1))
    }
}
