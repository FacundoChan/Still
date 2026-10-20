import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import StillCore

/// One edit to render: a fixture plus the trim, speed, and crop to apply.
struct RenderCase: Sendable, CustomTestStringConvertible {
    let name: String
    let fixture: String
    let kind: Fixture.Kind
    let start: Double
    let end: Double
    let speed: Double
    let aspect: CropAspect
    /// Whether the source is SDR, so its decoded frames can serve as ground truth.
    let comparesWithSource: Bool

    var url: URL { Fixture.root.appending(path: "Fixtures/\(kind.rawValue)/\(fixture)") }
    var isAvailable: Bool { Fixture.isAvailable(url) }
    var testDescription: String { name }

    func makeState(for source: SourceMedia) throws -> EditState {
        var state = try EditState(source: source.info)
        try state.setDurationLocked(false)
        state.setSelectionEnd(end)
        state.setSelectionStart(start)
        try state.setSpeed(speed)
        try state.setCropAspect(aspect)
        return state
    }

    // Starts sit 1/300 s off the 30 fps grid so a source frame never falls exactly on a sampled time,
    // where rounding could legitimately pick either neighbor.
    static let all: [RenderCase] = [
        RenderCase(name: "landscape 1× full frame", fixture: "landscape-sdr-30fps-6s.mov", kind: .synthetic,
                   start: 1 + 1 / 300, end: 4 + 1 / 300, speed: 1, aspect: .original, comparesWithSource: true),
        RenderCase(name: "landscape 2× square crop", fixture: "landscape-sdr-30fps-6s.mov", kind: .synthetic,
                   start: 1 / 300, end: 6 - 1 / 300, speed: 2, aspect: .ratio(width: 1, height: 1), comparesWithSource: true),
        RenderCase(name: "landscape 0.5× 9:16 crop", fixture: "landscape-sdr-30fps-6s.mov", kind: .synthetic,
                   start: 1 + 1 / 300, end: 2.5 + 1 / 300, speed: 0.5, aspect: .ratio(width: 9, height: 16), comparesWithSource: true),
        RenderCase(name: "rotated portrait 0.75× 4:3 crop", fixture: "rotated-portrait-sdr-30fps-5s.mov", kind: .synthetic,
                   start: 0.5 + 1 / 300, end: 2.75 + 1 / 300, speed: 0.75, aspect: .ratio(width: 4, height: 3), comparesWithSource: true),
        RenderCase(name: "120 fps 0.5×", fixture: "hfr-120fps-4s.mov", kind: .synthetic,
                   start: 1 + 1 / 300, end: 2.5 + 1 / 300, speed: 0.5, aspect: .original, comparesWithSource: true),
        RenderCase(name: "variable frame rate 1.5×", fixture: "vfr-30fps-5s.mov", kind: .synthetic,
                   start: 0.25 + 1 / 300, end: 4.75 + 1 / 300, speed: 1.5, aspect: .original, comparesWithSource: true),
        RenderCase(name: "iPhone SDR 1.5× custom 4:5", fixture: "portrait-sdr-h264-30fps-4.8s.mov", kind: .real,
                   start: 0.2, end: 4.7, speed: 1.5, aspect: .custom(width: 4, height: 5), comparesWithSource: false),
        RenderCase(name: "iPhone Dolby Vision 0.75× square", fixture: "portrait-hdr-dolbyvision-60fps-3.3s.mov", kind: .real,
                   start: 0.5, end: 2.75, speed: 0.75, aspect: .ratio(width: 1, height: 1), comparesWithSource: false),
    ]
}

@Suite("Render correctness", .serialized)
struct RenderCorrectnessTests {
    /// goal.md §13, Goal B: decoded export frames match what preview playback shows at PSNR ≥ 35 dB.
    static let parityThreshold = 35.0
    /// Composition frames vs the same frames computed straight from the source, for SDR synthetic sources.
    static let sourceThreshold = 35.0

    @Test(arguments: RenderCase.all.filter(\.isAvailable))
    func exportMatchesPreviewAndSource(_ edit: RenderCase) async throws {
        let source = try await SourceMedia.load(edit.url)
        let state = try edit.makeState(for: source)
        let plan = state.plan
        #expect(plan.issue(sourceDuration: source.duration) == nil)

        let directory = Fixture.outputDirectory(for: "render/\(edit.name)")
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(plan, source: source, to: directory, baseName: "LivePhoto")
        let graph = try RenderPipeline.build(source: source, plan: plan)

        // Size, duration, and frame timing.
        #expect(pair.pixelSize == state.outputGeometry.renderSize)
        let times = try await MediaProbe.videoPresentationTimes(pair.videoURL)
        #expect(Int64(times.count) == plan.outputFrameCount)
        let offGrid = times.enumerated().map { abs($0.element.seconds - Double($0.offset) / 30) }.max() ?? 0
        #expect(offGrid < 1e-4, "Frames must sit on the constant 30 fps grid")

        // Export vs what playback shows, compared in Y′CbCr so no color conversion is involved.
        let last = plan.outputFrameCount - 1
        let sampled = [0, last / 4, last / 2, 3 * last / 4, last, plan.keyPhotoFrameIndex]
        let playback = try MediaProbe.playbackFrames(graph, at: sampled)
        let movie = try await MediaProbe.movieFrames(pair.videoURL, at: sampled)
        var parities: [Double] = []
        for index in sampled {
            let playbackFrame = try #require(playback[index], "No playback frame \(index)")
            let movieFrame = try #require(movie[index], "No movie frame \(index)")
            let parity = MediaProbe.psnr(movieFrame, playbackFrame)
            parities.append(parity)
            #expect(parity >= Self.parityThreshold, "Frame \(index): export vs playback \(parity) dB")
            if parity < Self.parityThreshold {
                MediaProbe.save(movieFrame.image, to: directory.appending(path: "frame-\(index)-export.png"))
                MediaProbe.save(playbackFrame.image, to: directory.appending(path: "frame-\(index)-playback.png"))
            }
        }

        // The composition vs the same frames computed straight from the source: geometry and time mapping,
        // independent of the pipeline. Both sides use AVAssetImageGenerator, which is reliable for SDR.
        var truths: [Double] = []
        if edit.comparesWithSource {
            for index in sampled {
                let time = CMTime(value: index, timescale: 30)
                let rendered = try await MediaProbe.frame(of: graph.composition, at: time, videoComposition: graph.videoComposition)
                let expected = try await MediaProbe.expectedFrame(
                    source: source.asset, at: .seconds(edit.start + Double(index) / 30 * edit.speed),
                    crop: plan.crop, size: pair.pixelSize
                )
                let truth = MediaProbe.psnr(rendered, expected)
                truths.append(truth)
                #expect(truth >= Self.sourceThreshold, "Frame \(index): composition vs source \(truth) dB")
            }
        }

        // Key Photo JPEG vs the movie frame and the playback frame at its presentation time.
        let keyPhoto = try MediaProbe.image(at: pair.imageURL)
        let keyIndex = plan.keyPhotoFrameIndex
        let keyParity = MediaProbe.psnr(keyPhoto, try #require(movie[keyIndex]).image)
        #expect(keyParity >= Self.parityThreshold, "Key Photo vs movie frame \(keyParity) dB")
        let keyFidelity = MediaProbe.psnr(keyPhoto, try #require(playback[keyIndex]).image)
        #expect(keyFidelity >= Self.parityThreshold, "Key Photo vs playback frame \(keyFidelity) dB")
        print(String(format: "MEASURE %@ | export vs playback min %.1f dB | composition vs source min %@ | Key Photo vs movie %.1f dB, vs playback %.1f dB",
                     edit.name, parities.min() ?? 0, truths.min().map { String(format: "%.1f dB", $0) } ?? "n/a", keyParity, keyFidelity))

        let pairing = await LivePhotoInspector.checkPairing(imageURL: pair.imageURL, videoURL: pair.videoURL)
        #expect(pairing == .paired)
    }

    /// Negative control for the geometry check: a crop moved by 1% of the frame must fall below the
    /// threshold, so a misplaced crop can’t pass unnoticed.
    @Test func sourceComparisonDetectsAMisplacedCrop() async throws {
        let edit = try #require(RenderCase.all.first { $0.name == "landscape 2× square crop" })
        let source = try await SourceMedia.load(edit.url)
        let plan = try edit.makeState(for: source).plan
        let graph = try RenderPipeline.build(source: source, plan: plan)
        let time = CMTime(value: 30, timescale: 30)
        let rendered = try await MediaProbe.frame(of: graph.composition, at: time, videoComposition: graph.videoComposition)
        let sourceTime = CMTime.seconds(edit.start + 1 * edit.speed)
        let shiftedCrop = plan.crop.offsetBy(dx: 0.01, dy: 0)
        let shifted = try await MediaProbe.expectedFrame(source: source.asset, at: sourceTime, crop: shiftedCrop, size: graph.renderSize)
        let correct = try await MediaProbe.expectedFrame(source: source.asset, at: sourceTime, crop: plan.crop, size: graph.renderSize)
        #expect(MediaProbe.psnr(rendered, correct) >= Self.sourceThreshold)
        let misplaced = MediaProbe.psnr(rendered, shifted)
        #expect(misplaced < Self.sourceThreshold, "A 1% crop shift still scored \(misplaced) dB")
        print(String(format: "MEASURE negative control crop shifted 1%%: %.1f dB", misplaced))
    }

    @Test func muteRemovesTheAudioTrack() async throws {
        let url = Fixture.root.appending(path: "Fixtures/synthetic/landscape-sdr-30fps-6s.mov")
        let source = try await SourceMedia.load(url)
        var state = try EditState(source: source.info)
        state.setIncludesAudio(false)
        let directory = Fixture.outputDirectory(for: "render/muted")
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(state.plan, source: source, to: directory, baseName: "LivePhoto")
        #expect(!pair.hasAudio)
        #expect(try await MediaProbe.audio(pair.videoURL) == nil)
    }

    /// The 440 Hz tone must stay 440 Hz at any speed (goal.md §9, pitch preserved).
    @Test(arguments: [0.5, 0.75, 1.5, 2])
    func pitchIsPreserved(speed: Double) async throws {
        let url = Fixture.root.appending(path: "Fixtures/synthetic/landscape-sdr-30fps-6s.mov")
        let source = try await SourceMedia.load(url)
        var state = try EditState(source: source.info)
        state.moveSelection(toStart: 0)
        try state.setSpeed(speed)
        let directory = Fixture.outputDirectory(for: "render/pitch-\(speed)")
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(state.plan, source: source, to: directory, baseName: "LivePhoto")

        let audio = try #require(try await MediaProbe.audio(pair.videoURL))
        #expect(abs(audio.duration - 3) < 0.05, "Audio lasts \(audio.duration) s")
        let frequency = MediaProbe.toneFrequency(audio, from: 0.5, to: 2.5)
        #expect(abs(frequency - 440) / 440 < 0.02, "Measured \(frequency) Hz at \(speed)×")
    }

    /// Each white flash must coincide with its beep after retiming (goal.md §14, audio stays in sync).
    @Test(arguments: [(0.5, 0.94), (1.0, 0.94), (2.0, 0.95)])
    func audioStaysInSync(speed: Double, start: Double) async throws {
        let url = Fixture.root.appending(path: "Fixtures/synthetic/av-sync-30fps-8s.mov")
        let source = try await SourceMedia.load(url)
        var state = try EditState(source: source.info)
        try state.setSpeed(speed)
        state.moveSelection(toStart: start)
        let directory = Fixture.outputDirectory(for: "render/sync-\(speed)")
        try? FileManager.default.removeItem(at: directory)
        let pair = try await LivePhotoExporter().export(state.plan, source: source, to: directory, baseName: "LivePhoto")

        let flashes = try await MediaProbe.flashOnsets(pair.videoURL)
        let beeps = MediaProbe.beepOnsets(try #require(try await MediaProbe.audio(pair.videoURL)))
        let expected = (1...8).map(Double.init).filter { $0 >= start && $0 < state.selectionEnd }.map { ($0 - start) / speed }
        #expect(flashes.count == expected.count, "Flashes \(flashes), expected \(expected)")
        #expect(beeps.count == expected.count, "Beeps \(beeps), expected \(expected)")

        // A flash shows on the first output frame at or after its beep: up to one frame later.
        for (flash, beep) in zip(flashes, beeps) {
            let offset = flash - beep
            #expect(offset > -0.012 && offset < 1.0 / 30 + 0.012, "Flash \(flash) s vs beep \(beep) s at \(speed)×")
        }
    }
}
