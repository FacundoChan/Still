import AVFoundation
import CoreGraphics
import Testing
@testable import StillCore

/// An edit saved as a plain video: its choices beside the Live Photo's, its length, its size, and the movie it makes.
@Suite("Video mode", .serialized)
struct VideoModeTests {
    static let source = SourceInfo(duration: 40, frameRate: 29.97, orientedSize: CGSize(width: 1920, height: 1080), hasAudio: true)
    static let facts = CompressionSource(
        duration: 40, orientedSize: CGSize(width: 1920, height: 1080), frameRate: 29.97,
        audio: .init(isAAC: true, channelCount: 2, sampleRate: 44_100, bitRate: 128_000),
        videoBitRate: 12_000_000, fileSize: 60_000_000
    )

    @Test func aVideoHasNoLivePhotoLimit() throws {
        var state = try EditState(source: Self.source, video: Self.facts)
        #expect(state.kind == .livePhoto)
        #expect(state.setKind(.video) == nil)
        state.selectAll()
        #expect(state.selectionStart == 0 && state.selectionEnd == 40)
        #expect(state.exportIssue == nil)
        #expect(state.output.frameRate == 30)
        #expect(state.keepsFrameTiming)
        try state.setSpeed(2)
        #expect(!state.keepsFrameTiming, "At another speed, frames are made at the copy's rate")
        try state.setSpeed(1)

        // Back to a Live Photo: the selection shortens to the longest one, around the Key Photo.
        #expect(state.setKind(.livePhoto) != nil)
        #expect(abs(state.outputDuration - 15) < 1e-6)
        #expect(state.isInsideSelection(state.keyPhotoTime))
        #expect(state.exportIssue == nil)
    }

    @Test func withoutItsFactsAnEditStaysALivePhoto() throws {
        var state = try EditState(source: Self.source)
        #expect(!state.canMakeVideo)
        state.setKind(.video)
        #expect(state.kind == .livePhoto)
    }

    @Test func eachKindKeepsItsOwnChoices() throws {
        var state = try EditState(source: Self.source, video: Self.facts)
        state.setResolution(.hd)
        state.setBitRate(.high)
        state.setKind(.video)
        #expect(state.resolution == .fullHD && state.bitRate == .standard)
        state.setBitRate(.low)
        #expect(state.output.bitsPerPixel == VideoBitRate.low.compressionBitsPerPixel)
        state.setKind(.livePhoto)
        #expect(state.resolution == .hd && state.bitRate == .high)
        state.setKind(.video)
        #expect(state.bitRate == .low)
    }

    @Test func aVideoInH264IsStandardRange() throws {
        var hdr = Self.source
        hdr.isHDR = true
        var facts = Self.facts
        facts.isHDR = true
        var state = try EditState(source: hdr, video: facts)
        state.setKind(.video)
        #expect(state.isHDR && state.canKeepHDR)
        state.updateVideo { $0.setCodec(.h264) }
        #expect(!state.isHDR && !state.canKeepHDR)
        state.updateVideo { $0.setCodec(.hevc) }
        #expect(state.isHDR, "HDR comes back with HEVC")
    }

    @Test func theEstimateIsTheVideoAndItsSound() throws {
        var state = try EditState(source: Self.source, video: Self.facts)
        state.setKind(.video)
        state.selectAll()
        state.setSelectionEnd(10)
        let sizes = state.estimatedSizes(calibration: nil)
        #expect(sizes.photo == 0)
        let video = Double(state.output.averageVideoBitRate(for: CGSize(width: 1920, height: 1080))) * 10
        #expect(sizes.video == Int64((video + 128_000 * 10) / 8))
    }

    /// Two to 5.6 seconds of the speech clip at 2×, its middle half, with captions: 1.8 seconds of a narrower video,
    /// sound retimed to the same length, and the words drawn in.
    @Test func exportsATrimmedCroppedFasterVideoWithCaptions() async throws {
        let media = try await SourceMedia.load(CaptionTests.speech.url)
        var state = try EditState(source: media.info, video: try await media.compressionSource())
        state.setKind(.video)
        state.selectAll()
        state.setSelectionStart(2)
        state.setSelectionEnd(5.6)
        try state.setSpeed(2)
        try state.setCropAspect(.freeform)
        state.setCropRect(CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        var plan = state.plan
        plan.captions = BurnedCaptions(phrases: CaptionTests.phrases, style: .current)

        let directory = Fixture.outputDirectory(for: "video-mode")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let video = try await VideoExporter().export(plan, keepsFrameTiming: state.keepsFrameTiming, audio: state.video?.source.audio,
                                                     source: media, to: directory.appending(path: "Video.MOV"))
        #expect(abs(video.duration.seconds - 1.8) < 0.05)
        #expect(video.pixelSize == CGSize(width: 640, height: 720))
        #expect(video.hasAudio)
        let movie = try await SourceMedia.load(video.url)
        #expect(abs(movie.duration.seconds - 1.8) < 0.1)
        let sound = try #require(try await MediaProbe.audio(video.url))
        #expect(abs(sound.duration - 1.8) < 0.1, "sound \(sound.duration) s")

        // “This is a test…” is said from 2 s, the selection's start: from 0 s in the video, over a dark frame.
        let overlay = CaptionOverlay(try #require(plan.captions), plan: plan, renderSize: video.pixelSize)
        let cue = try #require(overlay.cue(at: 0.3))
        let frames = try await MediaProbe.movieFrames(video.url, at: [9])
        #expect(CaptionTests.brightest(try #require(frames[9]), in: cue.extent) > 150)
    }
}
