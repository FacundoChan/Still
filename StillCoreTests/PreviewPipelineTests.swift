import AVFoundation
import Foundation
import Testing
@testable import StillCore

/// The selection preview plays the export's retimed sound (goal.md §2, preview matches export).
@Suite("Preview pipeline", .serialized)
struct PreviewPipelineTests {
    @MainActor
    @Test(arguments: [
        ("landscape-sdr-30fps-6s.mov", Fixture.Kind.synthetic, 0.5),
        ("landscape-sdr-30fps-6s.mov", Fixture.Kind.synthetic, 2.0),
        ("portrait-hdr-dolbyvision-59.94fps-5.1s.mov", Fixture.Kind.real, 0.5),
    ].filter { Fixture.isAvailable(Fixture.root.appending(path: "Fixtures/\($0.1.rawValue)/\($0.0)")) })
    func selectionPreviewPlaysRetimedSound(fixture: String, kind: Fixture.Kind, speed: Double) async throws {
        let source = try await SourceMedia.load(Fixture.root.appending(path: "Fixtures/\(kind.rawValue)/\(fixture)"))
        var state = try EditState(source: source.info)
        try state.setSpeed(speed)
        let plan = state.plan

        let graph = try RenderPipeline.build(source: source, plan: plan)
        let directory = Fixture.outputDirectory(for: "preview/\(fixture)-\(speed)")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appending(path: "audio.caf")
        let wrote: Bool
        do { wrote = try graph.writeRetimedAudio(to: audioURL) } catch {
            Issue.record("writeRetimedAudio threw \(error)")
            throw error
        }
        #expect(wrote)
        let audioAsset = AVURLAsset(url: audioURL)
        let tracks = try await audioAsset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1, "CAF has \(tracks.count) audio tracks")

        let preview: RenderGraph
        do { preview = try await RenderPipeline.buildPreview(source: source, plan: plan, retimedAudio: audioURL) } catch {
            Issue.record("buildPreview threw \(error)")
            throw error
        }
        #expect(preview.hasAudio)
        let audioTrack = try #require(preview.composition.tracks(withMediaType: .audio).first)
        #expect(abs(audioTrack.timeRange.duration.seconds - plan.renderedDuration.seconds) < 0.01)

        let item = preview.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        for _ in 0..<200 where item.status == .unknown {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(item.status == .readyToPlay, "Player item failed: \(String(describing: item.error))")
        player.pause()
    }
}
